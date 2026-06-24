import Foundation
import AudioToolbox
import AVFoundation

/// Decodes a live HTTP/Icecast MP3 ATC stream to mono 16 kHz PCM using AudioToolbox —
/// URLSession streams the bytes, `AudioFileStream` parses MP3 frames into packets, an
/// `AudioConverter` decodes packets to PCM, and an `AVAudioConverter` resamples to
/// 16 kHz mono. The native counterpart of the Python ffmpeg decode.
///
/// (AVPlayer + MTAudioProcessingTap was tried first but doesn't work for live remote
/// Icecast streams — AVURLAsset exposes no audio track — so we decode the stream ourselves.)
///
/// **Threading:** the parser/decoder state (streamID, decoder, resampler, packetBuffer,
/// descPtr, packetCursor, …) and the continuation are AudioToolbox C objects and manually
/// managed memory with no internal locking. ALL access is confined to one private serial
/// queue: URLSession delivers its delegate callbacks there (via `callbackQueue`), and
/// connect/reconnect/`stop` teardown are dispatched there too. That makes buffer frees and
/// CoreAudio handle lifecycle mutually exclusive with in-flight parsing/decoding — without
/// it, a `stop()` racing a delegate callback is a use-after-free.
final class StreamAudioSource: NSObject, AudioSource, URLSessionDataDelegate {
    private let url: URL
    /// Edge-server candidates for the mount (Python iterates `candidate_stream_urls`); a
    /// reconnect rotates through these so one dead edge host doesn't strand the feed.
    private let candidates: [URL]
    private var candidateIndex = 0
    /// Consecutive failed connects with no decoded audio (reset once audio flows). Used to
    /// give up on a permanently unreachable feed instead of reconnecting forever.
    private var connectAttempts = 0
    private var decodedAnyAudio = false

    private var urlSession: URLSession?
    private var task: URLSessionDataTask?
    private var streamID: AudioFileStreamID?
    private var decoder: AudioConverterRef?
    private var resampler: AVAudioConverter?
    private var sourceFormat = AudioStreamBasicDescription()
    private var pcmFormat: AVAudioFormat?
    private var stopped = false

    /// Serial queue that owns all parser/decoder/continuation state (see the type doc).
    /// URLSession delivers its delegate callbacks here, and connect/reconnect/teardown are
    /// posted here as operations, so every access to the CoreAudio handles is serialized.
    /// (A plain serial OperationQueue, like URLSession's own `delegateQueue: nil` queue —
    /// NOT backed by an `underlyingQueue`, which stalls callback delivery after the first.)
    private let callbackQueue = OperationQueue()

    fileprivate var continuation: AsyncStream<[Float]>.Continuation?
    fileprivate var chunkCount = 0

    // Current batch of compressed packets being fed to the decoder's pull callback.
    private var packetBuffer: UnsafeMutableRawPointer?
    fileprivate var packetDescs: [AudioStreamPacketDescription] = []
    fileprivate var packetCursor = 0

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    init(url: URL) {
        self.url = url
        let expanded = StreamURLResolver.candidateURLs(url.absoluteString).compactMap { URL(string: $0) }
        self.candidates = expanded.isEmpty ? [url] : expanded
        super.init()
        callbackQueue.name = "net.atctranscribe.stream"
        callbackQueue.maxConcurrentOperationCount = 1     // serial: one callback/teardown at a time
    }

    func makeStream() -> AsyncStream<[Float]> {
        AsyncStream { cont in
            self.continuation = cont                          // written once, before any queue activity
            cont.onTermination = { [weak self] _ in self?.stop() }
            self.callbackQueue.addOperation { [weak self] in self?.connect() }
        }
    }

