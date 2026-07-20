import SwiftUI

/// The Weather (WX) tab: a gallery of NOAA aviation-weather imagery — prog charts, satellite, convective
/// outlooks, precipitation, winds aloft (and icing/turbulence/AIRMETs/PIREPs as sources are wired). Every
/// image viewed is cached on disk so it can be re-opened OFFLINE later; the download time is stamped under
/// the image (the chart's own valid time is printed inside the imagery by NOAA). Nothing here touches the
/// moving map. Self-gated like the other tabs (renders only when front).
struct WXTabView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var cache = WXImageCache()

    var body: some View {
        let p = model.palette
        return Group {
            if model.selectedTab == .wx {
                NavigationStack {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(WXCatalog.categories) { cat in
                                categoryCard(cat, p)
                            }
                            Text("Imagery: NOAA (NESDIS · WPC · SPC · AWC · NDFD). Downloaded charts stay available offline. Not a substitute for an official weather briefing.")
                                .font(.caption2).foregroundStyle(p.textDim).padding(.top, 4)
                        }
                        .padding(16)
                    }
                    .background(p.bg)
                    .navigationTitle("Weather")
                }
                .accessibilityIdentifier("tab-wx")
            }
        }
    }

    private func categoryCard(_ cat: WXCategory, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: cat.symbol).foregroundStyle(p.accent).frame(width: 24)
                Text(cat.title).font(.headline).foregroundStyle(p.text)
            }
            .padding(.bottom, 6)
            ForEach(WXCatalog.products(in: cat)) { product in
                NavigationLink { WXProductView(product: product).environmentObject(cache) } label: {
                    HStack {
                        Text(product.name).font(.callout).foregroundStyle(p.text)
                        Spacer()
                        if cache.cached(product.url()) != nil {
                            Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(p.good)
                                .accessibilityLabel("Available offline")
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(p.textDim)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wx-product-\(product.id)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
    }
}

/// One product: axis pickers (level / forecast hour / sector…), the zoomable chart, the download stamp
/// (+ offline badge), a Refresh button, and the product's coverage note + attribution.
struct WXProductView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cache: WXImageCache
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
        }
        .background(p.bg)
        .navigationTitle(product.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
