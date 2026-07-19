import SwiftUI
import MapKit

/// The Logbook tab: every saved flight, newest first, with a detail view (breadcrumb map + metrics + stops +
/// editable aircraft/notes). Self-gated like the other tabs (renders only when it's the front tab).
struct LogbookTabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var logbook: Logbook

    var body: some View {
        let p = model.palette
        return Group {
            if model.selectedTab == .logbook {
                NavigationStack {
                    Group {
                        if logbook.flights.isEmpty { emptyState(p) } else { list(p) }
                    }
                    .background(p.bg)
                    .navigationTitle("Logbook")
                }
                .accessibilityIdentifier("tab-logbook")
            }
        }
    }

    private func list(_ p: Palette) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(logbook.flights) { f in
                    NavigationLink { LoggedFlightDetailView(flight: f) } label: { row(f, p) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("logbook-row")
                        .contextMenu { Button("Delete", role: .destructive) { logbook.delete(f.id) } }
                }
            }
            .padding(16)
        }
    }

    private func row(_ f: LoggedFlight, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(f.routeSummary).font(.headline).foregroundStyle(p.text)
                Spacer()
                Text(Self.day.string(from: f.startedAt)).font(.caption).foregroundStyle(p.textDim)
            }
            Text("\(f.durationText) · \(f.distanceText) · max \(f.maxSpeedText)")
                .font(.caption.monospaced()).foregroundStyle(p.textDim)
            Text(f.aircraftLine).font(.caption2).foregroundStyle(p.textDim)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
    }

    private func emptyState(_ p: Palette) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed").font(.system(size: 40)).foregroundStyle(p.textDim)
            Text("No flights yet").font(.headline).foregroundStyle(p.text)
            Text("Tap the ⏺ record button on the map to log a flight — the trip is saved here when you stop.")
                .font(.callout).foregroundStyle(p.textDim).multilineTextAlignment(.center)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f }()
}

/// One saved flight: the breadcrumb on a map + metrics + stops + editable aircraft/notes.
struct LoggedFlightDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var logbook: Logbook
    @State private var flight: LoggedFlight
    @State private var notes: String

    init(flight: LoggedFlight) {
        _flight = State(initialValue: flight)
        _notes = State(initialValue: flight.notes)
    }

    var body: some View {
        let p = model.palette
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let region = flight.mapRegion { trailMap(region, p).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12)) }
                Card(title: "Metrics") {
                    VStack(alignment: .leading, spacing: 8) {
                        KV("Date", LogbookTabView.day.string(from: flight.startedAt))
                        KV("Duration", flight.durationText)
                        KV("Distance", flight.distanceText)
                        KV("Max speed", flight.maxSpeedText)
                        KV("Avg speed", flight.avgSpeedText)
                        KV("Max altitude", flight.maxAltText)
                    }
                }
                if !flight.stops.isEmpty {
                    Card(title: "Stops (\(flight.stops.count))") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(flight.stops) { s in
                                KV(s.label, LoggedFlight.hms(s.durationSec))
                            }
                        }
                    }
                }
                Card(title: "Aircraft") {
                    Menu {
                        Button("Not recorded") { setAircraft(callsign: nil, type: nil) }
                        ForEach(model.aircraftProfiles) { a in
                            Button(a.displayLine) { setAircraft(callsign: a.callsign, type: a.type) }
                        }
                    } label: {
                        HStack { Text(flight.aircraftLine).foregroundStyle(p.text); Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(p.textDim) }
                    }
                }
                Card(title: "Notes") {
                    TextEditor(text: $notes).frame(minHeight: 90).scrollContentBackground(.hidden).foregroundStyle(p.text)
                }
                Button(role: .destructive) { logbook.delete(flight.id) } label: {
                    Label("Delete flight", systemImage: "trash").font(.callout)
                }.buttonStyle(.plainHaptic).tint(p.bad)
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle(flight.routeSummary)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { commitNotes() }
    }

    private func trailMap(_ region: (center: Coord, spanLat: Double, spanLon: Double), _ p: Palette) -> some View {
        let coords = flight.breadcrumb.map { $0.clCoord }
        let mkRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.center.lat, longitude: region.center.lon),
            span: MKCoordinateSpan(latitudeDelta: region.spanLat, longitudeDelta: region.spanLon))
        return Map(initialPosition: .region(mkRegion)) {
            MapPolyline(coordinates: coords).stroke(.orange, lineWidth: 3)
            if let s = coords.first { Marker("Start", systemImage: "airplane.departure", coordinate: s).tint(.green) }
            if let e = coords.last { Marker("End", systemImage: "airplane.arrival", coordinate: e).tint(.red) }
        }
    }

    private func setAircraft(callsign: String?, type: String?) {
        flight.aircraftCallsign = callsign; flight.aircraftType = type
        logbook.update(flight)
    }
    private func commitNotes() {
        guard notes != flight.notes else { return }
        flight.notes = notes; logbook.update(flight)
    }
}
