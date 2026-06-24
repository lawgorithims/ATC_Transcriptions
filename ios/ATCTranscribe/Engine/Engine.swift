import Foundation

/// Token-level normalized Word Error Rate. Port of `engine._word_error_rate` /
/// `_normalize`: lowercase, keep alphanumerics, drop articles (a/an/the), then
/// token Levenshtein distance divided by the reference length.
enum WER {
    private static let articles: Set<String> = ["a", "an", "the"]

    static func normalize(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).compactMap { raw -> String? in
            let tok = String(raw.filter { $0.isLetter || $0.isNumber })
            return (!tok.isEmpty && !articles.contains(tok)) ? tok : nil
        }
    }

    static func rate(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        if ref.isEmpty { return hyp.isEmpty ? 0.0 : 1.0 }
        var prev = Array(0...hyp.count)
        for (i, r) in ref.enumerated() {
            var cur = [i + 1]
            for (j, h) in hyp.enumerated() {
                let cost = (r == h) ? 0 : 1
                cur.append(Swift.min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost))
            }
            prev = cur
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }
}

/// A labeled diagnostic clip: decoded mono-16 kHz audio + its reference transcript.
struct DiagnosticClip {
    let file: String
    let reference: String
    let audio: [Float]
    var audioSeconds: Double { Double(audio.count) / 16000.0 }
}

/// One scored proof-of-life clip. Mirrors an entry of `engine._time_snippets`.
struct ProofOfLifeSnippet: Equatable {
    let file: String
    let reference: String
    let hypothesis: String
    let wer: Double
    let seconds: Double
    let audioSeconds: Double
    let ok: Bool
}

/// Result of a proof-of-life run. Port of `engine.proof_of_life`'s payload.
struct ProofOfLifeResult {
    var passed = false
    var activeModel: String?
    var meanWER: Double?
    var realtimeSpeed: Double?
    var snippets: [ProofOfLifeSnippet] = []
    var error: String?
}

enum EngineError: Error { case unknownModel(String), modelNotFound(String, String) }

