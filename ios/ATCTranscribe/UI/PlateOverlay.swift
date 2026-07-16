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
    let pdf: String                // the plate's PDF filename — "View full page" opens it in the Plates tab
    let image: UIImage             // the original rendered page (black-on-white)
    var invertedImage: UIImage?    // lazily-computed color-inverted page (night mode); nil until first invert
    let imageAspect: Double        // width / height
    var centerLat: Double
    var centerLon: Double
    var widthMeters: Double        // geographic width the page spans (height follows the aspect)
    var rotationDeg: Double        // clockwise from north
    var opacity: Double
    var inverted: Bool = false     // show the color-inverted page (dark-cockpit night mode)

    /// The page actually drawn on the map — inverted when requested (falls back to the original if the
    /// inverted render isn't ready yet).
    var displayImage: UIImage { inverted ? (invertedImage ?? image) : image }
    var heightMeters: Double { PlatePlacement.heightMeters(widthMeters: widthMeters, imageAspect: imageAspect) }
    var center: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon) }

    /// A cheap identity of the GEOMETRY (not the image) so the map only rebuilds the overlay when the
    /// placement actually changed — opacity/invert are folded into the reconcile trigger separately.
    var geoKey: String { "\(centerLat),\(centerLon),\(widthMeters),\(rotationDeg)" }
}

/// MKOverlay wrapping a plate image at a geographic placement.
final class PlateImageOverlay: NSObject, MKOverlay {
    let image: UIImage
    let centerCoord: CLLocationCoordinate2D
    let widthMeters: Double
    let heightMeters: Double
    let rotationDeg: Double
    let opacity: Double            // baked into the draw; a change rebuilds the overlay (see reconcilePlate)
    let inverted: Bool             // tracked so an invert toggle rebuilds the overlay

    init(state: PlateOverlayState) {
        image = state.displayImage
        centerCoord = state.center
        widthMeters = state.widthMeters
        heightMeters = state.heightMeters
        rotationDeg = state.rotationDeg
        opacity = state.opacity
        inverted = state.inverted
    }
    var coordinate: CLLocationCoordinate2D { centerCoord }
    var boundingMapRect: MKMapRect {
        PlatePlacement.boundingMapRect(centerLat: centerCoord.latitude, centerLon: centerCoord.longitude,
                                       widthMeters: widthMeters, heightMeters: heightMeters, rotationDeg: rotationDeg)
    }
}

