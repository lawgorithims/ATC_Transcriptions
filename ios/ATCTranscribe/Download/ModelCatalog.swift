import Foundation

/// What kind of artifact a downloadable model is, which decides *how* it is fetched:
///  - `.whisperKit` — a WhisperKit CoreML model folder (the `.mlmodelc` set), pulled from a
///    HuggingFace repo via WhisperKit's native download API (built-in progress).
///  - `.ggufFile` — a single `*.gguf` file for the local llama.cpp context-fixer, pulled from a
///    direct HuggingFace `resolve` URL with a URLSession download task.
enum ModelKind: Sendable {
    case whisperKit
    case ggufFile
}

/// One downloadable artifact. The Whisper entries carry a `repo` + `variant` (the subfolder in
/// the HF repo); the GGUF entry carries a `directURL` + `fileName`. `required` marks the model
/// the app cannot transcribe without (gates first-launch onboarding).
struct ModelEntry: Identifiable, Sendable {
    let id: String
    let displayName: String
    let detail: String
    let kind: ModelKind
    let approxBytes: Int64
    let required: Bool

    // .whisperKit
    let repo: String?
    let variant: String?

    // .ggufFile
    let directURL: URL?
    let fileName: String?

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

/// The catalog of artifacts the app can download at runtime. The Whisper repo is the
/// WhisperKit-format HuggingFace repo the converted fine-tuned models are published to (see
/// `Tools/publish_models.md`); the GGUF defaults to the stock public Qwen repo already used by
/// `Tools/fetch_llm_model.sh`. Change `whisperRepo` to your repo before publishing the build.
enum ModelCatalog {
    /// HuggingFace repo holding the WhisperKit-format CoreML models, one subfolder per variant.
    /// Override at runtime with the `ATC_WHISPER_REPO` env var (Simulator/dev convenience).
    static var whisperRepo: String {
        ProcessInfo.processInfo.environment["ATC_WHISPER_REPO"] ?? "SingularityUS/atc-whisperkit"
    }

    static let small = ModelEntry(
        id: "small",
        displayName: "Small · fast",
        detail: "Fine-tuned ATC speech model — required to transcribe.",
        kind: .whisperKit, approxBytes: 465_000_000, required: true,
        repo: whisperRepo, variant: "small", directURL: nil, fileName: nil)

    static let turbo = ModelEntry(
        id: "turbo",
        displayName: "Large · higher accuracy",
        detail: "Higher accuracy, ~2× slower. Optional — used on capable devices.",
        kind: .whisperKit, approxBytes: 1_500_000_000, required: false,
        repo: whisperRepo, variant: "turbo", directURL: nil, fileName: nil)

    static let llm = ModelEntry(
        id: "llm",
        displayName: "AI context fixer (LLM)",
        detail: "Qwen2.5-0.5B — powers the optional on-device correction layer.",
        kind: .ggufFile, approxBytes: 400_000_000, required: false,
        repo: nil, variant: nil,
        directURL: URL(string: ProcessInfo.processInfo.environment["ATC_LLM_URL"]
            ?? "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"),
        fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf")

    static var all: [ModelEntry] { [small, turbo, llm] }
    /// The model whose absence blocks transcription (drives the first-launch gate).
    static var required: ModelEntry { small }
}

/// Resolves on-device storage for downloaded models. Models land in **Application Support**
/// (the app bundle is read-only), under `Models/whisper/<variant>/` and `Models/llm/<file>.gguf`.
/// `isReady` reuses the same markers the rest of the app already checks: `AudioEncoder.mlmodelc`
/// for a Whisper folder (see `TranscriberEngine.modelAvailable`) and a `*.gguf` for the LLM
/// (see `bundledLLMModelPath`).
enum ModelStore {
    /// Test seam: point the store at a temp directory in unit tests. Nil in the app.
    static var rootOverride: URL?

    static var root: URL {
        if let rootOverride { return rootOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    static func whisperDir(_ variant: String) -> URL {
        root.appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    static var llmDir: URL { root.appendingPathComponent("llm", isDirectory: true) }
    static func llmPath(_ fileName: String) -> URL { llmDir.appendingPathComponent(fileName) }

    /// The final on-device location an entry downloads to.
    static func localURL(for e: ModelEntry) -> URL {
        switch e.kind {
        case .whisperKit: return whisperDir(e.variant ?? e.id)
        case .ggufFile:   return llmPath(e.fileName ?? "\(e.id).gguf")
        }
    }

    static func isReady(_ e: ModelEntry) -> Bool {
        switch e.kind {
        case .whisperKit:
            let marker = whisperDir(e.variant ?? e.id).appendingPathComponent("AudioEncoder.mlmodelc")
            return FileManager.default.fileExists(atPath: marker.path)
        case .ggufFile:
            return FileManager.default.fileExists(atPath: localURL(for: e).path)
        }
    }

    // MARK: resolution helpers used by AppModel / LocalLLMCorrector

    /// Path of a downloaded Whisper model, preferring the larger `turbo` when both are present,
    /// or nil if none has been downloaded. Used to prefer a downloaded model over a bundled one.
    static func downloadedWhisperDir() -> String? {
        for variant in ["turbo", "small"] {
            let marker = whisperDir(variant).appendingPathComponent("AudioEncoder.mlmodelc")
            if FileManager.default.fileExists(atPath: marker.path) { return whisperDir(variant).path }
        }
        return nil
    }

    /// Path of the downloaded GGUF, or nil. Mirrors `bundledLLMModelPath`'s "first *.gguf" rule.
    static func downloadedLLMPath() -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: llmDir, includingPropertiesForKeys: nil) else { return nil }
        return items.first { $0.pathExtension.lowercased() == "gguf" }?.path
    }
}
