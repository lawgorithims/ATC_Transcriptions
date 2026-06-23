import Foundation
import AVFoundation
import MediaToolbox

/// Decodes a live HTTP/Icecast MP3 ATC stream to mono 16 kHz PCM and feeds the pipeline.
/// AVPlayer owns the network streaming + reconnection; an `MTAudioProcessingTap` pulls
/// the decoded PCM out of the playback graph (the player is muted, so nothing is played
/// aloud unless `listen` is enabled). The Swift counterpart of the Python ffmpeg decode.
///
/// NOTE: implemented but **live-feed/device validation pending** — remote-stream taps and
/// the availability of a given LiveATC feed are hard to verify headlessly.
final class StreamAudioSource: AudioSource {
    private let url: URL
    private let listen: Bool
    private var player: AVPlayer?
    fileprivate var continuation: AsyncStream<[Float]>.Continuation?
    fileprivate var converter: AVAudioConverter?
    fileprivate let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 16000, channels: 1, interleaved: false)!

    init(url: URL, listen: Bool = false) {
        self.url = url
        self.listen = listen
    }

    func makeStream() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            self.continuation = continuation
            let asset = AVURLAsset(url: url)
            Task { [weak self] in
                let track = try? await asset.loadTracks(withMediaType: .audio).first
                await MainActor.run { self?.attach(asset: asset, track: track) }
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    @MainActor private func attach(asset: AVURLAsset, track: AVAssetTrack?) {
        let item = AVPlayerItem(asset: asset)
        if let track, let tap = makeTap() {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
        let player = AVPlayer(playerItem: item)
        player.isMuted = !listen
        self.player = player
        player.play()
    }

    func stop() {
        player?.pause()
        player = nil
        continuation?.finish()
        continuation = nil
    }

    private func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare,
            unprepare: tapUnprepare, process: tapProcess)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else { return nil }
        return tap
    }

    fileprivate func emit(_ samples: [Float]) { continuation?.yield(samples) }
}

// MARK: - MTAudioProcessingTap C callbacks

private func tapInit(_ tap: MTAudioProcessingTap,
                     _ clientInfo: UnsafeMutableRawPointer?,
                     _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {}

private func tapPrepare(_ tap: MTAudioProcessingTap,
                        _ maxFrames: CMItemCount,
                        _ processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let source = Unmanaged<StreamAudioSource>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    var asbd = processingFormat.pointee
    if let inputFormat = AVAudioFormat(streamDescription: &asbd) {
        source.converter = AVAudioConverter(from: inputFormat, to: source.target)
    }
}

private func tapUnprepare(_ tap: MTAudioProcessingTap) {}

private func tapProcess(_ tap: MTAudioProcessingTap,
                        _ numberFrames: CMItemCount,
                        _ flags: MTAudioProcessingTapFlags,
                        _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut) == noErr
    else { return }
    let source = Unmanaged<StreamAudioSource>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    guard let converter = source.converter,
          let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, bufferListNoCopy: bufferListInOut, deallocator: nil)
    else { return }
    input.frameLength = AVAudioFrameCount(numberFrames)

    let ratio = source.target.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(numberFrames) * ratio) + 16
    guard let output = AVAudioPCMBuffer(pcmFormat: source.target, frameCapacity: capacity) else { return }

    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return input
    }
    if let channel = output.floatChannelData, output.frameLength > 0 {
        source.emit(Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength))))
    }
}
