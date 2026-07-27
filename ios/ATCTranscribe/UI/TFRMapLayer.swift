import MapKit

extension ChartMapView.Coordinator {
    /// Reconcile the live TFR layer against `tfrs` in place (the hazard/airspace diff pattern): a
    /// survivor whose geometry+altitudes are unchanged is left untouched (no blink on a 30-min refresh),
    /// a departed TFR is removed, an arrival is added (red-filled polygon + a ceiling/floor altitude
    /// block on its top edge), and a TFR whose boundary/limits changed is torn down and re-added.
    /// Toggle-off (and thermal/background pause) passes `[]`, clearing everything.
    func syncTFRs(_ mv: MKMapView, tfrs: [TFR]) {
        assert(tfrs.count <= 400, "TFR snapshot is capped by TFRService")
        var wanted: [String: TFR] = [:]
        for t in tfrs.prefix(400) where wanted[t.id] == nil && t.hasGeometry { wanted[t.id] = t }

        for (id, prev) in tfrByID where wanted[id] != prev {   // TFR is Equatable → catches a moved/re-issued NOTAM
            removeTFR(id, from: mv)
        }
        var addedLabels: [AirspaceLabelAnnotation] = []
        for (id, t) in wanted {
            tfrByID[id] = t
            guard tfrPolyByKey[id] == nil else { continue }    // survivor — untouched
            // One polygon + one altitude block PER AFFECTED AREA — the DC SFRA's ring and FRZ are
            // separate shapes with their own bands, never one concatenated ring (the wedge bug).
            var polys: [MKPolygon] = []; var labels: [AirspaceLabelAnnotation] = []
            for area in t.areas.prefix(64) where area.ring.count >= 3 {
                let coords = area.ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let poly = MKPolygon(coordinates: coords, count: coords.count)
                tfrOverlayIDs.insert(ObjectIdentifier(poly))
                polys.append(poly)
                mv.addOverlay(poly, level: .aboveLabels)
                if let top = area.labelCoord {                 // altitude block on the area's northernmost vertex
                    let label = AirspaceLabelAnnotation(
                        coord: CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon),
                        ceiling: AirspaceLabelAnnotation.altText(area.ceilingFt),
                        floor: AirspaceLabelAnnotation.altText(area.floorFt),
                        color: Self.airspaceColor("TFR"))
                    labels.append(label)
                    addedLabels.append(label)
                }
            }
            tfrPolyByKey[id] = polys
            tfrLabelByKey[id] = labels
        }
        if !addedLabels.isEmpty { mv.addAnnotations(addedLabels) }
        assert(tfrPolyByKey.count <= 400, "TFR overlay count bounded")
    }

    private func removeTFR(_ id: String, from mv: MKMapView) {
        for poly in tfrPolyByKey.removeValue(forKey: id) ?? [] {
            mv.removeOverlay(poly); tfrOverlayIDs.remove(ObjectIdentifier(poly))
        }
        for label in tfrLabelByKey.removeValue(forKey: id) ?? [] { mv.removeAnnotation(label) }
        tfrByID[id] = nil
    }
}
