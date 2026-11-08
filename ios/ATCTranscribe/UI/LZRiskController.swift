import Foundation
import SwiftUI

/// Owns the LZ layer's device-side state: which packs are mounted, which ruleset is compiled for
/// the pilot's aircraft, and the closure the tile server calls to render.
///
/// WHERE THE AIRCRAFT ENTERS
/// The pack is aircraft-agnostic. This is the object that binds it to an aircraft, and it does so
/// by RECOMPILING — producing a new signature, hence a new tile URL template, hence a clean cache.
/// Switching aeroplanes visibly re-tints the map, which is deliberate: it is the clearest possible
/// statement that the same ground is not equally landable for everything that flies.
///
/// WHY A SEPARATE OBJECT AND NOT AppModel
/// AppModel is a large, hot, main-actor object that many views observe; adding a pack store and a
/// compositor to it would republish the world on every reload. This is a nested ObservableObject
/// the map subscribes to directly — the same shape as `deviceLocation` and `windAloft`.
@MainActor
final class LZRiskController: ObservableObject {

    /// Shared, because two views now need the SAME instance: the map, which owns the render loop
    /// and the energy sweep, and the landable-ground panel, which asks what that sweep found. A
    /// second instance would run its own sweep and answer from a different footprint than the one
    /// on screen — the list and the map disagreeing about what is reachable.
    static let shared = LZRiskController()


    /// True when at least one `.lzpack` is mounted and a ruleset compiled.
    @Published private(set) var packAvailable = false
    /// Nil until everything needed to render exists. The map passes this straight into the tile
    /// URL template, so nil means "do not add the layer at all".
    @Published private(set) var signature: String?
    /// Why the layer is unavailable, when it is — so the UI can explain an empty map instead of
    /// showing nothing and letting the pilot guess.
    @Published private(set) var status: String = "not loaded"

    private var store: LZPackStore?
    private var compositor: LZTileCompositor?
    private var document: Data?
    private var lastKey: String = ""

    /// Cheap identity of the inputs that change what a pixel renders.
    ///
    /// `packs` is the mounted SET's fingerprint, not its count. A count cannot tell "installed a
    /// cell" from "installed one and removed another", and the second case leaves every cached tile
    /// composited from a pack that is gone.
    private static func key(aircraft: AircraftProfile?, night: Bool, packs: String) -> String {
        let a = aircraft.map { "\($0.glideRatio ?? -1)|\($0.bestGlideKts ?? -1)" } ?? "default"
        return "\(a)|\(night ? "n" : "d")|\(packs)"
    }

    /// Rebuild only when something that affects rendering actually changed. Called from the map's
    /// apply pass, so it must be cheap on the common path.
    func refresh(aircraft: AircraftProfile?, theme: AppTheme) {
        if store == nil { mount() }
        guard let store, store.isAvailable else {
            packAvailable = false
            signature = nil
            return
        }
        let night = (theme == .night)
        let fingerprint = store.packFingerprint
        let k = Self.key(aircraft: aircraft, night: night, packs: fingerprint)
        guard k != lastKey || compositor == nil else { return }
        lastKey = k

        guard let doc = document else {
            status = "ruleset missing from the app bundle"
            packAvailable = false
            signature = nil
            return
        }
        // The whole mounted set's fingerprint joins the signature, not just the first pack's stamp:
        // reinstalling a rebuilt pack under the same filename must not be served from the previous
        // pack's cached tiles, and with several packs mounted "the first one" is an arbitrary pick
        // that says nothing about the other eleven.
        guard let rules = LZRulesetCompiler.compile(document: doc, aircraft: aircraft,
                                                    themeKey: night ? "night" : "day",
                                                    packStamp: fingerprint) else {
            status = "ruleset failed to compile — layer withheld"
            packAvailable = false
            signature = nil
            return
        }
        let c = LZTileCompositor(store: store, rules: rules, night: night)
        // ⚠️ THE HAZARD VETO, AND IT IS SILENTLY OPTIONAL. The avoid map is a ~1 GB download the
        // pilot may not have; when it is absent this closure returns nil, `verdict` treats that as
        // "never consulted", and the layer scores exactly as it did before. That is deliberate — but
        // it also means the shading is WEAKER without the avoid map than with it, and the layer
        // currently gives the pilot no way to tell which they are looking at. Say so in the UI
        // before this is ever ungated (`AppModel.offFieldLayerAvailable`).
        //
        // ⚠️ `mask`, NOT `maskWithLandCover`, AND THAT IS DELIBERATE. Under avoid schema 2 a z12
        // tile holds the hazards and steep ground only; `maskWithLandCover` fetches the z11 parent
        // to add water, developed and trees back. This veto does not want them — the pack judges
        // land cover itself, and vetoing it twice is what makes the OTHER half of the eval worse.
        // `LZTileCompositor.avoidVetoMask` is a subset of what survives at z12, so this is already
        // a complete answer for every bit it reads, and it skips a second tile fetch per tile.
        // `LZAvoidVetoTests.testEveryBitTheVetoReadsSurvivesAtTheFinestZoom` pins that.
        c.avoidMask = { z, x, y in AvoidMapStore.shared.mask(z: z, x: x, y: y) }
        compositor = c
        compositorForSampling = c
        signature = c.signature
        packAvailable = true
        status = "\(store.readers.count) pack(s), ruleset \(rules.rulesetVersion)"
    }

