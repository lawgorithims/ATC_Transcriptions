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

    /// Release time in the iPad's LOCAL time zone (short date + time, e.g. "Jul 19, 2:45 PM").
    static let releaseTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    var body: some View {
        let p = model.palette
        return Group {
            if model.selectedTab == .wx {
                NavigationStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
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
            }
        }
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
                    if cache.cached(product.url()) != nil {
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
        let url = product.url(a: a, b: b)
        loadFailed = false
        // Paint the cached copy instantly, then refresh over the network.
        if !refresh, let disk = cache.cached(url) { current = disk }
        loading = true
        let result = await cache.load(url, forceRefresh: refresh)
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
