import SwiftUI
import MapKit
import PDFKit

/// A plate superimposed on the map, placed exactly from the FAA's embedded georeference (georef-only —
/// `overlayPlate` refuses plates without one, so there is no hand-placement and no move/scale UI). The
/// pilot adjusts opacity only; the placement itself is not editable. Still a reference aid — the caption
/// asks the pilot to verify before use. UIImage is not Equatable, so this type isn't either; `@Published`
/// fires on any assignment, which is all we need.
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

/// Draws the plate image into its geographic rect, rotated. Transparency is applied via the renderer's
/// compositor-level `alpha` (set in init, updated in place by `reconcilePlate`) — NOT `ctx.setAlpha` in
/// `draw`, because MapKit caches drawn overlay tiles and `setNeedsDisplay()` does not reliably
/// invalidate them, which left the opacity slider visually dead. `alpha` composites live, no redraw.
final class PlateOverlayRenderer: MKOverlayRenderer {
    private let plate: PlateImageOverlay
    init(_ o: PlateImageOverlay) {
        plate = o
        super.init(overlay: o)
        alpha = CGFloat(o.opacity)     // self-initialize so a renderer created mid-slide is correct
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard plate.image.cgImage != nil else { return }
        let center = point(for: MKMapPoint(plate.centerCoord))
        let ppm = MKMapPointsPerMeterAtLatitude(plate.centerCoord.latitude)
        let br = plate.boundingMapRect
        let scale = rect(for: br).width / max(br.width, 1)         // renderer points per map point
        let wpx = plate.widthMeters * ppm * scale
        let hpx = plate.heightMeters * ppm * scale
        ctx.saveGState()
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

/// The bottom control bar shown while a plate is overlaid on the map: the plate's name, the
/// auto-aligned caveat, an opacity slider, and a close button. Placement is exact (FAA embedded
/// georeference) and deliberately NOT editable — the old move/scale/rotate controls are gone.
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
                    Label("Auto-aligned — verify before use", systemImage: "checkmark.seal")
                        .font(.caption2).labelStyle(.titleAndIcon).foregroundStyle(p.good)
                }
                Spacer(minLength: 4)
                Button { model.clearPlateOverlay() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(p.textDim).accessibilityIdentifier("plate-remove")
            }
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled").font(.caption2).foregroundStyle(p.textDim).frame(width: 16)
                Slider(value: opacityBinding, in: 0.1...1).tint(p.accent)
                    .accessibilityIdentifier("plate-opacity-slider")
            }
        }
        .padding(12)
        .background(p.surface.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        // A .contain container: children keep their OWN identifiers (a bare .accessibilityIdentifier
        // on the VStack would stamp every child, clobbering plate-opacity-slider for UI tests).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plate-control-bar")
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { state.opacity }, set: { model.setPlateOpacity($0) })
    }
}
