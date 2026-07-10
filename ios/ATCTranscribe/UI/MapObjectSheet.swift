import SwiftUI

/// Compact bottom-sheet presentation of `MapObjectView` — used by the legacy `RouteMapSheet` focused
/// map. The home map presents `MapObjectView` directly (side panel on regular, sheet on compact).
struct MapObjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let result: MapProbeResult
    var resolved: [ResolvedLeg] = []          // accepted for source compatibility; MapObjectView re-resolves
    var onCommit: () -> Void = {}

    var body: some View {
        NavigationStack {
            MapObjectView(result: result, onCommit: onCommit, onClose: { dismiss() })
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .tint(model.palette.accent)
        .preferredColorScheme(model.theme == .day ? .light : .dark)
    }
}
