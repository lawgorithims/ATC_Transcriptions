import MapKit

/// A tappable NASA EONET hazard marker (wildfire / storm / dust / volcano). The event id keys the
/// map diff; the full event lives in the coordinator's `hazardEventsByID` side map for the probe.
final class HazardAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let eventID: String
    let category: EONETCategory

    init(_ ev: EONETEvent) {
        coordinate = CLLocationCoordinate2D(latitude: ev.point.lat, longitude: ev.point.lon)
        title = ev.title
        subtitle = ev.category.label
        eventID = ev.id
        category = ev.category
    }

    /// Marker / overlay tint per category — warm hazard hues, distinct from the airspace blues and
    /// the magenta route so the layer reads at a glance.
    static func tint(_ cat: EONETCategory) -> UIColor {
        switch cat {
        case .wildfires:    return UIColor(red: 0.98, green: 0.45, blue: 0.09, alpha: 1)   // orange
        case .severeStorms: return UIColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1)   // violet
        case .dustHaze:     return UIColor(red: 0.71, green: 0.45, blue: 0.04, alpha: 1)   // ochre
        case .volcanoes:    return UIColor(red: 0.86, green: 0.15, blue: 0.15, alpha: 1)   // red
        }
    }
}

extension ChartMapView.Coordinator {
    /// Reconcile the hazard layer against `events` in place (the airspace/traffic diff pattern):
    /// survivors are untouched (no blink on a refresh), departed events are removed, arrivals are
    /// added, and an event whose newest geometry changed (a storm that moved) is torn down and
    /// re-added. Toggle-off passes `[]`, which clears everything.
    func syncHazards(_ mv: MKMapView, events: [EONETEvent]) {
        assert(events.count <= 400, "hazard snapshot is capped by EONETService")
        var wanted: [String: EONETEvent] = [:]
        for ev in events.prefix(400) where wanted[ev.id] == nil { wanted[ev.id] = ev }   // de-dupe (rule 2)

        for (id, prev) in hazardEventsByID where wanted[id]?.updatedAt != prev.updatedAt {
            removeHazard(id, from: mv)                              // departed, or moved → re-add below
        }
        for (id, ev) in wanted {
            hazardEventsByID[id] = ev
            guard hazardAnnByKey[id] == nil else { continue }       // survivor — untouched
            let ann = HazardAnnotation(ev)
            hazardAnnByKey[id] = ann
            mv.addAnnotation(ann)
            if ev.polygon.count >= 3 {
                let coords = ev.polygon.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let poly = MKPolygon(coordinates: coords, count: coords.count)
                hazardOverlayCategory[ObjectIdentifier(poly)] = ev.category
                hazardPolyByKey[id] = poly
                mv.addOverlay(poly, level: .aboveLabels)
            }
            if ev.track.count >= 2 {
                let coords = ev.track.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let line = MKPolyline(coordinates: coords, count: coords.count)
                hazardOverlayCategory[ObjectIdentifier(line)] = ev.category
                hazardTrackByKey[id] = line
                mv.addOverlay(line, level: .aboveLabels)
            }
        }
        assert(hazardAnnByKey.count <= 400, "annotation count bounded")
    }

    private func removeHazard(_ id: String, from mv: MKMapView) {
        if let ann = hazardAnnByKey.removeValue(forKey: id) { mv.removeAnnotation(ann) }
        if let poly = hazardPolyByKey.removeValue(forKey: id) {
            mv.removeOverlay(poly); hazardOverlayCategory[ObjectIdentifier(poly)] = nil
        }
        if let line = hazardTrackByKey.removeValue(forKey: id) {
            mv.removeOverlay(line); hazardOverlayCategory[ObjectIdentifier(line)] = nil
        }
        hazardEventsByID[id] = nil
    }
}
