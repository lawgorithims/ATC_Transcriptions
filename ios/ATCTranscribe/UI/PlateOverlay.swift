import SwiftUI
import MapKit
import PDFKit

/// The live "plate superimposed on the map" placement the pilot is adjusting. It is a REFERENCE aid —
/// auto-placed on the airport and hand-aligned — never a precise navigation source (the FAA index we
/// bundle carries no georeferencing, so a plate can't be auto-aligned to survey accuracy). UIImage is
/// not Equatable, so this type isn't either; `@Published` fires on any assignment, which is all we need.
struct PlateOverlayState {
    let name: String
    let airport: String
    let image: UIImage
    let imageAspect: Double        // width / height
    var centerLat: Double
    var centerLon: Double
    var widthMeters: Double        // geographic width the page spans (height follows the aspect)
    var rotationDeg: Double        // clockwise from north
    var opacity: Double

    var heightMeters: Double { PlatePlacement.heightMeters(widthMeters: widthMeters, imageAspect: imageAspect) }
    var center: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon) }

    /// A cheap identity of the GEOMETRY (not the image) so the map only rebuilds the overlay when the
    /// placement actually changed — opacity alone re-renders in place.
    var geoKey: String { "\(centerLat),\(centerLon),\(widthMeters),\(rotationDeg)" }
}

/// MKOverlay wrapping a plate image at a geographic placement.
final class PlateImageOverlay: NSObject, MKOverlay {
    let image: UIImage
    let centerCoord: CLLocationCoordinate2D
    let widthMeters: Double
    let heightMeters: Double
    let rotationDeg: Double
    var opacity: Double            // mutable so an opacity slide updates in place (no overlay rebuild)

    init(state: PlateOverlayState) {
        image = state.image
        centerCoord = state.center
        widthMeters = state.widthMeters
        heightMeters = state.heightMeters
        rotationDeg = state.rotationDeg
        opacity = state.opacity
    }
    var coordinate: CLLocationCoordinate2D { centerCoord }
    var boundingMapRect: MKMapRect {
        PlatePlacement.boundingMapRect(centerLat: centerCoord.latitude, centerLon: centerCoord.longitude,
                                       widthMeters: widthMeters, heightMeters: heightMeters, rotationDeg: rotationDeg)
    }
}

/// Draws the plate image into its geographic rect, rotated + alpha-blended.
final class PlateOverlayRenderer: MKOverlayRenderer {
    private let plate: PlateImageOverlay
    init(_ o: PlateImageOverlay) { plate = o; super.init(overlay: o) }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard plate.image.cgImage != nil else { return }
        let center = point(for: MKMapPoint(plate.centerCoord))
        let ppm = MKMapPointsPerMeterAtLatitude(plate.centerCoord.latitude)
        let br = plate.boundingMapRect
        let scale = rect(for: br).width / max(br.width, 1)         // renderer points per map point
        let wpx = plate.widthMeters * ppm * scale
        let hpx = plate.heightMeters * ppm * scale
        ctx.saveGState()
        ctx.setAlpha(CGFloat(plate.opacity))
        ctx.translateBy(x: center.x, y: center.y)                  // to the plate's map center
        ctx.rotate(by: CGFloat(plate.rotationDeg * .pi / 180))     // clockwise-from-north rotation
        // Draw the UIImage via a pushed UIKit context so it renders upright (UIImage.draw handles the
        // coordinate flip), respecting the rotation/translation applied above.
        UIGraphicsPushContext(ctx)
        plate.image.draw(in: CGRect(x: -wpx / 2, y: -hpx / 2, width: wpx, height: hpx))
        UIGraphicsPopContext()
        ctx.restoreGState()
    }
}

/// Render the first page of a plate PDF to a UIImage at a legible resolution (bounded so a huge page
/// never blows memory). Returns nil for an unreadable PDF.
enum PlateImageRenderer {
    static func firstPageImage(pdfURL: URL, maxDimension: CGFloat = 2400) -> UIImage? {
        guard let doc = PDFDocument(url: pdfURL), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let s = min(maxDimension / bounds.width, maxDimension / bounds.height, 4)
        let size = CGSize(width: bounds.width * s, height: bounds.height * s)
        let fmt = UIGraphicsImageRendererFormat.default(); fmt.opaque = true; fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { c in
            UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size))
            c.cgContext.translateBy(x: 0, y: size.height)
            c.cgContext.scaleBy(x: s, y: -s)
            page.draw(with: .mediaBox, to: c.cgContext)
        }
    }
}

/// The bottom control bar shown while a plate is overlaid on the map: opacity, size, rotation, a
/// position nudge pad, and a clear "reference only" caveat. Writes adjustments back through AppModel.
struct PlateControlBar: View {
    @EnvironmentObject var model: AppModel
    let state: PlateOverlayState
    let palette: Palette

    var body: some View {
        let p = palette
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext").foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.name).font(.caption.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text("Reference only — align to fit. Not to scale.").font(.caption2).foregroundStyle(p.warn)
                }
                Spacer(minLength: 4)
                Button { model.recenterPlateOnAirport() } label: { Image(systemName: "scope").font(.callout) }
                    .buttonStyle(.plain).foregroundStyle(p.accent).accessibilityIdentifier("plate-recenter")
                Button { model.clearPlateOverlay() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(p.textDim).accessibilityIdentifier("plate-remove")
            }
            HStack(spacing: 12) {
                nudgePad(p)
                VStack(spacing: 6) {
                    labeledSlider("Opacity", "circle.lefthalf.filled", value: opacityBinding, range: 0.1...1, p: p)
                    labeledSlider("Size", "arrow.up.left.and.arrow.down.right", value: widthBinding, range: 4_000...120_000, p: p)
                    labeledSlider("Rotate", "rotate.right", value: rotationBinding, range: -180...180, p: p)
                }
            }
        }
        .padding(12)
        .background(p.surface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .accessibilityIdentifier("plate-control-bar")
    }

    /// A small square; drag the puck to nudge the plate's center (range ≈ ±half the plate width).
    private func nudgePad(_ p: Palette) -> some View {
        let side: CGFloat = 78
        return ZStack {
            RoundedRectangle(cornerRadius: 10).fill(p.surfaceAlt).frame(width: side, height: side)
            Image(systemName: "move.3d").font(.caption2).foregroundStyle(p.textDim)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    // Map the drag delta (points) to a metres offset scaled by the plate size, so a
                    // full-pad drag ≈ ±0.5 plate-width. East = +x, North = -y (screen y is down).
                    let frac = 0.5 / (side / 2)
                    model.nudgePlate(eastMeters: Double(v.translation.width) * frac * state.widthMeters / 8,
                                     northMeters: Double(-v.translation.height) * frac * state.widthMeters / 8)
                }
        )
        .accessibilityIdentifier("plate-nudge")
    }

    private func labeledSlider(_ label: String, _ icon: String, value: Binding<Double>, range: ClosedRange<Double>, p: Palette) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2).foregroundStyle(p.textDim).frame(width: 16)
            Slider(value: value, in: range).tint(p.accent)
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { state.opacity }, set: { model.setPlateOpacity($0) })
    }
    private var widthBinding: Binding<Double> {
        Binding(get: { state.widthMeters }, set: { model.setPlateWidth($0) })
    }
    private var rotationBinding: Binding<Double> {
        Binding(get: { state.rotationDeg }, set: { model.setPlateRotation($0) })
    }
}
