import SwiftUI

// MARK: - Widget identity

/// Every panel that can float over the home map. Superset of `SidebarWidget` (the diagnostic/info
/// cards) plus the operational panels that used to be top bars or the always-on transcript.
enum FloatingWidgetKind: String, Codable, CaseIterable, Identifiable {
    case transcript, flightPlan, objectInfo, proofOfLife, stratux, host, latency, diagnostics
    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript:  return "Transcript"
        case .flightPlan:  return "Flight plan"
        case .objectInfo:  return "Selected"
        case .proofOfLife: return "Performance check"
        case .stratux:     return "Stratux link"
        case .host:        return "Host"
        case .latency:     return "Latency"
        case .diagnostics: return "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .transcript:  return "text.bubble"
        case .flightPlan:  return "list.bullet.rectangle"
        case .objectInfo:  return "mappin.and.ellipse"
        case .proofOfLife: return "checkmark.seal"
        case .stratux:     return "dot.radiowaves.left.and.right"
        case .host:        return "cpu"
        case .latency:     return "speedometer"
        case .diagnostics: return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    /// Performance/device-load panels — never shown by default.
    var isDiagnostic: Bool { self == .latency || self == .diagnostics }

    /// `objectInfo` isn't user-addable — it appears only when a map object is tapped.
    var userManageable: Bool { self != .objectInfo }
}

// MARK: - Persisted layout

/// Where a floating card docks. The stored offset is measured as a FRACTION of the container from this
/// anchor, so an iPad layout degrades gracefully onto an iPhone / after rotation.
enum WidgetAnchor: String, Codable, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing, leading, trailing, center
}

/// One floating card's persisted state.
struct WidgetFrame: Codable, Equatable, Identifiable {
    var kind: FloatingWidgetKind
    var anchor: WidgetAnchor
    var offset: CGSize          // fraction of the container, from `anchor`
    var size: CGSize            // points (clamped to the container on resolve)
    var opacity: Double         // background opacity: 0 = fully transparent … 1 = opaque
    var visible: Bool
    var pinned: Bool            // locked in place (drag disabled), content still interactive
    var z: Int                  // higher draws on top; bumped when a card is moved
    var id: String { kind.rawValue }
}

/// The whole home-screen layout — persisted as JSON under `atc.widgetLayout`, mirroring `FlightPlan`.
struct WidgetLayout: Codable, Equatable {
    var items: [WidgetFrame]

    static let storageKey = "atc.widgetLayout"

    func frame(_ kind: FloatingWidgetKind) -> WidgetFrame? { items.first { $0.kind == kind } }
    var maxZ: Int { items.map(\.z).max() ?? 0 }

    mutating func update(_ kind: FloatingWidgetKind, _ mutate: (inout WidgetFrame) -> Void) {
        guard let i = items.firstIndex(where: { $0.kind == kind }) else { return }
        mutate(&items[i])
    }

    /// Bring a card to the front (drag / show).
    mutating func bringToFront(_ kind: FloatingWidgetKind) {
        let top = maxZ + 1
        update(kind) { $0.z = top }
    }

    // MARK: Persistence (UserDefaults JSON — mirrors FlightPlan.load/save/clear)