    /// Open the parser and start a data task for the current candidate. Runs on `callbackQueue`.
    private func connect() {
        guard !stopped else { return }
        let target = candidates[candidateIndex % candidates.count]
        AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(),
                            streamPropertyProc, streamPacketsProc, kAudioFileMP3Type, &streamID)
        var req = URLRequest(url: target)
        req.setValue("Mozilla/5.0 ATC_Transcribe/1.0", forHTTPHeaderField: "User-Agent")
        let session = urlSession ?? URLSession(configuration: .default, delegate: self, delegateQueue: callbackQueue)
        urlSession = session
        let t = session.dataTask(with: req)
        task = t
        NSLog("[stream] connecting %@", target.absoluteString)
        t.resume()
    }

    func stop() { callbackQueue.addOperation { [weak self] in self?.teardown() } }

    /// Full teardown. Runs serialized on `callbackQueue`; idempotent via `stopped`.
    private func teardown() {
        guard !stopped else { return }
        stopped = true
        task?.cancel(); task = nil
        urlSession?.invalidateAndCancel(); urlSession = nil
        if let d = decoder { AudioConverterDispose(d); decoder = nil }
        if let s = streamID { AudioFileStreamClose(s); streamID = nil }
        descPtr?.deallocate(); descPtr = nil
        packetBuffer?.deallocate(); packetBuffer = nil
        continuation?.finish(); continuation = nil
    }

    // MARK: URLSession — feed bytes to the parser (delegate callbacks run on callbackQueue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, let streamID else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let base = raw.baseAddress { AudioFileStreamParseBytes(streamID, UInt32(data.count), base, []) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        NSLog("[stream] task ended: %@", error?.localizedDescription ?? "closed")
        guard !stopped else { return }
        // Drop this attempt's parser/decoder before retrying.
        if let s = streamID { AudioFileStreamClose(s); streamID = nil }
        if let d = decoder { AudioConverterDispose(d); decoder = nil }
        resampler = nil

        // Rotate to the next edge server. Until we've decoded any audio a completion is a
        // connect failure, not a live drop: cap the attempts so a dead/unreachable feed
        // ends the stream (UI shows "Stream ended") instead of reconnecting forever.
        candidateIndex += 1
        if !decodedAnyAudio {
            connectAttempts += 1
            if connectAttempts >= candidates.count * 2 {
                NSLog("[stream] no audio after %d attempts — giving up", connectAttempts)
                teardown()   // invalidate the session + finish the stream (UI shows "Stream ended")
                return
            }
        }
        // Live streams drop periodically; reconnect (mirrors the Python ffmpeg reconnect).
        // Wait off-queue, then post connect back onto the serial callbackQueue.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.callbackQueue.addOperation { [weak self] in
                guard let self, !self.stopped else { return }
                self.connect()
            }
        }
    }

    // MARK: parser callbacks

    fileprivate func handleProperty(_ propertyID: AudioFileStreamPropertyID) {
        guard decoder == nil, let streamID,
              propertyID == kAudioFileStreamProperty_ReadyToProducePackets
                || propertyID == kAudioFileStreamProperty_DataFormat else { return }
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &sourceFormat) == noErr,
              sourceFormat.mSampleRate > 0, sourceFormat.mChannelsPerFrame > 0 else { return }
        let ch = sourceFormat.mChannelsPerFrame
        var pcm = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
            mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
        guard AudioConverterNew(&sourceFormat, &pcm, &decoder) == noErr else { return }
        pcmFormat = AVAudioFormat(streamDescription: &pcm)
        if let pcmFormat { resampler = AVAudioConverter(from: pcmFormat, to: target) }
        NSLog("[stream] decoding %.0f Hz %u ch", sourceFormat.mSampleRate, ch)
    }

    fileprivate func handlePackets(_ numberBytes: UInt32, _ numberPackets: UInt32,
                                   _ inputData: UnsafeRawPointer,
                                   _ descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard !stopped, let decoder, let pcmFormat, let resampler, numberPackets > 0 else { return }
        packetBuffer?.deallocate()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(numberBytes), alignment: 1)
        buf.copyMemory(from: inputData, byteCount: Int(numberBytes))
        packetBuffer = buf
        packetDescs = descs != nil ? Array(UnsafeBufferPointer(start: descs, count: Int(numberPackets))) : []
        packetCursor = 0
        guard !packetDescs.isEmpty else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        while packetCursor < packetDescs.count {
            guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 8192) else { break }
            out.frameLength = out.frameCapacity   // advertise full byte capacity, else FillComplexBuffer → -50 paramErr
            var framesOut: UInt32 = out.frameCapacity
            let status = AudioConverterFillComplexBuffer(decoder, decoderInputProc, selfPtr,
                                                         &framesOut, out.mutableAudioBufferList, nil)
            // `status == noMoreInputData` means the input proc reported this batch is drained —
            // NOT a real error and NOT end-of-stream (see supplyPackets). Emit any frames it
            // managed to produce, then move on; the converter stays alive for the next batch.
            if framesOut == 0 {
                if status != noErr && status != Self.noMoreInputData && chunkCount < 4 {
                    NSLog("[stream] fill failed status=%d", status)
                }
                break
            }
            out.frameLength = framesOut
            resample(out, with: resampler)
            if status != noErr { break }   // batch drained (or real error) → done with this batch
        }
    }

    private func resample(_ input: AVAudioPCMBuffer, with resampler: AVAudioConverter) {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        resampler.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return input
        }
        if let channel = out.floatChannelData, out.frameLength > 0 {
            emit(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
        }
    }

    fileprivate func emit(_ samples: [Float]) {
        decodedAnyAudio = true
        connectAttempts = 0
        chunkCount += 1
        if chunkCount % 15 == 1 {
            var sum: Float = 0
            for v in samples { sum += v * v }
            let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
            NSLog("[stream] decoded %d chunks (rms %.4f)", chunkCount, rms)
        }
        continuation?.yield(samples)
    }

    /// Sentinel returned by the decoder input proc when the current batch is drained. It is
    /// NOT `noErr`: returning 0 packets with `noErr` tells AudioConverter the stream has ENDED,
    /// after which it flushes and produces 0 frames forever (the live feed goes deaf after the
    /// first batch). A non-zero status instead means "no more input right now" — FillComplexBuffer
    /// returns it without latching end-of-stream, so the converter is reusable for the next batch.
    static let noMoreInputData: OSStatus = -1

    /// Supplies the remaining packets of the current batch to the decoder (one shot).
    fileprivate func supplyPackets(_ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                                   _ ioData: UnsafeMutablePointer<AudioBufferList>,
                                   _ outDescs: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        let remaining = packetDescs.count - packetCursor
        guard remaining > 0 else { ioNumberDataPackets.pointee = 0; return Self.noMoreInputData }
        let count = min(Int(ioNumberDataPackets.pointee), remaining)
        let descSlice = Array(packetDescs[packetCursor ..< packetCursor + count])
        let start = Int(descSlice[0].mStartOffset)
        let last = descSlice[count - 1]
        let end = Int(last.mStartOffset) + Int(last.mDataByteSize)

        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = sourceFormat.mChannelsPerFrame
        ioData.pointee.mBuffers.mDataByteSize = UInt32(end - start)
        ioData.pointee.mBuffers.mData = packetBuffer?.advanced(by: start)
        if let outDescs {
            // Rebase offsets to the slice start in a stable, manually-owned buffer the
            // converter reads synchronously during FillComplexBuffer.
            descPtr?.deallocate()
            let ptr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: count)
            for i in 0..<count {
                let d = descSlice[i]
                ptr[i] = AudioStreamPacketDescription(mStartOffset: d.mStartOffset - Int64(start),
                                                      mVariableFramesInPacket: d.mVariableFramesInPacket,
                                                      mDataByteSize: d.mDataByteSize)
            }
            descPtr = ptr
            outDescs.pointee = ptr
        }
        ioNumberDataPackets.pointee = UInt32(count)
        packetCursor += count
        return noErr
    }

    private var descPtr: UnsafeMutablePointer<AudioStreamPacketDescription>?
}

// MARK: - C callbacks

private func streamPropertyProc(_ clientData: UnsafeMutableRawPointer,
                                _ streamID: AudioFileStreamID,
                                _ propertyID: AudioFileStreamPropertyID,
                                _ ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    Unmanaged<StreamAudioSource>.fromOpaque(clientData).takeUnretainedValue().handleProperty(propertyID)
}

private func streamPacketsProc(_ clientData: UnsafeMutableRawPointer,
                               _ numberBytes: UInt32, _ numberPackets: UInt32,
                               _ inputData: UnsafeRawPointer,
                               _ packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    Unmanaged<StreamAudioSource>.fromOpaque(clientData).takeUnretainedValue()
        .handlePackets(numberBytes, numberPackets, inputData, packetDescriptions)
}

private func decoderInputProc(_ converter: AudioConverterRef,
                              _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>,
                              _ outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                              _ inUserData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let inUserData else { ioNumberDataPackets.pointee = 0; return noErr }
    return Unmanaged<StreamAudioSource>.fromOpaque(inUserData).takeUnretainedValue()
        .supplyPackets(ioNumberDataPackets, ioData, outDataPacketDescription)
}
