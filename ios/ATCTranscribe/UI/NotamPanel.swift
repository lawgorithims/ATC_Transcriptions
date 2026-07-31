import SwiftUI

/// NOTAMs for an aerodrome, with the ones that bear on the approach in use pinned to the top.
///
/// The compact section PINS; it never filters. The full list below it always contains everything that
/// was fetched, with the counts stated, so a pilot can always see how much was set aside and go and
/// read it. That is the whole design: a NOTAM promoted in error costs a few seconds, one quietly
/// demoted costs whatever it was warning about.
///
/// The empty state is load-bearing. "No NOTAMs", "no API key" and "the fetch failed" render as the same
/// empty list unless they are deliberately kept apart, and only one of them means the pilot has nothing
/// to read — so only a successful fetch is ever allowed to say "none".
struct NotamPanel: View {
    let airport: String
    /// The runway of the approach in use, "" for a circling or point-in-space procedure.
    let runway: String
    @ObservedObject var store: NotamStore
    let palette: Palette

    @State private var showAll = false

    private var p: Palette { palette }
    private var state: NotamFeedState { store.state(for: airport) }
    private var split: (pinned: [ClassifiedNotam], others: [ClassifiedNotam]) {
        NotamRelevance.partition(store.notams(airport), airport: airport, runway: runway)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch state {
            case .noCredential: credentialNotice
            case .loading:      Text("Loading NOTAMs…").font(.dsLabelS).foregroundStyle(p.textDim)
            case .failed(let why): failureNotice(why)
            case .ok(let at):   content(fetchedAt: at)
            }
            caveat
        }
        .onAppear { store.ensure(airport) }
        .accessibilityIdentifier("notam-panel")
    }

    // MARK: sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NOTAMS").dsSectionHeader(p)
            Text(runway.isEmpty ? airport : "\(airport) · approach to \(runway)")
                .font(.dsLabelS).foregroundStyle(p.textDim)
        }
    }

    @ViewBuilder private func content(fetchedAt: Date) -> some View {
        let s = split
        if s.pinned.isEmpty && s.others.isEmpty {
            // The ONLY place this sentence is allowed to appear.
            Text("The FAA reports no NOTAMs for \(airport).")
                .font(.dsLabel).foregroundStyle(p.textDim)
                .accessibilityIdentifier("notam-none")
        } else {
            if s.pinned.isEmpty {
                Text("None of the \(s.others.count) NOTAMs for \(airport) were matched to this approach.")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(s.pinned) { row($0, pinned: true) }
                }
            }
            Button {
                Haptics.impact(.light)
                withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(showAll
                         ? "Hide the other \(s.others.count)"
                         : "\(s.pinned.count) of \(s.pinned.count + s.others.count) bear on this approach — show all")
                    Image(systemName: showAll ? "chevron.up" : "chevron.down")
                }
                .font(.dsLabelS).foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notam-show-all")

            if showAll {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(s.others) { row($0, pinned: false) }
                }
            }
            Text("Fetched \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9)).foregroundStyle(p.textDim)
        }
    }

    private func row(_ c: ClassifiedNotam, pinned: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: c.unclassified ? "questionmark.circle.fill" : c.kind.icon)
                .font(.system(size: 12))
                .foregroundStyle(pinned ? (c.unclassified ? p.warn : p.bad) : p.textDim)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(c.unclassified ? "Could not be read — read it here" : c.kind.label)
                        .font(.dsLabelSBold)
                        .foregroundStyle(pinned ? p.text : p.textDim)
                    if !c.runways.isEmpty {
                        Text(c.runways.joined(separator: ", ")).font(.system(size: 9)).foregroundStyle(p.textDim)
                    }
                    Spacer(minLength: 0)
                    Text(c.notam.id).font(.system(size: 9)).foregroundStyle(p.textDim)
                }
                Text(c.notam.plainText ?? c.notam.text)
                    .font(.dsLabelS).foregroundStyle(pinned ? p.text : p.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(pinned ? 6 : 3)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pinned ? p.surface : p.surface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4)
            .stroke(pinned && !c.unclassified ? p.bad.opacity(0.35) : p.border, lineWidth: DS.Stroke.hairline))
    }

    private var credentialNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("NOTAMs need an FAA API key", systemImage: "key.fill")
                .font(.dsLabelSBold).foregroundStyle(p.warn)
            Text("The FAA's NOTAM service requires a free developer key. Add one in Settings → NOTAM feed. Until then this shows nothing — which is NOT the same as there being no NOTAMs.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Register at api.faa.gov").font(.system(size: 9)).foregroundStyle(p.textDim)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("notam-no-credential")
    }

    private func failureNotice(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("NOTAMs could not be refreshed", systemImage: "exclamationmark.triangle.fill")
                .font(.dsLabelSBold).foregroundStyle(p.warn)
            Text(why).font(.dsLabelS).foregroundStyle(p.textDim)
            if !store.notams(airport).isEmpty {
                Text("Showing the last set that was fetched.")
                    .font(.system(size: 9)).foregroundStyle(p.textDim)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(p.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
        .accessibilityIdentifier("notam-failed")
    }

    private var caveat: some View {
        Text("Awareness only — not an official briefing. Classification is an aid: everything fetched is in the full list, and anything this could not read is shown at the top rather than set aside.")
            .font(.system(size: 9)).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
