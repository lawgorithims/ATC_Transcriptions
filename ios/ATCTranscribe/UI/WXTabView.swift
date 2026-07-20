import SwiftUI

/// User-curated favorite WX products, persisted so the pilot's go-to charts survive relaunch. Stored as a
/// plain string array in UserDefaults (a Set of product ids); tiny + offline (no network, never cleared by
/// the image cache's eviction — favorites are identity, not data).
@MainActor final class WXFavorites: ObservableObject {
    @Published private(set) var ids: [String] = []          // insertion-ordered (most-recently-added last)
    private let key = "atc.wx.favorites"

    init() { ids = UserDefaults.standard.stringArray(forKey: key) ?? [] }

    func isFavorite(_ id: String) -> Bool { ids.contains(id) }
    func toggle(_ id: String) {
        assert(!id.isEmpty, "WXFavorites: empty product id")
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        UserDefaults.standard.set(ids, forKey: key)
    }
    /// The favorited products, in the catalog's own order (stable, not toggle order), skipping any id whose
    /// product no longer exists in the catalog.
    func products(from all: [WXProduct]) -> [WXProduct] {
        let set = Set(ids)
        return all.filter { set.contains($0.id) }
    }
}

/// The Weather (WX) tab: a gallery of NOAA aviation-weather imagery — prog charts, satellite, convective
/// outlooks, precipitation, winds aloft, icing/turbulence/AIRMETs. Every image viewed is cached on disk so
/// it can be re-opened OFFLINE later, stamped with when NOAA released it (Last-Modified) in local time.
/// A user-curated Favorites section rides on top. Nothing here touches the moving map. Self-gated (renders
/// only when front).
struct WXTabView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var cache = WXImageCache()
    @StateObject private var favorites = WXFavorites()
    @State private var updating = false
    @State private var updateProgress: (done: Int, total: Int)?

    /// Release time in the iPad's LOCAL time zone (short date + time, e.g. "Jul 19, 2:45 PM").
    static let releaseTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()
    private static let relative = RelativeDateTimeFormatter()

    var body: some View {
        let p = model.palette
        return Group {
            if model.selectedTab == .wx {
                NavigationStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            updateHeader(p)
                            let favs = favorites.products(from: WXCatalog.all)
                            if !favs.isEmpty {
                                section(title: "Favorites", symbol: "star.fill", tint: .yellow, products: favs, p)
                            }
                            ForEach(WXCatalog.categories) { cat in
                                section(title: cat.title, symbol: cat.symbol, tint: p.accent,
                                        products: WXCatalog.products(in: cat), p)
                            }
                            Text("Imagery: NOAA (NESDIS · WPC · SPC · AWC · NDFD). Downloaded charts stay available offline. Not a substitute for an official weather briefing.")
                                .font(.caption2).foregroundStyle(p.textDim)
                                .padding(.horizontal, 16).padding(.top, 12)
                        }
                        // Clear the bottom chrome: the tab bar is a safe-area inset, but the live GPS bar (an
                        // extra inset shown app-wide) was covering the last rows / a chart's bottom in
                        // landscape. Pad past it so every product + the full chart is reachable.
                        .padding(.bottom, model.showGPSBar ? 96 : 56)
                    }
                    .background(p.bg)
                    .navigationTitle("Weather")
                }
                .accessibilityIdentifier("tab-wx")
                // Keep the image cache's protected set in sync with favorites so a favorited chart the pilot
                // staged for offline use is NEVER evicted (their default-variant URL is protected).
                .onAppear { syncProtected() }
                .onChange(of: favorites.ids) { _, _ in syncProtected() }
            }
        }
    }

    private func syncProtected() {
        cache.protectedURLs = Set(favorites.products(from: WXCatalog.all).map { $0.url() })
    }

    // MARK: manual update + freshness

    /// The URLs the manual update should refresh: every CACHED variant (any altitude/forecast the pilot has
    /// open) plus each favorite's default variant (so a favorited-but-never-opened chart still gets staged).
    /// Keyed on real cached urls, NOT product defaults — so freshness can't call a chart "up to date" while
    /// the specific FL variant the pilot flies with is stale.
    private func trackedURLs() -> Set<String> {
        var urls = Set(cache.cachedEntries().map { $0.url })
        for u in favorites.products(from: WXCatalog.all).map({ $0.url() }) { urls.insert(u) }
        return urls
    }

    /// Aggregate freshness over the CACHED variants (mapped to category via the catalog's reverse url map),
    /// plus any favorited-but-uncached chart as `unknown`. Pure in-memory (no disk stat per render).
    private func aggregateFreshness(now: Date) -> WXFreshness {
        var items: [WXFreshness] = []
        for (url, fetched) in cache.cachedEntries() {                 // bounded by cache size (rule 2)
            guard let cat = WXCatalog.urlCategory[url] else { continue }
            items.append(WXFreshness.of(category: cat, fetchedAt: fetched, now: now))
        }
        for u in favorites.products(from: WXCatalog.all).map({ $0.url() }) where cache.fetchedAt(u) == nil {
            items.append(.unknown)
        }
        return WXFreshness.aggregate(items)
    }

    /// The banner button: a colored dot (up-to-date / may-be-stale / out-of-date), a hint, and a refresh
    /// control that re-downloads the tracked charts. Wrapped in a TimelineView so the color ages over time
    /// even without interaction. NOTE: this NEVER clears the cache — a failed refresh keeps the offline copy.
    private func updateHeader(_ p: Palette) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let fresh = aggregateFreshness(now: ctx.date)
            Button {
                Task { await updateCharts() }
            } label: {
                HStack(spacing: 11) {
                    Circle().fill(Self.color(fresh, p)).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(fresh)).font(.subheadline.weight(.semibold)).foregroundStyle(p.text)
                        Text(subtitle(fresh, now: ctx.date))
                            .font(.caption2).foregroundStyle(p.textDim)
                    }
                    Spacer()
                    if updating {
                        if let up = updateProgress {
                            Text("\(up.done)/\(up.total)").font(.caption.monospacedDigit()).foregroundStyle(p.textDim)
                        }
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise.circle.fill").font(.title3).foregroundStyle(p.accent)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.color(fresh, p).opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plainHaptic)
            .disabled(updating)
            .padding(.horizontal, 16).padding(.top, 12)
            .accessibilityIdentifier("wx-update-button")
            .accessibilityLabel("Update charts. \(Self.title(fresh))")
        }
    }

    private func subtitle(_ f: WXFreshness, now: Date) -> String {
        if updating { return "Downloading the latest charts…" }
        let newest = cache.cachedEntries().map { $0.fetchedAt }.max()
        switch f {
        case .unknown: return "Open charts to cache them for offline use"
        case .fresh:   return newest.map { "Checked \(Self.relative.localizedString(for: $0, relativeTo: now)) · tap to refresh" } ?? "Tap to refresh"
        case .aging:   return "Some charts may be out of date — tap to update"
        case .stale:   return "Charts are out of date — tap to update now"
        }
    }

    private static func title(_ f: WXFreshness) -> String {
        switch f {
        case .fresh:   return "Charts up to date"
        case .aging:   return "Charts may be out of date"
        case .stale:   return "Charts out of date"
        case .unknown: return "Update charts"
        }
    }
    private static func color(_ f: WXFreshness, _ p: Palette) -> Color {
        switch f {
        case .fresh:   return p.good
        case .aging:   return p.warn
        case .stale:   return p.bad
        case .unknown: return p.textDim
        }
    }

    /// Re-download the pilot's actual cached variants + favorites (force refresh). Offline-safe: `cache.load`
    /// falls back to the existing copy on any failure and NEVER deletes it — a botched update can't lose a
    /// chart the pilot staged. Bounded by the cache size + favorites (rule 2).
    private func updateCharts() async {
        let urls = Array(trackedURLs())
        guard !urls.isEmpty, !updating else { return }
        updating = true; updateProgress = (0, urls.count)
        Haptics.impact(.light)
        var done = 0
        for u in urls {                                          // bounded by cache size + favorites (rule 2)
            _ = await cache.load(u, forceRefresh: true)
            done += 1; updateProgress = (done, urls.count)
        }
        updating = false; updateProgress = nil
    }

    /// A flat section (header + divided rows) — replaces the old per-category rounded box so Favorites and
    /// the categories read as one continuous list.
    @ViewBuilder private func section(title: String, symbol: String, tint: Color, products: [WXProduct], _ p: Palette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 22)
            Text(title).font(.headline).foregroundStyle(p.text)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
        ForEach(products) { product in
            productRow(product, p)
            Divider().overlay(p.border).padding(.leading, 16)
        }
    }

    /// One product row: a leading star to favorite (toggles WITHOUT navigating), then a navigation area with
    /// the name, its NOAA release time (local), and an offline badge.
    private func productRow(_ product: WXProduct, _ p: Palette) -> some View {
        let fav = favorites.isFavorite(product.id)
        return HStack(spacing: 10) {
            Button {
                Haptics.impact(.light); favorites.toggle(product.id)
            } label: {
                Image(systemName: fav ? "star.fill" : "star")
                    .font(.subheadline).foregroundStyle(fav ? .yellow : p.textDim)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plainHaptic)
            .accessibilityIdentifier("wx-fav-\(product.id)")
            .accessibilityLabel(fav ? "Remove \(product.name) from favorites" : "Add \(product.name) to favorites")

            NavigationLink {
                WXProductView(product: product).environmentObject(cache).environmentObject(favorites)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(product.name).font(.callout).foregroundStyle(p.text)
                        if let rel = cache.releasedAt(product.url()) {
                            Text("Released \(Self.releaseTime.string(from: rel))")
                                .font(.system(size: 11)).foregroundStyle(p.textDim)
                        }
                    }
                    Spacer()
                    if cache.isCached(product.url()) {   // decode-free — never decodes a multi-MB image in a row
                        Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(p.good)
                            .accessibilityLabel("Available offline")
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(p.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wx-product-\(product.id)")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}

/// One product: axis pickers (level / forecast hour / sector…), the zoomable chart, the download stamp
/// (+ offline badge), a Refresh + favorite control, and the product's coverage note + attribution.
struct WXProductView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cache: WXImageCache
    @EnvironmentObject var favorites: WXFavorites
    let product: WXProduct
    @State private var a = 0
    @State private var b = 0
    @State private var current: WXCachedImage?
    @State private var loading = false
    @State private var loadFailed = false

    var body: some View {
        let p = model.palette
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Release time (NOAA Last-Modified), in the iPad's local time, right after the chart name.
                if let rel = current?.releasedAt {
                    Label("Released \(WXTabView.releaseTime.string(from: rel)) local", systemImage: "clock.badge.checkmark")
                        .font(.caption).foregroundStyle(p.textDim)
                        .accessibilityIdentifier("wx-released")
                }
                if let axis = product.axisA { axisPicker(axis, selection: $a, p) }
                if let axis = product.axisB { axisPicker(axis, selection: $b, p) }
                imagePane(p)
                stampRow(p)
                if !product.note.isEmpty {
                    Text(product.note).font(.caption2).foregroundStyle(p.textDim)
                }
                Text(product.attribution).font(.caption2).foregroundStyle(p.textDim.opacity(0.8))
            }
            .padding(16)
            .padding(.bottom, model.showGPSBar ? 96 : 56)   // clear the GPS bar so the chart bottom is visible
        }
        .background(p.bg)
        .navigationTitle(product.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                let fav = favorites.isFavorite(product.id)
                Button { Haptics.impact(.light); favorites.toggle(product.id) } label: {
                    Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? .yellow : p.accent)
                }
                .accessibilityIdentifier("wx-fav-toggle")
                .accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load(refresh: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .accessibilityIdentifier("wx-refresh")
            }
        }
        .task(id: "\(a)|\(b)") { await load(refresh: false) }
    }

    /// Segmented for short axes, a menu for long ones (flight levels, sectors).
    @ViewBuilder private func axisPicker(_ axis: WXAxis, selection: Binding<Int>, _ p: Palette) -> some View {
        if axis.options.count <= 4 {
            Picker(axis.name, selection: selection) {
                ForEach(axis.options.indices, id: \.self) { i in Text(axis.options[i].label).tag(i) }
            }
            .pickerStyle(.segmented)
        } else {
            HStack {
                Text(axis.name).font(.caption).foregroundStyle(p.textDim)
                Spacer()
                Picker(axis.name, selection: selection) {
                    ForEach(axis.options.indices, id: \.self) { i in Text(axis.options[i].label).tag(i) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder private func imagePane(_ p: Palette) -> some View {
        if let cur = current {
            WXZoomableImage(image: cur.image)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 260)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
        } else {
            VStack(spacing: 10) {
                if loading {
                    ProgressView(); Text("Downloading chart…").font(.callout).foregroundStyle(p.textDim)
                } else if loadFailed {
                    Image(systemName: "wifi.exclamationmark").font(.title2).foregroundStyle(p.warn)
                    Text("Couldn't download — no cached copy yet.\nConnect to the internet and tap refresh.")
                        .font(.callout).foregroundStyle(p.textDim).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 260)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func stampRow(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            if let cur = current {
                Image(systemName: cur.fromCache ? "internaldrive" : "checkmark.circle")
                    .font(.caption).foregroundStyle(cur.fromCache ? p.warn : p.good)
                Text("\(cur.fromCache ? "Offline copy — downloaded" : "Downloaded") \(Self.relative.localizedString(for: cur.fetchedAt, relativeTo: Date()))")
                    .font(.caption).foregroundStyle(p.textDim)
                    .accessibilityIdentifier("wx-stamp")
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
    }

    private func load(refresh: Bool) async {
        let startA = a, startB = b
        let url = product.url(a: startA, b: startB)
        loadFailed = false
        // Paint the cached copy instantly, then refresh over the network.
        if !refresh, let disk = cache.cached(url) { current = disk }
        loading = true
        let result = await cache.load(url, forceRefresh: refresh)
        // The pilot may have switched the level/forecast picker mid-download — a superseded load must NOT
        // clobber the now-visible chart with the wrong altitude's image (a red-hat finding).
        guard a == startA, b == startB else { return }
        loading = false
        if let result { current = result } else if current == nil { loadFailed = true }
    }

    private static let relative = RelativeDateTimeFormatter()
}

/// Pinch-to-zoom + drag for a chart image; double-tap resets. Kept deliberately simple (v1).
struct WXZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let zoom = min(max(scale * pinch, 1), 8)
        Image(uiImage: image)
            .resizable().scaledToFit()
            .scaleEffect(zoom)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(MagnificationGesture()
                .updating($pinch) { v, s, _ in s = v }
                .onEnded { v in scale = min(max(scale * v, 1), 8); if scale <= 1.01 { offset = .zero } })
            .simultaneousGesture(DragGesture()
                .updating($drag) { v, s, _ in if zoom > 1 { s = v.translation } }
                .onEnded { v in if zoom > 1 { offset.width += v.translation.width; offset.height += v.translation.height } })
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { scale = 1; offset = .zero } }
            .animation(.easeOut(duration: 0.1), value: zoom)
    }
}