    static func load() -> WidgetLayout? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let layout = try? JSONDecoder().decode(WidgetLayout.self, from: data),
              !layout.items.isEmpty else { return nil }
        return layout
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }

    /// Fresh-install layout: transcript + flight plan + performance check visible; diagnostics OFF.
    static func defaults() -> WidgetLayout {
        WidgetLayout(items: [
            WidgetFrame(kind: .transcript,  anchor: .bottomLeading, offset: .zero, size: CGSize(width: 380, height: 460), opacity: 0.92, visible: true,  pinned: false, z: 1),
            WidgetFrame(kind: .flightPlan,  anchor: .topLeading,    offset: .zero, size: CGSize(width: 340, height: 150), opacity: 0.92, visible: true,  pinned: false, z: 2),
            WidgetFrame(kind: .objectInfo,  anchor: .trailing,      offset: .zero, size: CGSize(width: 340, height: 440), opacity: 0.95, visible: false, pinned: false, z: 6),
            WidgetFrame(kind: .proofOfLife, anchor: .bottomTrailing, offset: .zero, size: CGSize(width: 300, height: 150), opacity: 0.90, visible: true,  pinned: false, z: 3),
            WidgetFrame(kind: .stratux,     anchor: .topTrailing,   offset: .zero, size: CGSize(width: 300, height: 190), opacity: 0.90, visible: false, pinned: false, z: 4),
            WidgetFrame(kind: .host,        anchor: .topTrailing,   offset: CGSize(width: 0, height: 0.28), size: CGSize(width: 260, height: 140), opacity: 0.90, visible: false, pinned: false, z: 5),
            WidgetFrame(kind: .latency,     anchor: .center,        offset: .zero, size: CGSize(width: 300, height: 180), opacity: 0.90, visible: false, pinned: false, z: 7),
            WidgetFrame(kind: .diagnostics, anchor: .center,        offset: CGSize(width: 0, height: 0.2), size: CGSize(width: 280, height: 170), opacity: 0.90, visible: false, pinned: false, z: 8),
        ])
    }

    /// Migrate the old `atc.sidebarWidgets` id list into a fresh layout: keep the visibility the user had
    /// (any listed widget becomes visible; the rest stay at their default visibility).
    static func migrating(fromSidebarIDs ids: [String]) -> WidgetLayout {
        var layout = defaults()
        let listed = Set(ids)
        for i in layout.items.indices where layout.items[i].kind.userManageable {
            if listed.contains(layout.items[i].kind.rawValue) { layout.items[i].visible = true }
        }
        return layout
    }
}

// MARK: - Widget store (isolated from the live-data storm)

/// Owns the floating-widget layout + the tapped-object probe — the home-screen "panel" state.
///
/// This lives in its OWN `ObservableObject`, deliberately NOT on `AppModel`, so the several-per-second
/// live-data publishes (transcript records, audio input level, ADS-B traffic, GPS — all mirrored into
/// `AppModel`) never invalidate the widget chrome. Because `FloatingCanvas` / `FloatingWidgetContainer`
/// observe this store instead of `AppModel`, SwiftUI skips their bodies on every unrelated storm tick, so
/// a card being dragged doesn't re-rasterize its shadow/clip/content — only its own gesture state moves
/// it. The live content INSIDE each card (e.g. `TranscriptCard`) keeps its own `AppModel` subscription, so
/// it still updates in real time. Layout changes persist as JSON, mirroring the old `AppModel` behaviour.
@MainActor final class WidgetStore: ObservableObject {
    @Published var layout: WidgetLayout { didSet { layout.save() } }
    /// The map object the user tapped on the home map (nil = nothing) — drives the object side panel
    /// (regular width) / bottom sheet (compact). Transient; changes only on a tap, never on the storm.
    @Published var mapProbe: MapProbeResult?

    init() { layout = WidgetStore.initialLayout() }

    /// First run under the redesign migrates the old `atc.sidebarWidgets` list into a layout; else the
    /// saved layout, else defaults. `--reset-widgets` (UI tests / recovery) forces defaults.
    static func initialLayout() -> WidgetLayout {
        if CommandLine.arguments.contains("--reset-widgets") { return .defaults() }
        if let saved = WidgetLayout.load() { return saved }
        if let ids = UserDefaults.standard.array(forKey: "atc.sidebarWidgets") as? [String] {
            return .migrating(fromSidebarIDs: ids)
        }
        return .defaults()
    }

    func update(_ kind: FloatingWidgetKind, _ mutate: (inout WidgetFrame) -> Void) { layout.update(kind, mutate) }
    func bringToFront(_ kind: FloatingWidgetKind) { layout.bringToFront(kind) }
    /// Reveal a widget and lift it to the front (top-bar Widgets menu / programmatic show).
    func show(_ kind: FloatingWidgetKind) { layout.update(kind) { $0.visible = true }; layout.bringToFront(kind) }
    func reset() { layout = .defaults() }
}

// MARK: - Pure geometry (unit-tested; no view state)

/// Resolves a `WidgetFrame` to an on-screen rect and, inversely, snaps a dragged rect back to the
/// nearest anchor. Kept pure (CoreGraphics only) so the docking math is unit-testable.
enum WidgetGeometry {
    static let margin: CGFloat = 12          // inset from the container edge at an anchor
    static let snapFraction: CGFloat = 0.06  // drop within this fraction of an anchor → snap flush to it