    /// Rescan the pack directory. Cheap enough to call when the layer is switched on.
    func mount() {
        let s = LZPackStore()
        store = s
        document = LZRulesetCompiler.loadDocument()
        lastKey = ""
        if !s.isAvailable {
            status = s.rejected.isEmpty
                ? "no .lzpack installed in Application Support/lz"
                : "pack refused: \(s.rejected.joined(separator: "; "))"
        }
        assert(document != nil || !s.isAvailable, "a mounted pack with no ruleset cannot render")
    }

    /// A pack landed (or was deleted) while the app was running — pick it up NOW.
    ///
    /// `mount()` alone is not enough: the map's `.task(id:)` keys on aircraft/theme/layer state,
    /// none of which changes when a download finishes, so a pack that arrived while the map was on
    /// screen stayed invisible until the pilot toggled something. Downloading 88 MB and watching
    /// the map not change is indistinguishable from the layer being broken.
    ///
    /// Idempotent and cheap when nothing moved: `refresh` re-keys on the mounted fingerprint and
    /// returns immediately if it matches.
    func packsChangedOnDisk(aircraft: AircraftProfile?, theme: AppTheme) {
        mount()
        refresh(aircraft: aircraft, theme: theme)
        assert(store != nil, "packsChangedOnDisk must leave a store mounted")
    }

    /// Handed to `MBTilesHTTPServer.setLZProvider`. Runs on the server's concurrent queue, so it
    /// must not touch main-actor state — it captures the immutable compositor instead.
    nonisolated func makeProvider(_ c: LZTileCompositor?)
        -> ((String, Int, Int, Int) -> Data?)? {
        guard let c else { return nil }
        return { sig, z, x, y in c.tilePNG(signature: sig, z: z, x: x, y: y) }
    }

    var provider: ((String, Int, Int, Int) -> Data?)? { makeProvider(compositor) }

    /// The detail-card path: what does the layer say about this exact point, and which rules said it.
    func sample(lon: Double, lat: Double) -> LZSampleInfo? {
        compositor?.sample(lon: lon, lat: lat)
    }

    // MARK: - The live energy field

    /// Current arrival-energy bands, or empty when the layer has nothing trustworthy to draw.
    @Published private(set) var energyBands: [LZEnergyBand] = []
    /// WHERE the bands above were computed from. The sweep runs every five seconds and the aeroplane
    /// does not wait — at 140 kt it is a quarter of a mile further on before the next one lands — so
    /// the map slides the footprint from this anchor to where the aeroplane is being drawn. Without it
    /// the bands sat still and then jumped, which is what "the glide bars move independently" looked
    /// like from the cockpit. nil whenever there are no bands.
    @Published private(set) var energyAnchor: Coord?
    /// One line for the badge: whether wind was used, whether coverage was lost, whose glide ratio,
    /// and — once the map has answered — how many band polygons it actually drew.
    @Published private(set) var energyStatus: String = ""
    /// Everything in `energyStatus` except the drawn count, so the count can be re-appended without
    /// the line growing a new copy of itself on every render callback.
    private var energyStatusBase: String = ""
    /// Polygons the map's shape source last accepted. -1 = the map has not reported yet.
    private var energyRendered = -1

    /// Called back by the map after it installs the band polygons. This is the only signal that
    /// closes the loop: the field computing and the map DRAWING it are separate failures, and during
    /// development the second one happened silently while the first said everything was fine.
    func noteEnergyRendered(_ count: Int) {
        assert(count >= 0, "negative polygon count")
        guard count != energyRendered else { return }
        energyRendered = count
        recomposeEnergyStatus()
    }

    private func recomposeEnergyStatus() {
        guard !energyStatusBase.isEmpty else { return }
        energyStatus = energyRendered >= 0
            ? "\(energyStatusBase) · \(energyRendered) drawn"
            : energyStatusBase
    }

    /// Its OWN terrain reader. `TerrainElevation.shared` is main-actor-only by convention and
    /// `AppModel.nrstTerrain` is sound only because exactly one NRST compute runs at a time — a
    /// second consumer faulting the same mmap from another queue is the bug that comment forbids.
    private nonisolated(unsafe) static let energyTerrain = TerrainElevation()
    private var energyInFlight = false

