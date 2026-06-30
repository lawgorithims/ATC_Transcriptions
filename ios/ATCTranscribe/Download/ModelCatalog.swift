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
    /// The model's name as shown in the download list (with `detail` as the subtitle). Kept the SAME
    /// as `shortLabel` for the speech models so a model reads identically everywhere (download list,
    /// picker, badges, loading states); the descriptor lives in `detail`.
    let displayName: String
    /// Compact name for the active-model picker / status badges / loading states (e.g. "Large V2").
    let shortLabel: String
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

    /// HuggingFace repo + variant subfolder for the optional **stock** (non-fine-tuned) speech model
    /// ("Large V2" in the UI). Defaults to WhisperKit's own public catalog, where OpenAI's
    /// large-v3-turbo is already converted to CoreML — so this model needs **no** conversion/upload
    /// (unlike the fine-tuned ones). Override either with an env var for a self-hosted copy.
    static var cleanRepo: String {
        // Same repo as the fine-tuned models — the stock build is hosted alongside them.
        ProcessInfo.processInfo.environment["ATC_CLEAN_REPO"] ?? whisperRepo
    }
    static var cleanVariant: String {
        // Stock OpenAI large-v3-turbo converted through OUR OWN pipeline (Tools/convert_to_coreml.sh),
        // on-device-optimized exactly like the fine-tuned models — so it loads + transcribes at
        // fine-tuned speed instead of the slow generic Argmax build (which took minutes to load and ran
        // the ANE hot on an M2 iPad Air). Hosted as the `stockturbo` variant; see publish_models.md §1b.
        ProcessInfo.processInfo.environment["ATC_CLEAN_VARIANT"] ?? "stockturbo"
    }

    static let small = ModelEntry(
        id: "small",
        displayName: "Small",
        shortLabel: "Small",
        detail: "Fast, fine-tuned ATC speech model — required to transcribe.",
        kind: .whisperKit, approxBytes: 465_000_000, required: true,
        // variant `small-v2`: US-fine-tuned whisper-small (re-trained 2026-06). Bumping the
        // variant folder forces existing installs (which cache-lock by folder presence, no version
        // field) to re-download the new model on update. Old `small/` is kept on HF for rollback.
        repo: whisperRepo, variant: "small-v2", directURL: nil, fileName: nil)

    static let turbo = ModelEntry(
        id: "turbo",
        displayName: "Large",
        shortLabel: "Large",
        detail: "Fine-tuned, higher accuracy, ~2× slower. Optional — used on capable devices.",
        kind: .whisperKit, approxBytes: 1_500_000_000, required: false,
        repo: whisperRepo, variant: "turbo", directURL: nil, fileName: nil)

    /// Stock OpenAI large-v3-turbo (no ATC fine-tuning) for real-world A/B comparison against the
    /// fine-tuned `turbo`. Same architecture/size as `turbo`; its on-disk folder is the long
    /// WhisperKit variant id, so it's resolved through `variant` (≠ its short `id`) everywhere.
    static let cleanturbo = ModelEntry(
        id: "cleanturbo",
        displayName: "Large V2",
        shortLabel: "Large V2",
        detail: "Stock OpenAI large-v3-turbo (no ATC fine-tuning), converted for on-device speed like the fine-tuned models. Optional; for real-world accuracy comparison.",
        kind: .whisperKit, approxBytes: 1_500_000_000, required: false,   // on-device fp16 ≈ 1.5 GB
        repo: cleanRepo, variant: cleanVariant, directURL: nil, fileName: nil)

    static let llm = ModelEntry(
        id: "llm",
        displayName: "AI context fixer",
        shortLabel: "AI fixer",
        detail: "Powers the on-device transcript correction layer. Installed automatically with the speech model.",
        kind: .ggufFile, approxBytes: 400_000_000, required: false,
        repo: nil, variant: nil,
        directURL: URL(string: ProcessInfo.processInfo.environment["ATC_LLM_URL"]
            ?? "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf"),
        fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf")

    static var all: [ModelEntry] { [small, turbo, cleanturbo, llm] }
    /// The selectable transcription (Whisper) models, in UI/picker order (smallest → largest).
    static var whisperEntries: [ModelEntry] { [small, turbo, cleanturbo] }
    /// The model whose absence blocks transcription (drives the first-launch gate).
    static var required: ModelEntry { small }

    /// Friendly short label for a model id (e.g. "small" → "Small", "cleanturbo" → "Large V2"), for
    /// status badges / sidebar where only the persisted id is on hand. Falls back to the raw id.
    static func shortLabel(forID id: String) -> String {
        all.first { $0.id == id }?.shortLabel ?? id
    }
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

    /// Path of a downloaded Whisper model, or nil if none has been downloaded. Used to prefer a
    /// downloaded model over a bundled one. Preference order: the fine-tuned models (the app's
    /// reason for being) first — larger `turbo`, then `small` — then the optional stock "Large V2".
    /// Iterates catalog entries (not bare variant strings) so each entry's own `variant` folder is
    /// checked; the stock model's on-disk folder name differs from its short id.
    static func downloadedWhisperDir() -> String? {
        for e in [ModelCatalog.turbo, ModelCatalog.small, ModelCatalog.cleanturbo] where isReady(e) {
            return localURL(for: e).path
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
