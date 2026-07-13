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
        for t in tfrs.prefix(400) where wanted[t.id] == nil && t.polygon.count >= 3 { wanted[t.id] = t }

        for (id, prev) in tfrByID where wanted[id] != prev {   // TFR is Equatable → catches a moved/re-issued NOTAM
            removeTFR(id, from: mv)
        }
        var addedLabels: [AirspaceLabelAnnotation] = []
        for (id, t) in wanted {
            tfrByID[id] = t
            guard tfrPolyByKey[id] == nil else { continue }    // survivor — untouched
            let coords = t.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let poly = MKPolygon(coordinates: coords, count: coords.count)
            tfrOverlayIDs.insert(ObjectIdentifier(poly))
            tfrPolyByKey[id] = poly
            mv.addOverlay(poly, level: .aboveLabels)
            if let top = t.labelCoord {                        // altitude block on the northernmost vertex
                let label = AirspaceLabelAnnotation(
                    coord: CLLocationCoordinate2D(latitude: top.lat, longitude: top.lon),
                    ceiling: AirspaceLabelAnnotation.altText(t.ceilingFt),
                    floor: AirspaceLabelAnnotation.altText(t.floorFt),
                    color: Self.airspaceColor("TFR"))
                tfrLabelByKey[id] = label
                addedLabels.append(label)
            }
        }
        if !addedLabels.isEmpty { mv.addAnnotations(addedLabels) }
        assert(tfrPolyByKey.count <= 400, "TFR overlay count bounded")
    }

    private func removeTFR(_ id: String, from mv: MKMapView) {
        if let poly = tfrPolyByKey.removeValue(forKey: id) {
            mv.removeOverlay(poly); tfrOverlayIDs.remove(ObjectIdentifier(poly))
        }
        if let label = tfrLabelByKey.removeValue(forKey: id) { mv.removeAnnotation(label) }
        tfrByID[id] = nil
    }
}
