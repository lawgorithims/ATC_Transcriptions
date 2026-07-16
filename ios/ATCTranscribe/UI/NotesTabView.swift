import SwiftUI
#if canImport(PencilKit)
import PencilKit
#endif

/// The "Notes" bottom tab (far right): hand-write notes with a finger or Apple Pencil and keep them in a
/// library. Two modes — a thumbnail LIBRARY of saved notes, and an EDITOR (a full-page PencilKit canvas
/// with the system tool palette). Content renders only while the tab is selected (opacity switch in
/// RootTabView) so the canvas/tool-picker cost nothing behind the map.
struct NotesTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var notes: NotesStore

    @State private var editing: EditingNote?
    #if canImport(PencilKit)
    @State private var drawing = PKDrawing()
    #endif
    @State private var confirmDelete: Note?
    @State private var dirty = false            // the canvas was actually modified this session
    @State private var clearToken = 0           // bumped by the eraser so updateUIView actually wipes the canvas

    /// The note currently open in the editor (a fresh one, or an existing note being re-opened).
    struct EditingNote: Identifiable {
        let id: String
        let createdAt: Date
        var title: String
        let isNew: Bool
    }

    var body: some View {
        Group {
            if model.selectedTab == .notes {
                content
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder private var content: some View {
        #if canImport(PencilKit)
        let p = model.palette
        ZStack {
            p.bg.ignoresSafeArea()
            if let note = editing {
                editor(note)
            } else {
                library
            }
        }
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .confirmationDialog("Delete this note?", isPresented: deletePresented, presenting: confirmDelete) { note in
            Button("Delete", role: .destructive) { notes.delete(note); if editing?.id == note.id { editing = nil } }
        }
        #else
        Text("Notes require PencilKit.").foregroundStyle(model.palette.textDim)
        #endif
    }

    // MARK: library

    #if canImport(PencilKit)
    private var library: some View {
        let p = model.palette
        return VStack(spacing: 0) {
            HStack {
                Text("Notes").font(.title2.weight(.bold)).foregroundStyle(p.text)
                Spacer()
                Button { newNote() } label: {
                    Label("New note", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(p.accent)).foregroundStyle(.white)
                }
                .buttonStyle(.plainHaptic).accessibilityIdentifier("notes-new")
            }
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            Rectangle().fill(p.border).frame(height: 0.5)

            if notes.notes.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(notes.notes) { note in tile(note) }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var emptyLibrary: some View {
        let p = model.palette
        return VStack(spacing: 12) {
            Image(systemName: "pencil.and.scribble").font(.system(size: 40)).foregroundStyle(p.textDim.opacity(0.7))
            Text("No notes yet.").foregroundStyle(p.textDim)
            Text("Tap “New note” to jot down a clearance, frequency, or a quick diagram with your finger or Apple Pencil.")
                .font(.caption).foregroundStyle(p.textDim.opacity(0.85))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    private func tile(_ note: Note) -> some View {
        let p = model.palette
        return Button { openNote(note) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let thumb = notes.thumbnail(note.id) {
                        Image(uiImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(red: 0.98, green: 0.97, blue: 0.94))
                    }
                }
                .frame(height: 150).frame(maxWidth: .infinity).clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title).font(.subheadline.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(p.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(p.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("note-tile")
        .contextMenu {
            Button(role: .destructive) { confirmDelete = note } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: editor

    private func editor(_ note: EditingNote) -> some View {
        let p = model.palette
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { cancelEdit() } label: {
                    Label("Library", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plainHaptic).foregroundStyle(p.accent).accessibilityIdentifier("notes-back")
                TextField("Title", text: Binding(get: { editing?.title ?? "" },
                                                 set: { editing?.title = $0 }))
                    .textFieldStyle(.plain).font(.headline).foregroundStyle(p.text)
                    .frame(maxWidth: 320)
                Spacer()
                Button { clearCanvas() } label: { Image(systemName: "eraser.line.dashed") }
                    .buttonStyle(.plainHaptic).foregroundStyle(p.textDim).accessibilityIdentifier("notes-clear")
                if !note.isNew {
                    Button { confirmDelete = notes.notes.first { $0.id == note.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plainHaptic).foregroundStyle(p.bad).accessibilityIdentifier("notes-delete")
                }
                Button { saveEdit() } label: {
                    Text("Done").font(.subheadline.weight(.bold))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(p.accent)).foregroundStyle(.white)
                }
                .buttonStyle(.plainHaptic).accessibilityIdentifier("notes-done")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(p.surface)
            Rectangle().fill(p.border).frame(height: 0.5)

            // Paper behind the transparent ink canvas so strokes read in any theme.
            NoteCanvas(drawing: $drawing, clearToken: clearToken, onEdited: { dirty = true })
                .background(Color(red: 0.98, green: 0.97, blue: 0.94))
                .id(note.id)                                  // rebuild the canvas when switching notes
                .accessibilityIdentifier("note-canvas")
        }
    }

    // MARK: actions

    private func newNote() {
        drawing = PKDrawing(); dirty = false; clearToken = 0
        editing = EditingNote(id: NotesStore.newID(), createdAt: Date(), title: "", isNew: true)
    }

    private func openNote(_ note: Note) {
        drawing = (notes.drawingData(note.id).flatMap { try? PKDrawing(data: $0) }) ?? PKDrawing()
        dirty = false; clearToken = 0
        editing = EditingNote(id: note.id, createdAt: note.createdAt, title: note.title, isNew: false)
    }

    private func clearCanvas() { drawing = PKDrawing(); dirty = true; clearToken += 1 }

    private func cancelEdit() { saveEdit() }   // saveEdit guards both empty-new and unmodified-existing

    private func saveEdit() {
        guard let note = editing else { return }
        // Never write over an existing note the pilot didn't modify this session — this is what protects a
        // note whose ink failed to load (blank fallback canvas) from clobbering the real file. And don't
        // persist a brand-new note with no strokes.
        if note.isNew, drawing.strokes.isEmpty { editing = nil; return }
        if !note.isNew, !dirty { editing = nil; return }
        let now = Date()
        let data = drawing.dataRepresentation()
        let thumb = Self.thumbnail(from: drawing).pngData()
        notes.save(id: note.id, title: note.title, drawing: data, thumbnail: thumb,
                   createdAt: note.createdAt, now: now)
        editing = nil
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    /// A library thumbnail from a drawing: the ink's content box fit onto a paper card (blank paper when
    /// there are no strokes yet). Rendered off the live canvas so it survives closing the editor.
    static func thumbnail(from drawing: PKDrawing, target: CGSize = CGSize(width: 480, height: 340)) -> UIImage {
        let paper = UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { ctx in
            paper.setFill(); ctx.fill(CGRect(origin: .zero, size: target))
            let content = drawing.bounds
            guard content.width > 1, content.height > 1 else { return }
            let ink = drawing.image(from: content, scale: 2)
            let pad: CGFloat = 16
            let box = CGRect(origin: .zero, size: target).insetBy(dx: pad, dy: pad)
            let s = min(box.width / content.width, box.height / content.height, 3)
            let w = content.width * s, h = content.height * s
            ink.draw(in: CGRect(x: (target.width - w) / 2, y: (target.height - h) / 2, width: w, height: h))
        }
    }
    #endif
}

#if canImport(PencilKit)
/// A full-page PencilKit canvas with the system tool palette. Accepts finger AND pencil input
/// (`drawingPolicy = .anyInput`) so a Stratux-less iPad without a Pencil still works. The live drawing
/// is streamed back into the SwiftUI binding via the delegate so the editor can save it.
struct NoteCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var clearToken: Int = 0                 // bump to WIPE the visible canvas (the eraser button)
    var onEdited: () -> Void = {}           // fired when the pilot actually changes the ink (dirty tracking)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        context.coordinator.lastClearToken = clearToken
        let picker = context.coordinator.toolPicker
        picker.setVisible(true, forFirstResponder: canvas)
        picker.addObserver(canvas)
        DispatchQueue.main.async { canvas.becomeFirstResponder() }   // required for the palette to appear
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // The canvas owns the live drawing (the binding is written FROM it; `.id(note.id)` rebuilds on a
        // note switch). The ONE state->canvas push we honour is an explicit eraser wipe, tracked by a token
        // so a generic re-render can't clobber in-progress ink.
        if clearToken != context.coordinator.lastClearToken {
            context.coordinator.lastClearToken = clearToken
            canvas.drawing = PKDrawing()
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let parent: NoteCanvas
        let toolPicker = PKToolPicker()
        var lastClearToken = 0
        init(_ parent: NoteCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            parent.onEdited()
        }
    }
}
#endif
