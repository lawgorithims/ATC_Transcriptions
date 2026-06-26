import Foundation
import SwiftUI
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Per-model download state surfaced to the UI (progress bar + "ready" confirmation).
enum DownloadState: Equatable {
    case notDownloaded
    case downloading(Double)   // 0.0 ... 1.0
    case ready
    case failed(String)
}

enum ModelDownloadError: LocalizedError {
    case unsupported
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Downloading is not supported in this build."
        }
    }
}

/// Abstraction over the actual byte transfer so the manager's state machine is unit-testable
/// without a network (tests inject a fake; the app uses `LiveModelDownloader`). `progress`
/// reports a 0...1 fraction and may be called from a background thread.
protocol ModelDownloading: Sendable {
    func downloadWhisper(variant: String, repo: String, into dest: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws
    func downloadFile(from url: URL, to dest: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Drives model downloads and publishes their progress. Owns one in-flight `Task` per model id so
/// the UI can show a live progress bar, cancel, or re-download. On success it flips the model to
/// `.ready` and fires `onReady` so `AppModel` can load a model that wasn't present at launch.
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var states: [String: DownloadState] = [:]

    /// Called on the main actor when a model finishes downloading (wire to `AppModel`).
    var onReady: ((ModelEntry) -> Void)?

    private let downloader: ModelDownloading
    private var tasks: [String: Task<Void, Never>] = [:]

    init(downloader: ModelDownloading = LiveModelDownloader()) {
        self.downloader = downloader
        refreshStates()
    }

    /// Reconcile published state with what's actually on disk (skips models mid-download).
    func refreshStates() {
        for e in ModelCatalog.all {
            if case .downloading = states[e.id] { continue }
            states[e.id] = ModelStore.isReady(e) ? .ready : .notDownloaded
        }
    }

    func state(_ id: String) -> DownloadState { states[id] ?? .notDownloaded }

    /// Start (or no-op if already running) the download for `e`. Returns the backing task so
    /// tests can await completion; the UI ignores the return value.
    @discardableResult
    func download(_ e: ModelEntry) -> Task<Void, Never>? {
        guard tasks[e.id] == nil else { return tasks[e.id] }
        states[e.id] = .downloading(0)
        let downloader = self.downloader
        let task = Task { [weak self] in
            // Apply progress only while still downloading, so a late tick (the transfer's final
            // callbacks race the completion hop) can't resurrect a `.ready`/`.failed` state.
            let report: @Sendable (Double) -> Void = { f in
                Task { @MainActor in
                    guard let self, case .downloading = self.states[e.id] else { return }
                    self.states[e.id] = .downloading(min(max(f, 0), 1))
                }
            }
            do {
                switch e.kind {
                case .whisperKit:
                    try await downloader.downloadWhisper(variant: e.variant ?? e.id, repo: e.repo ?? ModelCatalog.whisperRepo,
                                                         into: ModelStore.whisperDir(e.variant ?? e.id), progress: report)
                case .ggufFile:
                    guard let url = e.directURL else { throw ModelDownloadError.unsupported }
                    try await downloader.downloadFile(from: url, to: ModelStore.localURL(for: e), progress: report)
                }
                await self?.finish(e.id, .ready, entry: e)
            } catch is CancellationError {
                await self?.finish(e.id, ModelStore.isReady(e) ? .ready : .notDownloaded, entry: nil)
            } catch {
                await self?.finish(e.id, .failed(error.localizedDescription), entry: nil)
            }
        }
        tasks[e.id] = task
        return task
    }

    func cancel(_ e: ModelEntry) {
        tasks[e.id]?.cancel()
    }

    private func finish(_ id: String, _ state: DownloadState, entry: ModelEntry?) {
        tasks[id] = nil
        states[id] = state
        if case .ready = state, let entry { onReady?(entry) }
    }
}

// MARK: - Live downloader (WhisperKit HF download + URLSession file download)

/// The production `ModelDownloading`: Whisper folders via WhisperKit's HuggingFace download,
/// single files via a delegate-backed URLSession download task (byte-level progress + cancel).
struct LiveModelDownloader: ModelDownloading {
    func downloadWhisper(variant: String, repo: String, into dest: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(WhisperKit)
        // Download into a temp hub base we control, then atomically move the model folder into
        // its Application Support home. NOTE: this is the one spot coupled to WhisperKit's
        // download signature — if the pinned argmax-oss-swift exposes different labels, adjust
        // here only (every other file is independent of it), mirroring LlamaContext's note.
        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-dl", isDirectory: true)
        let src = try await WhisperKit.download(
            variant: variant,
            downloadBase: tmpBase,
            useBackgroundSession: false,
            from: repo,
            progressCallback: { p in progress(p.fractionCompleted) })
        try FileIO.replace(dest, with: src)
        #else
        throw ModelDownloadError.unsupported
        #endif
    }

    func downloadFile(from url: URL, to dest: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        try await FileDownloader(dest: dest, progress: progress).run(url: url)
    }
}

enum FileIO {
    /// Move `src` to `dest`, replacing any existing item and creating parent dirs.
    static func replace(_ dest: URL, with src: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: src, to: dest)
    }
}

/// One-shot URLSession download with byte-level progress, cancellation, and an atomic move of
/// the finished file into `dest`. The completion is bridged to async via a continuation.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(dest: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.dest = dest
        self.progress = progress
        super.init()
    }

    func run(url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.continuation = c
                let t = session.downloadTask(with: url)
                self.task = t
                t.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Must move synchronously — `location` is deleted when this delegate call returns.
        do {
            try FileIO.replace(dest, with: location)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }   // success path already resumed in didFinishDownloadingTo
        if (error as NSError).code == NSURLErrorCancelled {
            continuation?.resume(throwing: CancellationError())
        } else {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
