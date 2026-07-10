import SwiftUI

/// Map search: find any airport, navaid, or fix by identifier or name, then center the map on it and
/// open its info sheet (same actions as a tap). Backed by `MapSearch`; debounced off-main.
struct MapSearchSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (IdentifiedObject) -> Void
    var initialQuery = ""                          // screenshot/demo affordance (`--search`)

    @State private var query = ""
    @State private var results: [IdentifiedObject] = []
    @FocusState private var focused: Bool

    var body: some View {
        let p = model.palette
        NavigationStack {
            VStack(spacing: 0) {
                field(p)
                if query.isEmpty {
                    ContentUnavailableView("Search the map", systemImage: "magnifyingglass",
                                           description: Text("Find any airport, VOR, or fix by identifier or name."))
                } else if results.isEmpty {
                    ContentUnavailableView("No matches", systemImage: "questionmark.circle",
                                           description: Text("Try an identifier (KBOS, BOS) or a name (Logan)."))
                } else {
                    List(results) { o in
                        Button { onPick(o) } label: { row(o, p) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(p.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
        .onChange(of: query) { _, q in refresh(q) }
        .onAppear {
            if !initialQuery.isEmpty { query = initialQuery } else { focused = true }
        }
    }

    private func field(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(p.textDim)
            TextField("Identifier or name", text: $query)
                .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.characters)
                .submitLabel(.search).foregroundStyle(p.text)
                .accessibilityIdentifier("map-search-field")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(p.textDim) }
                    .buttonStyle(.plain)
            }
        }
        .padding(10).background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border, lineWidth: 1))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func row(_ o: IdentifiedObject, _ p: Palette) -> some View {
        HStack(spacing: 10) {
            badge(o.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(o.ident).font(.system(.body, design: .monospaced)).foregroundStyle(p.text)
                if let sub = subtitle(o) { Text(sub).font(.caption).foregroundStyle(p.textDim).lineLimit(1) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(p.textDim)
        }
    }

    private func subtitle(_ o: IdentifiedObject) -> String? {
        switch o.kind {
        case .airport: return NavMeta.airport(o.ident)?.name ?? "Airport"
        case .vor:     return NavMeta.navaid(o.ident).map { [$0.name, $0.typeLabel].compactMap { $0 }.joined(separator: " · ") } ?? "Navaid"
        case .fix:     return "Fix"
        default:       return o.kind.label
        }
    }

    private func refresh(_ q: String) {
        Task {
            let r = await Task.detached(priority: .userInitiated) { MapSearch.results(q) }.value
            if q == query { results = r }        // ignore stale responses
        }
    }

    private func badge(_ kind: MapObjectKind) -> some View {
        let color: Color = {
            switch kind {
            case .airport: return .hex(0xE879F9)
            case .vor:     return .hex(0x34D399)
            case .fix:     return .hex(0x60A5FA)
            default:       return .gray
            }
        }()
        let icon: String = {
            switch kind {
            case .airport: return "airplane"
            case .vor:     return "hexagon"
            case .fix:     return "triangle"
            default:       return "mappin"
            }
        }()
        return ZStack {
            Circle().fill(color).frame(width: 26, height: 26)
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
        }
    }
}
