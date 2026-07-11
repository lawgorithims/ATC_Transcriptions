import SwiftUI
import PDFKit

/// Renders a PDF (an FAA terminal-procedure plate) with PDFKit — pinch-zoom, scroll, native.
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true                       // fit-to-width, then free pinch-zoom
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .black
        v.minScaleFactor = 0.2
        v.maxScaleFactor = 8
        v.document = PDFDocument(url: url)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

/// Full-screen viewer for one approach/departure/arrival plate. Loads from the offline `PlateStore`
/// cache, downloading once if needed (with a spinner) and degrading to an offline notice if it isn't
/// cached and there's no signal. `onSendToMap` (when provided) offers the "overlay on the map" action.
struct PlateViewer: View {
    let procedure: AirportProcedure
    let airport: String
    let palette: Palette
    var onSendToMap: ((URL) -> Void)? = nil
    var onClose: () -> Void

    @State private var url: URL?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    PDFKitView(url: url).ignoresSafeArea(edges: .bottom)
                } else if loading {
                    ProgressView("Downloading plate…").tint(palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    offlineState
                }
            }
            .navigationTitle(procedure.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onClose() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(procedure.name).font(.headline).lineLimit(1)
                        Text(airport).font(.caption2).foregroundStyle(palette.textDim)
                    }
                }
                if let onSendToMap, let url {
                    ToolbarItem(placement: .primaryAction) {
                        Button { onSendToMap(url) } label: { Label("Overlay on map", systemImage: "map") }
                            .accessibilityIdentifier("plate-overlay-map")
                    }
                }
            }
        }
        .tint(palette.accent)
        .task { await load() }
    }

    private var offlineState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash").font(.system(size: 34)).foregroundStyle(palette.textDim)
            Text("Plate not downloaded").font(.headline).foregroundStyle(palette.text)
            Text("This plate isn’t cached yet and couldn’t be fetched. Connect to the internet once to download it, then it works offline.")
                .font(.caption).foregroundStyle(palette.textDim)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Try again") { Task { loading = true; await load() } }
                .buttonStyle(.borderedProminent).tint(palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        // Instant path: already cached.
        if let cached = PlateStore.localURL(procedure), FileManager.default.fileExists(atPath: cached.path) {
            url = cached; loading = false; return
        }
        let got = await PlateStore.ensureOnDisk(procedure)
        url = got
        loading = false
    }
}