    /// Recompute the footprint from the current fix. Cheap to call on a timer: it returns
    /// immediately while a previous sweep is still running, and clears rather than holds stale
    /// bands whenever the position becomes untrustworthy.
    ///
    /// A STALE FOOTPRINT IS WORSE THAN NONE. The bands say "you can reach here from where you are";
    /// drawn against a position the integrity monitor has disowned, or an altitude that is minutes
    /// old, they are a claim about a situation that no longer exists.
    func refreshEnergy(coord: Coord?, altitudeFtMSL: Double?, aircraft: AircraftProfile?,
                       wind: (fromDeg: Double, kts: Double)?, verticalAccuracyM: Double?,
                       trackDeg: Double? = nil) async {
        // Distinguish the two reasons. They are different problems with different fixes, and
        // lumping them together sends a pilot looking for a GPS fault when the receiver is fine
        // and it is the altitude that is missing (exactly what the Simulator does — CoreLocation
        // there supplies a position with no usable altitude at all).
        guard let coord else {
            clearEnergy(reason: "no trusted position — GPS suppressed or unavailable")
            return
        }
        guard let alt = altitudeFtMSL, alt.isFinite else {
            clearEnergy(reason: "position OK, but no altitude — cannot compute a glide footprint")
            return
        }
        guard !energyInFlight else { return }
        energyInFlight = true
        defer { energyInFlight = false }

        let ratio = aircraft?.glideRatio ?? NearestAirports.defaultGlideRatio
        let input = LZGlideField.Input(
            coord: coord, altitudeFtMSL: alt, glideRatio: ratio,
            isDefaultGlideRatio: aircraft?.glideRatio == nil,
            bestGlideKts: Double(aircraft?.bestGlideKts ?? 65),
            windFromDeg: wind?.fromDeg, windKts: wind?.kts,
            verticalAccuracyM: verticalAccuracyM,
            trackDeg: trackDeg)

        // Off the main actor: a 64-ray sweep over an mmapped grid is not render-loop work.
        let field = await Task.detached(priority: .utility) {
            LZGlideField.compute(input, terrain: Self.energyTerrain)
        }.value

        guard let field else {
            clearEnergy(reason: "terrain grid unavailable")
            return
        }
        guard field.maxRangeNm > 0 else {
            // Below the arrival reserve there is nothing to draw, and saying "0 nm" reads like a
            // failure. Name the actual condition.
            clearEnergy(reason: "below glide reserve — no footprint from this height")
            return
        }
        energyBands = field.bands
        energyAnchor = coord          // slide them from here — see `energyAnchor`
        energyFieldSnapshot = field
        var parts = [String]()
        // Say what the footprint was charged for, the same words the airport list uses.
        parts.append(field.usedWind ? "headwind applied" : "still air (no current winds)")
        if trackDeg != nil { parts.append("turns included") }
        if field.isDefaultGlideRatio { parts.append("default \(Int(ratio)):1 — set your glide ratio") }
        if field.sawHole { parts.append("terrain coverage incomplete") }
        parts.append(String(format: "%.0f nm", field.maxRangeNm))
        energyStatusBase = parts.joined(separator: " · ")
        recomposeEnergyStatus()
    }

    func clearEnergy(reason: String) {
        guard !energyBands.isEmpty || energyStatus != reason else { return }
        energyBands = []
        energyAnchor = nil
        energyFieldSnapshot = nil
        // A reason is a whole answer, not a base to append a polygon count to — "layer off · 0 drawn"
        // reads as a fault report about a layer nobody asked to draw.
        energyStatusBase = ""
        energyRendered = -1
        energyStatus = reason
    }

    /// The last computed footprint, kept so the site search can ask "what can I reach" without
    /// re-running a 64-ray sweep the energy layer has already done this second.
    private(set) var energyFieldSnapshot: LZEnergyField?

    /// A `Sendable` closure over the immutable compositor, for scoring ground off the main actor.
    /// Handing out the compositor itself would invite a caller to hold it past a recompile.
    nonisolated var sampler: @Sendable (Coord) -> LZSampleInfo? {
        let c = compositorForSampling
        return { coord in c?.sample(lon: coord.lon, lat: coord.lat) }
    }

    /// Snapshot of the compositor reference, safe to capture. Nil until a pack and ruleset exist.
    private nonisolated(unsafe) var compositorForSampling: LZTileCompositor?

    /// Data vintages for the card's provenance line.
    var vintages: [String: String] { store?.vintages ?? [:] }
    var maxZoom: Int { store?.maxZoom ?? 13 }
    var minZoom: Int { store?.minZoom ?? 6 }
}