    /// The card's origin when docked flush to `anchor` (before the fractional offset is applied).
    static func anchorOrigin(_ anchor: WidgetAnchor, size: CGSize, container: CGSize) -> CGPoint {
        let m = margin
        let maxX = max(m, container.width - size.width - m)
        let maxY = max(m, container.height - size.height - m)
        let midX = (container.width - size.width) / 2
        let midY = (container.height - size.height) / 2
        switch anchor {
        case .topLeading:     return CGPoint(x: m, y: m)
        case .topTrailing:    return CGPoint(x: maxX, y: m)
        case .bottomLeading:  return CGPoint(x: m, y: maxY)
        case .bottomTrailing: return CGPoint(x: maxX, y: maxY)
        case .leading:        return CGPoint(x: m, y: midY)
        case .trailing:       return CGPoint(x: maxX, y: midY)
        case .center:         return CGPoint(x: midX, y: midY)
        }
    }

    /// The clamped on-screen rect for a frame in a container of `container` points.
    static func rect(for frame: WidgetFrame, in container: CGSize) -> CGRect {
        let s = CGSize(width: min(frame.size.width, container.width - 2 * margin),
                       height: min(frame.size.height, container.height - 2 * margin))
        let base = anchorOrigin(frame.anchor, size: s, container: container)
        var o = CGPoint(x: base.x + frame.offset.width * container.width,
                        y: base.y + frame.offset.height * container.height)
        // keep the card fully within the container (with margin) so it can never strand off-screen
        o.x = min(max(o.x, margin), max(margin, container.width - s.width - margin))
        o.y = min(max(o.y, margin), max(margin, container.height - s.height - margin))
        return CGRect(origin: o, size: s)
    }

    /// Given where a card was dropped, choose the nearest anchor and the residual fractional offset from
    /// it — so it lands where you let go but is stored anchor-relative (survives resize/rotation). A drop
    /// very close to an anchor snaps flush (zero offset).
    static func snap(droppedOrigin origin: CGPoint, size: CGSize, in container: CGSize) -> (anchor: WidgetAnchor, offset: CGSize) {
        let nearest = WidgetAnchor.allCases.min { a, b in
            distance(origin, anchorOrigin(a, size: size, container: container))
                < distance(origin, anchorOrigin(b, size: size, container: container))
        } ?? .topLeading
        let base = anchorOrigin(nearest, size: size, container: container)
        var off = CGSize(width: (origin.x - base.x) / max(container.width, 1),
                         height: (origin.y - base.y) / max(container.height, 1))
        if abs(off.width) < snapFraction { off.width = 0 }     // magnetic snap flush to the anchor
        if abs(off.height) < snapFraction { off.height = 0 }
        return (nearest, off)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }

    static let minSize = CGSize(width: 220, height: 120)
}

// MARK: - Environment: tell an inner `Card` to drop its own surface so the container owns the background

private struct FloatingSurfaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var floatingSurface: Bool {
        get { self[FloatingSurfaceKey.self] }
        set { self[FloatingSurfaceKey.self] = newValue }
    }
}

// MARK: - The floating card container (iPad / regular width)

/// Wraps any panel in a movable, resizable, opacity-adjustable, pinnable card floating over the map.
/// Drag is scoped to the header handle (so inner scroll views / buttons keep working); on release it
/// snaps to the nearest anchor via `WidgetGeometry`. Reads/writes its `WidgetFrame` through `AppModel`.
struct FloatingWidgetContainer<Content: View>: View {
    let frame: WidgetFrame
    let container: CGSize
    let palette: Palette
    let widgets: WidgetStore          // plain ref for actions only — NOT observed, so the live-data storm
                                      // can never re-render (and re-rasterize) a card while it's being dragged
    @ViewBuilder var content: Content

    @GestureState private var drag: CGSize = .zero
    @GestureState private var resize: CGSize = .zero
    @State private var showControls = false

