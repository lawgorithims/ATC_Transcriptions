import SwiftUI

/// The small provenance marker: one glyph that says whether the data behind what you're looking at is
/// current, close to expiring, expired, or undated — with the cycle and expiry on tap.
///
/// Deliberately quiet when everything is current (a dim dot), and loud only when it isn't. A chart that
/// has expired still LOOKS authoritative, so the badge exists to say otherwise.
struct DataCurrencyBadge: View {
    @EnvironmentObject var model: AppModel
    /// The datasets feeding whatever this badge sits next to. The badge shows the WORST of them — a
    /// screen fusing four sources is only as current as its stalest input.
    let sources: [DataProvenance]
    var compact: Bool = true

    @State private var showDetail = false

    private var currency: DataCurrency { DataCurrency.worst(sources.map { $0.currency() }) }

    private var tint: Color {
        let p = model.palette
        switch currency {
        case .current:      return p.textDim
        case .unknown:      return p.textDim
        case .expiringSoon: return p.warn
        case .expired:      return p.bad
        }
    }

    private var glyph: String {
        switch currency {
        case .current:      return "checkmark.seal"
        case .unknown:      return "questionmark.circle"
        case .expiringSoon: return "clock.badge.exclamationmark"
        case .expired:      return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 3) {
                Image(systemName: glyph).font(.caption2)
                if !compact || currency.isExpired {
                    Text(currency.label).font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic)
        .accessibilityIdentifier("data-currency-badge")
        .accessibilityLabel("Data currency: \(currency.label)")
        .popover(isPresented: $showDetail) { detail }
    }

    private var detail: some View {
        let p = model.palette
        return VStack(alignment: .leading, spacing: 10) {
            Text("Data currency").font(.caption.weight(.bold)).foregroundStyle(p.textDim)
            ForEach(Array(sources.enumerated()), id: \.offset) { _, src in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: Self.glyph(for: src.currency()))
                            .font(.caption2).foregroundStyle(Self.tint(for: src.currency(), p))
                        Text(src.source.isEmpty ? "Unnamed dataset" : src.source)
                            .font(.caption).foregroundStyle(p.text)
                    }
                    Text(src.summary.isEmpty ? "No cycle recorded" : src.summary)
                        .font(.caption2).foregroundStyle(p.textDim)
                }
            }
            Text("Aeronautical data is republished on a fixed cycle. Expired data may not reflect current procedures — verify against an official source before use.")
                .font(.caption2).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(minWidth: 280, maxWidth: 360)
        .background(p.bg)
        .presentationCompactAdaptation(.popover)
    }

    static func glyph(for c: DataCurrency) -> String {
        switch c {
        case .current: return "checkmark.seal"
        case .unknown: return "questionmark.circle"
        case .expiringSoon: return "clock.badge.exclamationmark"
        case .expired: return "exclamationmark.triangle.fill"
        }
    }
    static func tint(for c: DataCurrency, _ p: Palette) -> Color {
        switch c {
        case .current: return p.good
        case .unknown: return p.textDim
        case .expiringSoon: return p.warn
        case .expired: return p.bad
        }
    }
}