/// Draws the plate image into its geographic rect, rotated, with the opacity BAKED INTO THE DRAW
/// (`ctx.setAlpha`). This is the only alpha path that works everywhere: the compositor-level
/// `MKOverlayRenderer.alpha` is honored by the simulator but IGNORED for custom renderers on real
/// devices (Metal path), which made the slider look dead on hardware while the sim test passed.
/// An opacity change therefore requires a fresh draw — `reconcilePlate` rebuilds the overlay
/// (add-new-then-remove-old, so there's never a blank gap) and the new renderer draws at the new alpha.
final class PlateOverlayRenderer: MKOverlayRenderer {
    private let plate: PlateImageOverlay
    init(_ o: PlateImageOverlay) {
        plate = o
        super.init(overlay: o)
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
        // coordinate flip). The opacity is passed EXPLICITLY to draw(in:blendMode:alpha:) — the one
        // alpha path UIKit guarantees — rather than via ctx.setAlpha, whose graphics-state propagation
        // through UIImage.draw proved unreliable on the MapKit tile renderer.
        UIGraphicsPushContext(ctx)
        plate.image.draw(in: CGRect(x: -wpx / 2, y: -hpx / 2, width: wpx, height: hpx),
                         blendMode: .normal, alpha: CGFloat(plate.opacity))
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

    /// The first page rendered UPRIGHT for an airport-diagram thumbnail. Some FAA diagrams sit on a PDF
    /// page with a `/Rotate` flag (landscape airports), which a naive raster draws on its side. PDFKit's
    /// `thumbnail(of:for:)` honours the page rotation, so the diagram always reads upright (labels
    /// horizontal). The canvas is sized to the ROTATED display bounds so it fills without letterboxing.
    /// (We deliberately DON'T force true-north — that would turn the FAA's readable labels sideways;
    /// diagrams keep their published orientation with the north arrow intact, as every EFB shows them.)
    static func northUpFirstPage(pdfURL: URL, pdf: String, maxDimension: CGFloat = 600) -> UIImage? {
        guard let doc = PDFDocument(url: pdfURL), let page = doc.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation == 90 || page.rotation == 270
        let display = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard display.width > 1, display.height > 1 else { return nil }
        let s = min(maxDimension / display.width, maxDimension / display.height, 4)
        return page.thumbnail(of: CGSize(width: display.width * s, height: display.height * s), for: .mediaBox)
    }

    /// Colour-invert a rendered page (black-on-white → white-on-black) for a dark-cockpit night view.
    /// Synchronous CoreImage raster — call OFF the main actor (it's a full-page bitmap). nil on failure.
    static func inverted(_ image: UIImage) -> UIImage? {
        guard let ci = CIImage(image: image),
              let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        guard let out = filter.outputImage,
              let cg = Self.ciContext.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    private static let ciContext = CIContext(options: nil)
}

// MARK: - On-plate settings button (SwiftUI, positioned at the plate's top-right corner screen-point)

/// A single gear button riding the PLATE's own top-right corner — MapHostView positions it from the
/// corner screen-point streamed by the map, so it pans/zooms with the plate. Tapping it drops the plate
/// menu down from the top of the screen (overriding the console bar). SwiftUI-layered over the map (not
/// an MKAnnotationView) so its tap never fights MapKit's pan recognizer. Dims with the plate's own
/// opacity, floored so it can never become unfindable.
struct PlateCornerSettingsButton: View {
    @EnvironmentObject var model: AppModel
    let opacity: Double

    var body: some View {
        let p = model.palette
        Button {
            Haptics.impact(.light)
            withAnimation(.easeInOut(duration: 0.2)) { model.showPlateMenu = true }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(p.text)
                .frame(width: 36, height: 36)
                .background(Circle().fill(p.surface.opacity(0.94)))
                .overlay(Circle().stroke(p.border, lineWidth: 1))
                .padding(14)                        // invisible hit halo — cockpit-friendly target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHaptic)
        .opacity(max(opacity, 0.4))
        .accessibilityIdentifier("plate-settings-button")
    }
}

/// The plate menu that drops from the top of the screen (overriding the console top bar) when the
/// plate's gear is tapped: hide the plate, view it full-page in the Plates tab, an opacity slider, an
/// invert-colours toggle, and a close. Also closable by a two-finger swipe (wired in ConsoleView).
struct PlateMenuBar: View {
    @EnvironmentObject var model: AppModel
    let state: PlateOverlayState

    var body: some View {
        let p = model.palette
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext").foregroundStyle(p.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.name).font(.callout.weight(.semibold)).foregroundStyle(p.text).lineLimit(1)
                    Text("Plate on map · \(state.airport)").font(.caption2).foregroundStyle(p.textDim)
                }
                Spacer(minLength: 8)
                Button {
                    Haptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.2)) { model.showPlateMenu = false }
                } label: {
                    Image(systemName: "chevron.up").font(.body.weight(.semibold)).foregroundStyle(p.textDim)
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plainHaptic).accessibilityIdentifier("plate-menu-close")
            }
            // Actions
            HStack(spacing: 8) {
                menuAction("Hide plate", "eye.slash", id: "plate-menu-hide") {
                    model.clearPlateOverlay()            // clearing the plate also dismisses this menu
                }
                menuAction("Full page", "arrow.up.left.and.arrow.down.right", id: "plate-menu-fullpage") {
                    model.openPlateFullPage()
                }
                menuAction(state.inverted ? "Normal" : "Invert", "circle.righthalf.filled",
                           id: "plate-menu-invert", active: state.inverted) {
                    model.togglePlateInvert()
                }
            }
            // Opacity slider (in normal screen space → no MapKit gesture conflict)
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled").font(.caption).foregroundStyle(p.textDim).frame(width: 18)
                Slider(value: opacityBinding, in: AppModel.plateMinOpacity...1).tint(p.accent)
                    .accessibilityIdentifier("plate-opacity-slider")
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(p.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plate-menu")
    }

    private func menuAction(_ label: String, _ icon: String, id: String, active: Bool = false,
                            _ run: @escaping () -> Void) -> some View {
        let p = model.palette
        return Button {
            Haptics.impact(.light)
            run()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.body)
                Text(label).font(.caption2)
            }
            .foregroundStyle(active ? p.bg : p.text)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(active ? p.accent : p.surfaceAlt)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border, lineWidth: 1))
        }
        .buttonStyle(.plainHaptic).accessibilityIdentifier(id)
    }

    private var opacityBinding: Binding<Double> {
        Binding(get: { state.opacity }, set: { model.setPlateOpacity($0) })
    }
}
