import SwiftUI

/// A docked side pane (Windows-snap split screen): a widget dragged to the left/right edge lives here as
/// a full-height panel instead of a floating card. Resizable by dragging its inner edge (width remembered
/// per side), a "↗" button pops it back out to a floating widget, a "✕" (or a two-finger swipe) closes it.
struct SidePane<Content: View>: View {
    let side: WidgetStore.PaneSide
    let kind: FloatingWidgetKind
    let container: CGSize
    let palette: Palette
    @ObservedObject var widgets: WidgetStore
    @ViewBuilder var content: Content

    @State private var resizeStartWidth: CGFloat?     // pane width captured at the start of a resize drag

    private static var handleW: CGFloat { 12 }
    private static var minW: CGFloat { 260 }

    /// Effective pane width: the remembered points if set + in range, else one-third of the PORTRAIT
    /// width (min screen dimension) so the same physical width persists across orientation, per the brief.
    private var paneWidth: CGFloat {
        let maxW = max(Self.minW, container.width * 0.6)
        let stored = widgets.paneWidth(side)
        let base = stored > 0 ? stored : min(container.width, container.height) / 3
        return min(max(base, Self.minW), maxW)
    }

    var body: some View {
        let p = palette
        let body = VStack(spacing: 0) {
            header(p)
            Rectangle().fill(p.border).frame(height: 0.5)
            content
                .environment(\.floatingSurface, true)      // fill the pane — no floating-card chrome
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .frame(width: paneWidth)
        .background(p.surface)
        .frame(height: container.height)
        // The inner edge carries the resize grip + a divider; the outer edge is flush to the screen.
        let stack = HStack(spacing: 0) {
            if side == .right { resizeHandle(p) }
            body
            if side == .left { resizeHandle(p) }
        }
        return stack
            .frame(height: container.height)
            .shadow(color: .black.opacity(0.3), radius: 10, x: side == .left ? 4 : -4)
            .twoFingerSwipeDown { widgets.closePane(side) }   // two-finger swipe also closes the pane
            .transition(.move(edge: side == .left ? .leading : .trailing))
    }

    private func header(_ p: Palette) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol).font(.caption)
            Text(kind.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Button { Haptics.impact(.light); withAnimation(.easeInOut(duration: 0.2)) { widgets.undockToWidget(side) } } label: {
                Image(systemName: "arrow.up.forward.app").font(.callout).padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plainHaptic)
            .accessibilityIdentifier("pane-popout-\(side == .left ? "left" : "right")")
            .accessibilityLabel("Pop out to floating widget")
            Button { Haptics.impact(.light); withAnimation(.easeInOut(duration: 0.2)) { widgets.closePane(side) } } label: {
                Image(systemName: "xmark").font(.callout).padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plainHaptic)
            .accessibilityIdentifier("pane-close-\(side == .left ? "left" : "right")")
            .accessibilityLabel("Close pane")
        }
        .foregroundStyle(p.text)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(p.surfaceAlt)
    }

    /// A draggable divider on the pane's INNER edge — drag to resize; the new width is remembered.
    private func resizeHandle(_ p: Palette) -> some View {
        ZStack {
            Rectangle().fill(p.surfaceAlt)
            Capsule().fill(p.textDim.opacity(0.7)).frame(width: 4, height: 44)
        }
        .frame(width: Self.handleW)
        .frame(height: container.height)
        .contentShape(Rectangle())
        .accessibilityIdentifier("pane-resize-\(side == .left ? "left" : "right")")
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let start = resizeStartWidth ?? paneWidth
                    if resizeStartWidth == nil { resizeStartWidth = start }
                    // Left pane grows when the inner (right) edge is dragged right; right pane the mirror.
                    let delta = side == .left ? v.translation.width : -v.translation.width
                    let maxW = max(Self.minW, container.width * 0.6)
                    widgets.setPaneWidth(side, min(max(start + delta, Self.minW), maxW))
                }
                .onEnded { _ in resizeStartWidth = nil }
        )
    }
}