    var body: some View {
        let p = palette
        let rect = WidgetGeometry.rect(for: frame, in: container)
        let w = clampW(rect.width + resize.width)
        let h = clampH(rect.height + resize.height)
        VStack(spacing: 0) {
            header(p)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .environment(\.floatingSurface, true)
        .frame(width: w, height: h)
        .background(p.surface.opacity(frame.opacity))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.border.opacity(0.7), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) { if !frame.pinned { resizeGrip(p) } }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .position(x: rect.midX + drag.width, y: rect.midY + drag.height)
        .zIndex(Double(frame.z))
        // While a drag/resize is live, disable the implicit spring: otherwise the bring-to-front z-bump in
        // the drag's onChanged mutates `frame` (WidgetFrame.Equatable includes z), arming the spring
        // MID-drag so it chases the still-moving finger — the reported rubber-band "jitter" — and animates
        // the .zIndex reorder in the same pass (grab "flicker"). Nil animation while gesturing → the card
        // tracks the finger 1:1 and the z-lift is instant. Restored when idle (both gesture states .zero,
        // which includes the release commit) so the snap-to-anchor + opacity/pin/size changes still spring.
        .animation((drag == .zero && resize == .zero)
                   ? .interactiveSpring(response: 0.3, dampingFraction: 0.82)
                   : nil,
                   value: frame)
    }

    // MARK: header (drag handle + controls)

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 6) {
            Image(systemName: frame.kind.symbol).font(.caption2)
            Text(frame.kind.title).font(.caption.weight(.semibold)).lineLimit(1)
            if frame.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(p.accent) }
            Spacer(minLength: 4)
            Button { showControls = true } label: {
                Image(systemName: "slider.horizontal.3").font(.caption2).padding(5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showControls, arrowEdge: .top) { controls(p) }
            Button { close() } label: {
                Image(systemName: "xmark").font(.caption2).padding(5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(p.text)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(p.surfaceAlt.opacity(max(frame.opacity, 0.35)))
        .contentShape(Rectangle())                       // grabbable even when the card is see-through
        .gesture(dragGesture, including: frame.pinned ? .subviews : .all)   // pinned → drag disabled, content still works
        .accessibilityIdentifier("widget-header-\(frame.kind.rawValue)")
    }

    private func controls(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: opacityBinding, in: 0.15...1)
            }
            Toggle(isOn: pinnedBinding) { Label("Pin in place", systemImage: "pin") }
            Button(role: .destructive) { showControls = false; close() } label: {
                Label("Hide widget", systemImage: "eye.slash")
            }
        }
        .padding(16).frame(width: 240)
        .presentationCompactAdaptation(.popover)
        .tint(p.accent)
    }

    private func resizeGrip(_ p: Palette) -> some View {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(p.textDim)
            .padding(6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($resize) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        let rect = WidgetGeometry.rect(for: frame, in: container)
                        widgets.update(frame.kind) {
                            $0.size = CGSize(width: clampW(rect.width + v.translation.width),
                                             height: clampH(rect.height + v.translation.height))
                        }
                    }
            )
    }

    // MARK: gestures + bindings

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($drag) { v, s, _ in s = v.translation }
            .onChanged { _ in if widgets.layout.frame(frame.kind)?.z != widgets.layout.maxZ { widgets.bringToFront(frame.kind) } }
            .onEnded { v in
                let rect = WidgetGeometry.rect(for: frame, in: container)
                let dropped = CGPoint(x: rect.origin.x + v.translation.width, y: rect.origin.y + v.translation.height)
                let snapped = WidgetGeometry.snap(droppedOrigin: dropped, size: rect.size, in: container)
                widgets.update(frame.kind) { $0.anchor = snapped.anchor; $0.offset = snapped.offset }
            }
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { frame.opacity }, set: { v in widgets.update(frame.kind) { $0.opacity = v } })
    }
    private var pinnedBinding: Binding<Bool> {
        Binding(get: { frame.pinned }, set: { v in widgets.update(frame.kind) { $0.pinned = v } })
    }

    private func close() {
        if frame.kind == .objectInfo { widgets.mapProbe = nil }   // the object panel closes by clearing the tap
        else { widgets.update(frame.kind) { $0.visible = false } }
    }

    private func clampW(_ x: CGFloat) -> CGFloat { min(max(x, WidgetGeometry.minSize.width), container.width - 2 * WidgetGeometry.margin) }
    private func clampH(_ y: CGFloat) -> CGFloat { min(max(y, WidgetGeometry.minSize.height), container.height - 2 * WidgetGeometry.margin) }
}
