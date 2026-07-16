import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One saved hand-written note. The drawing itself (a PencilKit `PKDrawing`) and a rendered thumbnail
/// live in separate files keyed by `id`; this is just the library metadata (persisted as an index).
struct Note: Identifiable, Codable, Equatable {
    let id: String                 // UUID string — also the drawing/thumbnail filename stem
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

/// The note library: metadata index + per-note drawing/thumbnail files under Documents/Notes. Storage
/// is format-agnostic (raw `Data` in, raw `Data` out) so this file never imports PencilKit — the Notes
/// view owns the `PKDrawing` ↔ `Data` conversion. A missing/corrupt store degrades to empty.
@MainActor final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []      // newest-updated first

    private let dir: URL
    private let indexURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = docs.appendingPathComponent("Notes", isDirectory: true)
        indexURL = dir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        notes = loadIndex()
    }

    // MARK: reads

    func drawingData(_ id: String) -> Data? { try? Data(contentsOf: drawingURL(id)) }

    #if canImport(UIKit)
    func thumbnail(_ id: String) -> UIImage? {
        guard let data = try? Data(contentsOf: thumbURL(id)) else { return nil }
        return UIImage(data: data)
    }
    #endif

    // MARK: writes

    /// Create-or-update a note: write the drawing + thumbnail, upsert the index (moved to the front by
    /// updatedAt). `title` empty → a date-stamped default so the library never shows a blank tile.
    func save(id: String, title: String, drawing: Data, thumbnail: Data?, createdAt: Date, now: Date) {
        assert(!id.isEmpty, "note id must be non-empty")
        try? drawing.write(to: drawingURL(id), options: .atomic)
        if let thumbnail { try? thumbnail.write(to: thumbURL(id), options: .atomic) }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = notes.filter { $0.id != id }
        next.insert(Note(id: id, title: name.isEmpty ? Self.defaultTitle(now) : name,
                         createdAt: createdAt, updatedAt: now), at: 0)
        notes = next
        persistIndex()
    }

    func delete(_ note: Note) {
        try? FileManager.default.removeItem(at: drawingURL(note.id))
        try? FileManager.default.removeItem(at: thumbURL(note.id))
        notes.removeAll { $0.id == note.id }
        persistIndex()
    }

    /// A fresh note id — the caller creates the drawing, then calls `save`.
    static func newID() -> String { UUID().uuidString }

    static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return "Note · \(f.string(from: date))"
    }

    // MARK: storage

    private func drawingURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).drawing") }
    private func thumbURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).png") }

    private func loadIndex() -> [Note] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Note].self, from: data) else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
