import SwiftUI

/// The key and the caveat for the "where not to go" map, in the layers panel. The caveat is not
/// small print: unshaded ground is NOT safe ground, and the reasons it might not be are named.
struct AvoidLegend: View {
    let palette: Palette
    let theme: AppTheme
    let showCover: Bool
    @ObservedObject private var library = AvoidMapLibrary.shared

    private var rows: [(String, AvoidReason)] {
        var r: [(String, AvoidReason)] = [("Power lines, towers, turbines", .wires), ("Solar farms", .solar),
                                          ("Orchards, vineyards, hop poles", .orchard), ("Steep ground", .steep)]
        if showCover { r.append(("Trees, water, built-up areas", .trees)) }
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.0) { title, reason in
                HStack(spacing: 8) {
                    let c = AvoidTileRenderer.colour(reason, theme: theme)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: c.0, green: c.1, blue: c.2).opacity(max(c.3, 0.5)))
                        .frame(width: 18, height: 10)
                    Text(title).font(.dsLabelS).foregroundStyle(palette.text)
                }
            }
            Text("Shows only where NOT to put the aeroplane down — never where to land. Not mapped anywhere: "
                 + "distribution and farm wires, fences, ditches, crops. Unshaded ground is not safe ground. "
                 + "Power lines: HIFLD, data to Sept 2024.")
                .font(.dsLabelS).foregroundStyle(palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("layers-avoid-note")
            Text(status).font(.dsLabelS).foregroundStyle(library.store.isInstalled ? palette.textDim : palette.warn)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("layers-avoid-status")
        }
        .padding(.leading, 30)
    }

    private var status: String {
        if let info = library.store.info {
            return "Contiguous US · built \(info.builtAt.prefix(10)) · hidden when zoomed far out."
        }
        return "Not downloaded yet — Settings › Downloads › Where not to go."
    }
}