/// Owns the *active* fine-tuned Whisper model (exactly one resident) and shares it
/// between the proof-of-life check and the live session. Supports a larger `turbo`
/// default and a smaller `small` fallback with an adaptive startup benchmark that
/// downgrades on devices slower than `minRealtimeSpeed`. Swift port of
/// `server/engine.py:TranscriberEngine` (model registry, adaptive selection,
/// proof-of-life). Audio loading / manifest parsing is left to the caller.
actor TranscriberEngine {
    private let models: [String: String]      // name -> converted CoreML model folder
    let defaultModel: String
    let fallbackModel: String
    private(set) var minRealtimeSpeed: Double
    let adaptive: Bool
    let maxWER: Double
    private let cpuOnly: Bool                  // true on the iOS Simulator (no ANE)

    private var activeName: String?
    private var active: ATCTranscriber?
    private(set) var autoDowngraded = false
    private(set) var measuredSpeed: Double?
    private var selected = false

    init(models: [String: String],
         defaultModel: String = "turbo",
         fallbackModel: String = "small",
         minRealtimeSpeed: Double = 1.2,
         adaptive: Bool = true,
         maxWER: Double = 0.5,
         cpuOnly: Bool = false) {
        self.models = models
        self.defaultModel = models[defaultModel] != nil ? defaultModel : (models.keys.sorted().first ?? defaultModel)
        self.fallbackModel = models[fallbackModel] != nil ? fallbackModel : self.defaultModel
        self.minRealtimeSpeed = minRealtimeSpeed
        self.adaptive = adaptive
        self.maxWER = maxWER
        self.cpuOnly = cpuOnly
    }

    var activeModel: String? { activeName }

    /// A converted model is "available" if its folder holds the CoreML bundles.
    func modelAvailable(_ name: String) -> Bool {
        guard let folder = models[name] else { return false }
        return FileManager.default.fileExists(
            atPath: (folder as NSString).appendingPathComponent("AudioEncoder.mlmodelc"))
    }

    /// Load `name`, dropping the current model first so only one is ever resident.
    /// Port of `load_model`.
    @discardableResult
    func loadModel(_ name: String) async throws -> ATCTranscriber {
        guard let folder = models[name] else { throw EngineError.unknownModel(name) }
        if activeName == name, let active { return active }
        active = nil; activeName = nil                       // free current before loading next
        guard modelAvailable(name) else { throw EngineError.modelNotFound(name, folder) }
        let transcriber = ATCTranscriber(modelFolder: folder, cpuOnly: cpuOnly)
        try await transcriber.load()
        active = transcriber
        activeName = name
        return transcriber
    }

    /// Active transcriber, running adaptive selection on first use. Port of `get_transcriber`.
    func transcriber() async throws -> ATCTranscriber {
        if let active { return active }
        if adaptive && !selected {
            try await autoSelect(benchmarkAudio: nil)
            if let active { return active }
        }
        return try await loadModel(activeName ?? defaultModel)
    }

    /// Real-time speed (audio seconds / best processing seconds) on a representative
    /// clip, after a warmup pass. Port of `_measure_speed`.
    func measureSpeed(audio: [Float], warmup: Int = 1, passes: Int = 2) async -> Double {
        guard let transcriber = active, !audio.isEmpty else { return 0.0 }
        let duration = Double(audio.count) / 16000.0
        for _ in 0..<max(1, warmup) { _ = try? await transcriber.transcribe(audio) }
        var best: Double?
        for _ in 0..<max(1, passes) {
            let start = Date()
            _ = try? await transcriber.transcribe(audio)
            let secs = Date().timeIntervalSince(start)
            best = best.map { Swift.min($0, secs) } ?? secs
        }
        guard let b = best, b > 0 else { return 0.0 }
        return duration / b
    }

    /// Load the default model and, if adaptive, downgrade to the fallback when the
    /// device is slower than `minRealtimeSpeed` on `benchmarkAudio`. Port of `auto_select`.
    func autoSelect(benchmarkAudio: [Float]?) async throws {
        autoDowngraded = false
        measuredSpeed = nil
        defer { selected = true }

        if !modelAvailable(defaultModel) {
            if modelAvailable(fallbackModel) { try await loadModel(fallbackModel) }
            return
        }
        try await loadModel(defaultModel)
        guard adaptive, let benchmarkAudio else { return }

        let speed = await measureSpeed(audio: benchmarkAudio)
        measuredSpeed = speed
        if speed < minRealtimeSpeed, fallbackModel != defaultModel, modelAvailable(fallbackModel) {
            try await loadModel(fallbackModel)
            autoDowngraded = true
        }
    }

    /// Manually force `name` (unloads the other). Port of `override`.
    func override(_ name: String) async throws {
        try await loadModel(name)
        selected = true
        autoDowngraded = false
    }

    func setMinRealtimeSpeed(_ value: Double) { minRealtimeSpeed = Swift.max(0, value) }

    /// Run `maxSnippets` bundled clips through the active model and report PASS/FAIL +
    /// mean WER + real-time speed. Port of `proof_of_life` / `_time_snippets`.
    func proofOfLife(clips: [DiagnosticClip], maxSnippets: Int = 2) async -> ProofOfLifeResult {
        var result = ProofOfLifeResult()
        let transcriber: ATCTranscriber
        do { transcriber = try await self.transcriber() } catch {
            result.error = "Model failed to load: \(error)"
            return result
        }
        result.activeModel = activeName

        let use = Array(clips.prefix(maxSnippets))
        if let first = use.first { _ = try? await transcriber.transcribe(first.audio) }   // warmup

        var scored: [ProofOfLifeSnippet] = []
        var totalAudio = 0.0, totalProc = 0.0
        for clip in use {
            let start = Date()
            let hyp = (try? await transcriber.transcribe(clip.audio)) ?? ""
            let secs = Date().timeIntervalSince(start)
            totalAudio += clip.audioSeconds
            totalProc += secs
            scored.append(ProofOfLifeSnippet(
                file: clip.file, reference: clip.reference, hypothesis: hyp,
                wer: WER.rate(reference: clip.reference, hypothesis: hyp),
                seconds: secs, audioSeconds: clip.audioSeconds,
                ok: !hyp.trimmingCharacters(in: .whitespaces).isEmpty))
        }

        let usable = scored.filter(\.ok)
        let meanWER = usable.isEmpty ? 1.0 : usable.map(\.wer).reduce(0, +) / Double(usable.count)
        result.snippets = scored
        result.meanWER = meanWER
        result.realtimeSpeed = totalProc > 0 ? totalAudio / totalProc : 0.0
        result.passed = !scored.isEmpty && scored.allSatisfy(\.ok) && meanWER <= maxWER
        return result
    }
}
