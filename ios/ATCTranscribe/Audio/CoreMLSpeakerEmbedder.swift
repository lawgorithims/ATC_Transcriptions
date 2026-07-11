import Foundation
import CoreML

/// On-device ECAPA-TDNN speaker embedder (Stage 5b): runs the Core ML model exported by
/// `python-legacy/dataset/export_ecapa_coreml.py` on the Apple Neural Engine to produce a 192-dim
/// voice embedding far stronger than the mean-MFCC fingerprint (a corpus study showed MFCC cannot
/// separate same-feed speakers).
///
/// INPUT CONTRACT: RAW 16 kHz mono audio. The exported model does the STFT + 80-mel fbank + sentence
/// normalization + ECAPA internally (verified cosine 1.0 vs the original), so there is NO Swift
/// feature front-end to keep in sync — the whole pipeline is correct by construction. The model takes
/// a fixed 3 s (`samples`) window; this class pads short clips / crops long ones. The model returns
/// the RAW embedding (the export omits the in-model L2-norm, which overflows fp16); this class
/// L2-normalizes it in Float.
///
/// FAIL-SAFE: if the model is not present or fails to load, `isAvailable` is false and `embed`
/// returns nil, so the caller falls back to MFCC — the same None-on-failure contract as the offline
/// `speaker_embed`. Actor-confined to `LivePipeline` (single-threaded use), like `SpeakerModel`.
///
/// CODING STANDARD (NASA/JPL "Power of Ten"): fixed loop bounds, a preallocated input buffer, input
/// validation with safe (nil) recovery, invariant asserts, no recursion, no function pointers.
final class CoreMLSpeakerEmbedder {
    static let samples = 48_000   // fixed model input length = 3 s @ 16 kHz; Swift pads/crops to this
    static let dims = 192
    private static let minSamples = 400   // reject clips < ~25 ms (matches the offline embedder)

    private let model: MLModel?
    private let input: MLMultiArray?   // preallocated [1, samples], reused every call

    var isAvailable: Bool { model != nil && input != nil }

    /// Load from an explicit compiled-model URL if given (probe/tests), else from the app bundle.
    init(modelURL: URL? = nil, modelName: String = "ECAPA") {
        // Resources/Models is bundled as a folder reference → the model lands under "Models/".
        let url = modelURL
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: "Models")
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
        var loaded: MLModel?
        if let url {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            loaded = try? MLModel(contentsOf: url, configuration: cfg)
        }
        model = loaded
        input = try? MLMultiArray(shape: [1, NSNumber(value: Self.samples)], dataType: .float32)
        assert(Self.samples > 0 && Self.dims > 0)
    }

    /// Embed raw 16 kHz mono audio → L2-normalized 192-dim vector, or nil if unavailable / too short.
    func embed(_ audio: [Float]) -> [Float]? {
        guard let model, let input else { return nil }
        guard audio.count >= Self.minSamples else { return nil }
        fill(input, from: audio)
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: ["waveform": MLFeatureValue(multiArray: input)]) else { return nil }
        guard let out = try? model.prediction(from: provider),
              let emb = out.featureValue(for: "embedding")?.multiArrayValue,
              emb.count == Self.dims else { return nil }
        return l2normalized(emb)
    }

    /// Copy audio into the preallocated model input, padding short clips / cropping long ones.
    private func fill(_ arr: MLMultiArray, from audio: [Float]) {
        assert(arr.count == Self.samples)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)   // dtype is .float32 (we own it)
        let n = min(audio.count, Self.samples)
        for i in 0..<n { ptr[i] = audio[i] }
        for i in n..<Self.samples { ptr[i] = 0 }   // pad the tail with silence
    }

    /// L2-normalize the raw embedding (dtype-agnostic read; the ANE may hand back fp16).
    private func l2normalized(_ arr: MLMultiArray) -> [Float]? {
        guard arr.count == Self.dims else { return nil }
        var sumSq: Float = 0
        for i in 0..<Self.dims { let v = arr[i].floatValue; sumSq += v * v }
        guard sumSq > 1e-12 else { return nil }
        let inv = 1 / sumSq.squareRoot()
        var out = [Float](repeating: 0, count: Self.dims)
        for i in 0..<Self.dims { out[i] = arr[i].floatValue * inv }
        assert(out.count == Self.dims)
        return out
    }
}
