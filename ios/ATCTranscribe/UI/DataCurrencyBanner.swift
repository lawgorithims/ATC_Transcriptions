import SwiftUI

/// A one-line, app-wide notice when any bundled aeronautical dataset has expired or is about to.
///
/// The detection machinery already existed and was correct — `DataProvenance`, `DataCurrency`, the
/// 0901Z cutover, the badge. What it lacked was REACH: a pilot had to open Settings → Charts &
/// downloads, or an approach-activation sheet, to learn that the data under the whole app was out of
/// cycle. Expired navigation data that looks authoritative is exactly the failure this project keeps
/// designing against, so it belongs where the pilot cannot miss it.
///
/// Deliberately quiet when everything is current: it renders nothing at all. Dismissal lasts for the
/// session — long enough not to nag on every tab switch, short enough that a new launch says it again.
struct DataCurrencyBanner: View {
    @EnvironmentObject var model: AppModel
    let onOpenDownloads: () -> Void

    var body: some View {
        let p = model.palette
        if let worst = model.staleDataSummary, !model.dataCurrencyBannerDismissed {
            HStack(spacing: 10) {
                Image(systemName: worst.expired ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                    .foregroundStyle(worst.expired ? p.bad : p.warn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(worst.headline).font(.dsLabelBold).foregroundStyle(p.text)
                    Text(worst.detail).font(.dsLabelS).foregroundStyle(p.textDim)
                }
                Spacer(minLength: 4)
                Button("Update") { onOpenDownloads() }
                    .font(.dsLabelBold).foregroundStyle(p.accent)
                    .buttonStyle(.plainHaptic)
                    .accessibilityIdentifier("data-currency-update")
                Button {
                    model.dataCurrencyBannerDismissed = true
                } label: {
                    Image(systemName: "xmark").font(.dsLabelSBold).foregroundStyle(p.textDim)
                }
                .buttonStyle(.plainHaptic)
                .accessibilityIdentifier("data-currency-dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 0.5) }
            .accessibilityIdentifier("data-currency-banner")
        }
    }
}

/// What the currency sweep found, reduced to something a pilot can act on.
struct StaleDataSummary: Equatable {
    let expired: Bool
    let headline: String
    let detail: String

    /// Fuse the app's dated datasets and describe the WORST of them, or nil when everything is current.
    ///
    /// `.unknown` is deliberately not reported here. An undated dataset is a real gap — the badge says
    /// "Undated" wherever one is shown — but it is not a claim that the data is stale, and a banner that
    /// fires on it would be permanent furniture the pilot learns to ignore.
    static func make(sources: [(name: String, provenance: DataProvenance)],
                     asOf now: Date = Date()) -> StaleDataSummary? {
        assert(sources.count <= 32, "unexpectedly many datasets to sweep")
        var expired: [(String, Int)] = []          // name, days since expiry
        var soon: [(String, Int)] = []             // name, days left
        for s in sources.prefix(32) {
            switch s.provenance.currency(asOf: now) {
            case .expired(let since):
                expired.append((s.name, max(DataProvenance.wholeDays(from: since, to: now), 0)))
            case .expiringSoon(let days):
                soon.append((s.name, max(days, 0)))
            case .current, .unknown:
                continue
            }
        }
        if !expired.isEmpty {
            let names = expired.map(\.0).sorted().joined(separator: ", ")
            let worst = expired.map(\.1).max() ?? 0
            return StaleDataSummary(
                expired: true,
                headline: expired.count == 1 ? "\(names) has expired" : "\(expired.count) datasets have expired",
                detail: worst == 0 ? "\(names) — out of cycle as of today. Verify against current charts."
                                   : "\(names) — \(worst) day\(worst == 1 ? "" : "s") out of cycle. Verify against current charts.")
        }
        guard !soon.isEmpty else { return nil }
        let names = soon.map(\.0).sorted().joined(separator: ", ")
        let least = soon.map(\.1).min() ?? 0
        return StaleDataSummary(
            expired: false,
            headline: least == 0 ? "\(names) expires today" : "\(names) expires in \(least) day\(least == 1 ? "" : "s")",
            detail: "Download the new cycle before it lapses.")
    }
}
