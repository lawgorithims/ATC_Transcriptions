#!/usr/bin/env python3
"""Build `cifp.sqlite` — coded terminal procedures (approach/SID/STAR legs), ILS/localizer, and runway
geometry — from the FAA CIFP (public domain, ARINC 424 v18). This is the georeferenced procedure data
that backs the map overlay + corrector grounding (fix idents → lat/lon, not plate PDFs).

Source: https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_<YYMMDD>.zip → the `FAACIFP18` file, fixed-width
132-column records. The field layout below is read empirically from the FAA's own public-domain data
file (records like `SUSAP KBOSK6F...`), not from the copyrighted ARINC-424 specification. Emits a
compact SQLite queried per-airport by the app (`Core/CIFP.swift`).

Run (regenerate each 28-day cycle):
    python3 build_cifp.py [--zip local.zip | --cifp local/FAACIFP18] [--date YYMMDD] [--out path.sqlite]
"""
import argparse, datetime as dt, io, os, re, sqlite3, urllib.request, zipfile

BASE = "https://aeronav.faa.gov/Upload_313-d/cifp/"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
LATLON = re.compile(r"([NS])(\d{8})([EW])(\d{9})")   # DDMMSSss / DDDMMSSss, as it appears in every geo record

# Approach-ident first letter → readable approach type (common FAA/ARINC codings).
#
# R vs H is easy to get backwards and the consequence is not cosmetic: RNP AR approaches require
# specific operator and aircrew authorization, so labelling one "RNAV (GPS)" invites a pilot to fly an
# approach they are not approved for. The assignment below is settled against this repo's own d-TPP
# plate index at the same cycle — KMDW codes H22LX/H04RY against the published "RNAV (RNP) X RWY 22L"
# and "RNAV (RNP) Y RWY 04R", and R04RZ/R22R against "RNAV (GPS) Z RWY 04R" / "RNAV (GPS) RWY 22R";
# KEGE agrees. The coded data carries the same signature: H idents hold 1,423 RF legs across 121
# airports with RNP down to 0.1, R idents hold 3 RF legs and never go below RNP 0.3.
# `X` is the LDA, not a localizer. All 15 X-coded approaches in cycle 2607 are charted LDA on that
# exact runway (KSLC X35, PHNL X26L, KDCA X19, KBIH X17 …), and an LDA is by definition NOT aligned
# with the runway centerline. Calling it "LOC" was worst at KSNA, where the real localizer L20R and the
# offset LDA X20R both rendered as "LOC RWY 20R" — two indistinguishable rows in the activation chooser.
# `S` is the VOR approach that REQUIRES DME, and it is not the same procedure as `V`: at KPNS, S08
# crosses NUN at 2000 ft and V08 at 2500 ft. Naming both "VOR" made them look interchangeable.
APPROACH_TYPE = {"I": "ILS", "X": "LDA", "L": "LOC", "B": "LOC BC", "R": "RNAV (GPS)", "H": "RNAV (RNP)",
                 "P": "GPS", "V": "VOR", "D": "VOR/DME", "N": "NDB", "Q": "NDB/DME", "S": "VOR/DME",
                 "G": "IGS", "U": "SDF", "T": "TACAN"}

# CIRCLING approaches carry no runway, so their ident is a type mnemonic plus the circling letter
# ("RNV-A", "VDMA", "LBC-B") and the runway rule below cannot expand it. Left as the raw ident, the
# stored name shared no approach-type token with the printed plate title — "RNV-A" against
# "RNAV (GPS)-A" — so the plate matcher scored an approach ZERO against its own plate.
CIRCLING_TYPE = {"RNV": "RNAV (GPS)", "VDM": "VOR/DME", "LBC": "LOC BC", "VOR": "VOR", "LDA": "LDA",
                 "NDB": "NDB", "LOC": "LOC", "GPS": "GPS", "SDF": "SDF", "TCN": "TACAN", "ILS": "ILS"}


def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=600).read()


# AIRAC cycles are 28 days. Anchor on cycle 2607, whose effective date (2026-07-09) is published in the
# FAA d-TPP metadata this repo already ingests — so the two datasets agree by construction.
CYCLE_ANCHOR = ("2607", dt.date(2026, 7, 9))


def cycle_dates(cycle):
    """(effective, expires) ISO dates for a YYNN AIRAC cycle. Expiry is the next cycle's effective date."""
    a_id, a_date = CYCLE_ANCHOR
    try:
        dy, dn = int(cycle[:2]) - int(a_id[:2]), int(cycle[2:]) - int(a_id[2:])
    except ValueError:
        return ("", "")
    eff = a_date + dt.timedelta(days=28 * (dn + dy * 13))     # 13 cycles per year
    return (eff.isoformat(), (eff + dt.timedelta(days=28)).isoformat())


def coord(line):
    """First lat/lon in a record → (lat, lon) decimal degrees, or None."""
    m = LATLON.search(line)
    if not m:
        return None
    la = int(m[2][0:2]) + int(m[2][2:4]) / 60 + (int(m[2][4:6]) + int(m[2][6:8]) / 100) / 3600
    lo = int(m[4][0:3]) + int(m[4][3:5]) / 60 + (int(m[4][5:7]) + int(m[4][7:9]) / 100) / 3600
    return (round(-la if m[1] == "S" else la, 6), round(-lo if m[3] == "W" else lo, 6))


def approach_name(ident):
    """"H33LX" → ("RNAV (RNP) X RWY 33L", "33L"); "RNV-A" → ("RNAV (GPS)-A", ""); else pass through.

    The MULTIPLE INDICATOR (the X/Y/Z in "RNAV (GPS) Z RWY 22") must survive. Y and Z to the same runway
    are DIFFERENT PROCEDURES — different minimums, different step-down fixes, different equipment
    requirements, and different MISSED APPROACH paths. Dropping the letter made 221 (airport, name)
    groups collide across 135 airports, so the activation chooser offered two identical rows and the
    pilot had no way to tell which go-around they were arming.

    ARINC 424 field 5.010 is positionally unambiguous, verified against the whole cycle:
      ident[3] is the runway side or a '-' placeholder — only '-', L, C, R (and a digit for COPTER).
      ident[4] is the multiple indicator — only Z(610) Y(595) X(46) W(10) V(5) U(2), never L/C/R.
    So the suffix is simply ident[4] on a 5-character runway ident. No letter heuristic, which would be
    unsafe: the trailing R of "R22R" is runway 22 RIGHT, not a suffix.
    """
    t = APPROACH_TYPE.get(ident[0])
    # `ident[1:3].isdigit()` alone also matched the three COPTER idents (KJFK R027, KLGA R250, 2P2 R029),
    # whose third digit is part of a BEARING, not a runway — they were stored as "RWY 02"/"RWY 25" for
    # runways those airports do not have.
    if t and len(ident) >= 3 and ident[1:3].isdigit() and not (len(ident) > 3 and ident[3].isdigit()):
        side = ident[3] if len(ident) > 3 and ident[3] in "LCR" else ""
        rwy = ident[1:3] + side
        suffix = ident[4] if len(ident) == 5 else ""
        return f"{t}{' ' + suffix if suffix else ''} RWY {rwy}", rwy
    if t and len(ident) == 4 and ident[1:4].isdigit():                # COPTER: type + 3-digit bearing
        return f"COPTER {t} {ident[1:4]}", ""
    circling = CIRCLING_TYPE.get(ident[:3])
    if circling:
        letter = ident[3:].lstrip("-").strip()
        return (f"{circling}-{letter}" if letter else circling), ""
    return ident, ""


def load_lines(args):
    if args.cifp:
        return [l.rstrip("\n") for l in open(args.cifp, encoding="latin-1")]
    if args.zip:
        zf = zipfile.ZipFile(args.zip)
    else:
        url = BASE + f"CIFP_{args.date}.zip"
        print("downloading", url, flush=True)
        zf = zipfile.ZipFile(io.BytesIO(fetch(url)))
    with zf.open("FAACIFP18") as fh:
        return [l.rstrip("\n") for l in io.TextIOWrapper(fh, encoding="latin-1")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip"); ap.add_argument("--cifp"); ap.add_argument("--date", default="260709")
    ap.add_argument("--out", default=os.path.join(
        os.path.dirname(__file__), "..", "ATCTranscribe", "Resources", "nav", "cifp.sqlite"))
    args = ap.parse_args()

    print("reading FAACIFP18…", flush=True)
    lines = load_lines(args)

    # The cycle comes from the file's OWN header record (`HDR01FAACIFP18 ... 2607 ...`), not from the
    # requested filename — so a mislabelled download can never stamp the wrong validity period onto the
    # data. Verified against the real file: the 4-digit AIRAC id sits at 0-based 35.
    cycle = ""
    if lines and lines[0].startswith("HDR01"):
        cand = lines[0][35:39]
        if cand.isdigit():
            cycle = cand
    if not cycle:
        raise SystemExit("CIFP header carries no readable cycle id — refusing to build undated data")
    print(f"CIFP header cycle: {cycle}")
    print("records:", len(lines), flush=True)

    # ---- pass 1: fix-coordinate table (ident → coord) from every geo-bearing fix/navaid record ----
    fixes = {}   # ident → (lat, lon)   (procedures reference fixes by ident; first geo record wins)
    # ⚠️ TERMINAL fixes are AIRPORT-SCOPED and must not go in the global table alone.
    #
    # A terminal waypoint or NDB belongs to one airport, and its ident is only unique WITHIN that
    # airport — "SJ" is the NDB at San Angelo, Texas AND the VOR at San Juan, Puerto Rico. Resolving
    # both through one first-wins table put 66 legs across 19 published approaches at 10 airports
    # 369-2,028 NM from their own field: every leg of KSJT's NDB RWY 03 — the IF, the procedure turn,
    # the final approach fix and the missed-approach hold — was placed in Puerto Rico.
    #
    # The ARINC record already states the owner: on a section-P record, 0-based columns 6-10 are the
    # airport identifier, which pass 2 below already reads as `apt`. So terminal records are keyed by
    # (airport, ident) as well, and pass 2 prefers that scoped entry over the global one.
    terminal_fixes = {}   # (airport, ident) → (lat, lon)
    # ⚠️ AND THE REAL DISAMBIGUATOR IS THE ARINC REGION. A short navaid ident is unique only within its
    # region: "SJ" is an NDB in region K4 (San Angelo, Texas, N31 16) AND an NDB in region TJ (San Juan,
    # Puerto Rico, N18 24), both section D subsection B. Airport scoping does not help, because neither
    # is a terminal record. The LEG record names the region it means — 0-based columns 34-36 — and the
    # navaid record carries its own at 19-21, so the two can simply be matched.
    region_fixes = {}     # (ident, region) → (lat, lon)
    def add_region(ident, region, c):
        if ident and region and c:
            region_fixes.setdefault((ident, region), c)
    def add_fix(ident, c):
        if ident and c and ident not in fixes:
            fixes[ident] = c
    def add_terminal(apt, ident, c):
        if apt and ident and c:
            terminal_fixes.setdefault((apt, ident), c)
    # ⚠️ SECTION P HAS TWO SUBSECTION POSITIONS. On a PROCEDURE record the subsection sits at 0-based 12
    # ("SUSAP KSJTK4F..." — F = approach); on a terminal NAVAID or WAYPOINT record it sits at 5
    # ("SUSAPNKBRDK3 BR" — N = NDB, airport KBRD at 6-10, region K3 at 10-12). Reading only position 12
    # meant the terminal-NDB branch NEVER FIRED, so airport scoping silently collected nothing for them.
    for l in lines:
        if len(l) < 40:
            continue
        sec = l[4]
        sub12 = l[12] if len(l) > 12 else " "
        sub5 = l[5]
        if sec == "E" and sub5 == "A":                          # enroute waypoint
            add_fix(l[13:18].strip(), coord(l))
        elif sec == "P" and (sub5 == "C" or sub12 == "C"):      # terminal waypoint
            add_terminal(l[6:10].strip(), l[13:18].strip(), coord(l))
            add_fix(l[13:18].strip(), coord(l))
        elif sec == "D":                                        # VHF navaid (VOR/DME/TACAN) and NDB
            add_region(l[13:17].strip(), l[19:21].strip(), coord(l))
            add_fix(l[13:17].strip(), coord(l))
        elif sec == "P" and (sub5 == "N" or sub12 == "N"):      # terminal NDB
            add_terminal(l[6:10].strip(), l[13:17].strip(), coord(l))
            add_region(l[13:17].strip(), l[10:12].strip(), coord(l))
            add_fix(l[13:17].strip(), coord(l))
        elif sec == "P" and (sub5 == "A" or sub12 == "A"):      # airport reference point
            add_fix(l[6:10].strip(), coord(l))
    nrf = 0
    print(f"fixes: {len(fixes)} global, {len(terminal_fixes)} airport-scoped, "
          f"{len(region_fixes)} region-scoped", flush=True)

    # ---- pass 2: procedures + legs (subsection D=SID, E=STAR, F=approach), runways (G), ILS (I) ----
    con = sqlite3.connect(args.out if False else ":memory:")
    con.executescript("""
      -- `route_type` is ARINC col 20 (0-based 19): it distinguishes an approach TRANSITION from the
      -- approach proper, and a SID runway-transition from its common/enroute portion. It was dropped by
      -- the previous builder, which is why segmentation had to be inferred downstream.
      -- `incomplete` is set when ANY record belonging to this procedure failed to parse (constraint:
      -- never emit a partial procedure that looks complete).
      CREATE TABLE procedure(id INTEGER PRIMARY KEY, airport TEXT, kind TEXT, ident TEXT, name TEXT,
                             runway TEXT, transition TEXT, route_type TEXT, incomplete INTEGER DEFAULT 0);
      -- Column names of the original six are unchanged so the shipped reader keeps working; everything
      -- after `alt` is new. `alt_desc` is the ARINC altitude-description qualifier (col 83, 0-based 82)
      -- WITHOUT which at / at-or-above / at-or-below / between are indistinguishable, and `alt2` is the
      -- second altitude that `between` requires. `wp_desc` char 4 carries the segment role (A=IAF,
      -- F=FAF, M=missed-approach point, I=final approach course fix, B=intermediate fix)
      -- — read, not inferred.
      CREATE TABLE leg(procedure_id INTEGER, seq INTEGER, fix TEXT, lat REAL, lon REAL,
                       leg_type TEXT, course_mag REAL, alt TEXT,
                       alt_desc TEXT, alt2 TEXT, speed_limit INTEGER, vertical_angle REAL,
                       turn TEXT, rnp REAL, wp_desc TEXT, recd_navaid TEXT,
                       -- RF (radius-to-fix) ARC CENTRE, resolved to a position at build time.
                       -- ARINC publishes the centre FIX at 0-based cols 106-111 with its own region at
                       -- 112-114; it was never extracted, so 1,439 RF legs had no centre and RNP AR
                       -- arcs — whose whole purpose is a fixed-radius turn threaded through terrain —
                       -- could only be drawn as straight chords. Stored as coordinates rather than an
                       -- ident because the centre is often a terminal waypoint the app's nav database
                       -- does not carry.
                       rf_lat REAL, rf_lon REAL);
      -- Provenance travels with the data (constraint: source/cycle/effective/expiration/ingested_at).
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE ils(airport TEXT, runway TEXT, ident TEXT, freq_mhz REAL, course_mag REAL, lat REAL, lon REAL);
      CREATE TABLE runway(airport TEXT, designator TEXT, lat REAL, lon REAL, bearing_mag REAL, length_ft INTEGER);
      CREATE TABLE airway(area TEXT, ident TEXT, seq INTEGER, fix TEXT, lat REAL, lon REAL, mea INTEGER, maa INTEGER);
      CREATE INDEX ix_proc_apt ON procedure(airport);
      CREATE INDEX ix_leg_proc ON leg(procedure_id);
      CREATE INDEX ix_ils_apt ON ils(airport);
      CREATE INDEX ix_rwy_apt ON runway(airport);
      CREATE INDEX ix_awy_ident ON airway(ident);
      CREATE INDEX ix_awy_lat ON airway(lat);
    """)
    proc_id = {}   # (airport, sub, ident, transition) → rowid
    nproc = nleg = nbad = 0
    bad_keys = set()   # procedures touched by a rejected record → marked incomplete

    def num(s, scale=1.0):
        """Signed fixed-point ARINC number -> float, or None. Absent stays absent (never defaulted)."""
        s = s.strip()
        neg = s.startswith("-")
        if neg:
            s = s[1:]
        if not s.isdigit():
            return None
        v = int(s) / scale
        return -v if neg else v

    def rnp_val(s):
        """ARINC RNP: 3 chars, 2 significant digits + a decimal-shift exponent (e.g. '10 '/'102')."""
        s = s.strip()
        if len(s) < 3 or not s[:2].isdigit() or not s[2].isdigit():
            return None
        return round(int(s[:2]) / (10 ** int(s[2])), 3)

    # ---- pass 2b: enroute airways (section E, subsection R) — V/J/T/Q routes as ordered fix chains.
    # Empirical layout: route ident 14-18, sequence 26-29, fix 30-34, MEA 84-88, MEA-2 89-93, MAA 94-98.
    nawy = 0
    def alt(s):
        s = s.strip()
        return int(s) if s.isdigit() and int(s) > 0 else None
    for l in lines:
        if len(l) < 98 or l[4] != "E" or l[5] != "R":
            continue
        ident = l[13:18].strip()
        seq = re.sub(r"\D", "", l[25:29])
        fix = l[29:34].strip()
        if not ident or not fix or not seq:
            continue
        c = fixes.get(fix)
        if c:
            # The AREA code (USA/PAC/…) disambiguates same-ident airways in different regions — the US
            # East Coast V1 and the Hawaii V1 are DIFFERENT airways; merging them draws bogus lines.
            # ARINC ER records carry two directional minimum-enroute altitudes (cols 84-88 and 89-93,
            # used when the MEA differs by direction of flight). Store the HIGHER so the card's floor is
            # never optimistically low for the opposite direction.
            mea1, mea2 = alt(l[83:88]), alt(l[88:93])
            mea = max(x for x in (mea1, mea2) if x is not None) if (mea1 or mea2) else None
            con.execute("INSERT INTO airway(area,ident,seq,fix,lat,lon,mea,maa) VALUES(?,?,?,?,?,?,?,?)",
                        (l[1:4].strip(), ident, int(seq), fix, c[0], c[1], mea, alt(l[93:98])))
            nawy += 1

    for l in lines:
        if len(l) < 60 or l[4] != "P":
            continue
        sub = l[12]
        apt = l[6:10].strip()
        if sub in "DEF":                                        # SID / STAR / Approach leg
            # ARINC's continuation-record number is NOT a boolean. '0' means "primary leg, nothing
            # follows"; '1' means "primary leg that HAS continuations"; '2'+ are the continuations
            # themselves. Both 0 and 1 are real legs. Rejecting everything but '0' threw away 6,741
            # primaries — and every single one of them was the FINAL APPROACH FIX, because the FAF is
            # exactly the leg that carries the LNAV/LPV minima-line continuation. That silently deleted
            # the FAF from 6,741 of 10,243 published approaches (96-99% of every RNAV approach in the
            # US) along with its published crossing altitude. Keep the primaries; drop only true
            # continuations, whose payload (minima lines, FAS data block) this app does not use.
            if l[38] not in "01":
                continue
            ident = l[13:19].strip()
            route_type = l[19].strip()
            trans = l[20:25].strip()
            seq = num(l[26:29])
            fix = l[29:34].strip()
            wp_desc = l[39:43]                        # char 4: A=IAF F=FAF M=MAP I=FACF B=intermediate
            turn = l[43].strip()
            rnp = rnp_val(l[44:47])
            leg_type = l[47:49].strip()
            recd = l[50:54].strip()                             # recommended navaid
            course = num(l[70:74], 10.0)                        # tenths of a degree
            alt_desc = l[82].strip()
            alt = l[84:89].strip()
            alt2 = l[89:94].strip()
            speed = num(l[99:102])
            vangle = num(l[102:106], 100.0)                     # hundredths of a degree, signed
            key = (apt, sub, ident, trans)
            if key not in proc_id:
                kind = {"D": "SID", "E": "STAR", "F": "IAP"}[sub]
                name, rwy = (approach_name(ident) if sub == "F" else (ident, ""))
                cur = con.execute("INSERT INTO procedure(airport,kind,ident,name,runway,transition,route_type) "
                                  "VALUES(?,?,?,?,?,?,?)", (apt, kind, ident, name, rwy, trans, route_type))
                proc_id[key] = cur.lastrowid
                nproc += 1
            # A leg with no sequence number or no path terminator cannot be flown, drawn, or ordered.
            # Reject it LOUDLY and mark its procedure incomplete, rather than shipping a procedure that
            # is quietly one leg short — which is exactly the failure this build could not see before,
            # because nothing ever incremented these counters.
            if seq is None or not leg_type:
                nbad += 1
                bad_keys.add(key)
                continue
            # EVERY leg is emitted, including fix-less ones. The previous builder's `if fix:` guard
            # silently discarded every altitude/heading/intercept-terminated leg (CA VA VI VR CI CD VD),
            # which left 706 SIDs in the database with NO legs at all — a named, selectable procedure
            # with no path. A leg with no fix still has a path terminator and a constraint.
            # THE AIRPORT'S OWN fix wins over the global table. `apt` is this procedure's airport, and a
            # terminal waypoint or NDB with the same ident elsewhere is a different point entirely —
            # see the note in pass 1. Falling back to the global table keeps enroute fixes and VHF
            # navaids, which are genuinely global, resolving exactly as before.
            # ⚠️ THE LEG TELLS YOU WHICH TABLE TO LOOK IN. Columns 34-36 are the fix's region and 36-37
            # its SECTION: "P" means a TERMINAL fix, which belongs to one airport, and "D"/"E" mean an
            # enroute navaid or waypoint, which is regional. Looking in the region table first got KBRD
            # wrong — three airports publish a terminal NDB called "BR" and two of them are in region
            # K3, so the region alone does not disambiguate and it picked Burlington's, 369 NM from
            # Brainerd. When the leg says the fix is terminal, the AIRPORT is the more specific key.
            fix_region = l[34:36].strip() if len(l) > 36 else ""
            fix_sec = l[36] if len(l) > 36 else " "
            if fix:
                if fix_sec == "P":                              # terminal: airport, then region
                    c = (terminal_fixes.get((apt, fix)) or region_fixes.get((fix, fix_region))
                         or fixes.get(fix))
                else:                                           # enroute: region, then airport
                    c = (region_fixes.get((fix, fix_region)) or terminal_fixes.get((apt, fix))
                         or fixes.get(fix))
            else:
                c = None
            # RF arc centre: the fix named at 106-111, resolved through the same most-specific-first
            # tables as the leg's own fix. Only RF legs carry one.
            rf = None
            if leg_type == "RF" and len(l) > 116:
                cfix, creg = l[106:111].strip(), l[112:114].strip()
                if cfix:
                    rf = (region_fixes.get((cfix, creg)) or terminal_fixes.get((apt, cfix))
                          or fixes.get(cfix))
                    if rf: nrf += 1
            con.execute("INSERT INTO leg(procedure_id,seq,fix,lat,lon,leg_type,course_mag,alt,"
                        "alt_desc,alt2,speed_limit,vertical_angle,turn,rnp,wp_desc,recd_navaid,"
                        "rf_lat,rf_lon) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (proc_id[key], seq, fix, c[0] if c else None, c[1] if c else None,
                         leg_type, course, alt, alt_desc, alt2, speed, vangle,
                         turn or None, rnp, wp_desc, recd or None,
                         rf[0] if rf else None, rf[1] if rf else None))
            nleg += 1
        elif sub == "G":                                        # runway: RWxx, length (21-26), bearing (27-30), threshold coord
            c = coord(l)
            con.execute("INSERT INTO runway(airport,designator,lat,lon,bearing_mag,length_ft) VALUES(?,?,?,?,?,?)",
                        (apt, l[13:18].strip(), c[0] if c else None, c[1] if c else None,
                         num(l[27:31], 10.0), num(l[21:27])))
        elif sub == "I":                                        # localizer/ILS: ident (13-16), freq (21-26), RWxx (27-31), course (51-54)
            c = coord(l)
            con.execute("INSERT INTO ils(airport,runway,ident,freq_mhz,course_mag,lat,lon) VALUES(?,?,?,?,?,?,?)",
                        (apt, l[27:32].strip(), l[13:17].strip(), num(l[21:27], 100.0),
                         num(l[51:55], 10.0), c[0] if c else None, c[1] if c else None))

    # Deduplicated terminal/approach-fix table for the map's zoomed-in fix layer: distinct named fixes
    # (with coords) drawn from every procedure leg, lat-indexed so a small in-view box query is fast (the
    # `leg` table itself is 190k+ rows with no spatial index). Named fixes only (RW.. thresholds excluded).
    con.execute("CREATE TABLE terminal_fix(fix TEXT, lat REAL, lon REAL)")
    # The exclusion must test the runway-threshold SHAPE (RW + two digits + optional L/C/R), not the
    # bare "RW" prefix: RWF is the Redwood Falls VOR, RWO is Kodiak, and RWLND is a published waypoint.
    # A prefix match deleted all three from the map's fix layer and from the corrector's vocabulary.
    con.execute("""INSERT INTO terminal_fix SELECT DISTINCT fix, lat, lon FROM leg
                   WHERE fix<>'' AND NOT (fix GLOB 'RW[0-9][0-9]*') AND lat IS NOT NULL AND lat<>0""")
    con.execute("CREATE INDEX ix_tfix_lat ON terminal_fix(lat)")
    ntfix = con.execute("SELECT COUNT(*) FROM terminal_fix").fetchone()[0]

    # ---- provenance + loud parse accounting ------------------------------------------------------
    # Every record travels with where it came from and which 28-day cycle it is valid for. Without this
    # nothing downstream can tell whether two datasets may legally be combined, or whether the data in
    # the pilot's hands has expired.
    eff, exp = cycle_dates(cycle)
    for k, v in [("source", "FAA CIFP (ARINC 424-18), public domain"),
                 ("source_url", BASE + f"CIFP_{args.date}.zip"),
                 ("cycle", cycle), ("effective", eff), ("expires", exp),
                 ("ingested_at", dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")),
                 ("builder", os.path.basename(__file__)),
                 ("records_rejected", str(nbad))]:
        con.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (k, v))

    # A procedure with ANY rejected record is marked incomplete rather than silently shipped short.
    if bad_keys:
        con.executemany("UPDATE procedure SET incomplete=1 WHERE airport=? AND kind=? AND ident=? AND transition=?",
                        [(a, {"D": "SID", "E": "STAR", "F": "IAP"}[sb], i, t) for (a, sb, i, t) in bad_keys])
    # ---- structural self-check against the source ------------------------------------------------
    # Row counts alone do not tell you whether a database is *flyable*. This build once shipped with the
    # final approach fix deleted from 6,741 of 10,243 approaches and reported a clean run, because the
    # only thing being counted was rows that survived. So count the FAA's own segment markers — the
    # ones that make a procedure flyable — and refuse to write a database that lost any of them.
    # Counting only the approach ROLE markers would have left 79% of legs — and every SID and STAR —
    # outside the check, so a build could still gut the whole departure/arrival half of the database and
    # report a clean run. Count the total, count each kind, and count the roles.
    src_roles = {"A": 0, "F": 0, "M": 0}                        # IAF / final approach fix / missed pt
    src_kind = {"SID": 0, "STAR": 0, "IAP": 0}
    kind_of = {"D": "SID", "E": "STAR", "F": "IAP"}
    for l in lines:
        if len(l) < 60 or l[4] != "P" or l[12] not in "DEF" or l[38] not in "01":
            continue
        src_kind[kind_of[l[12]]] += 1
        role = l[42] if len(l) > 42 else " "
        if role in src_roles:
            src_roles[role] += 1

    checks = []                                                 # (label, source count, db count)
    checks.append(("legs (all)", sum(src_kind.values()),
                   con.execute("SELECT COUNT(*) FROM leg").fetchone()[0]))
    for kind in sorted(src_kind):
        checks.append((f"legs {kind}", src_kind[kind],
                       con.execute("SELECT COUNT(*) FROM leg JOIN procedure ON leg.procedure_id="
                                   "procedure.id WHERE procedure.kind=?", (kind,)).fetchone()[0]))
    for role in sorted(src_roles):
        checks.append((f"role {role!r}", src_roles[role],
                       con.execute("SELECT COUNT(*) FROM leg WHERE substr(wp_desc,4,1)=?",
                                   (role,)).fetchone()[0]))
    lost = []
    for label, want, got in checks:
        print(f"  {label:<12} source={want:<7} database={got:<7}" +
              ("" if got == want else f"   *** {want - got} LOST ***"))
        if got != want:
            lost.append(f"{label}: {want - got} lost")
    if lost:                                                    # an explicit raise — `assert` is
        raise SystemExit("REFUSING TO WRITE: " + "; ".join(lost))   # stripped under `python -O`

    nincomplete = con.execute("SELECT COUNT(*) FROM procedure WHERE incomplete=1").fetchone()[0]
    nolegs = con.execute("SELECT COUNT(*) FROM procedure p WHERE NOT EXISTS"
                         "(SELECT 1 FROM leg WHERE procedure_id=p.id)").fetchone()[0]
    if nolegs:                          # a named, selectable procedure with no path is not shippable
        raise SystemExit(f"REFUSING TO WRITE: {nolegs} procedures have no legs")
    con.commit()

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    disk = sqlite3.connect(out)
    con.backup(disk)
    disk.execute("VACUUM")
    disk.close()
    print(f"fixes={len(fixes)} procedures={nproc} legs={nleg} airway_points={nawy} terminal_fixes={ntfix} bytes={os.path.getsize(out)} -> {out}")
    print(f"cycle={cycle} effective={eff} expires={exp}")
    print(f"rejected_records={nbad} incomplete_procedures={nincomplete} procedures_with_no_legs={nolegs}")
    # airway spot-check: V1 and J121 should both exist with ordered geo points
    for awy in ("V1", "J121"):
        pts = con.execute("SELECT COUNT(*) FROM airway WHERE ident=?", (awy,)).fetchone()[0]
        print(f"  airway {awy}: {pts} points")

    # sanity spot-check
    for apt in ("KBOS", "KJFK"):
        rows = con.execute("SELECT id,kind,ident,name,runway FROM procedure WHERE airport=? AND kind='IAP' ORDER BY ident", (apt,)).fetchall()
        print(f"\n{apt}: {len(rows)} approaches")
        for pid, kind, ident, name, rwy in rows[:4]:
            legs = con.execute("SELECT seq,fix,lat,lon,leg_type FROM leg WHERE procedure_id=? ORDER BY seq", (pid,)).fetchall()
            plotted = sum(1 for _, _, la, lo, _ in legs if la is not None)
            print(f"  {ident:7} {name:20} {len(legs)} legs ({plotted} geo): " +
                  " → ".join(f"{f}" for _, f, _, _, _ in legs[:6]))
        for apt_, rwy, ident, freq, crs, la, lo in con.execute("SELECT * FROM ils WHERE airport=? LIMIT 4", (apt,)).fetchall():
            print(f"  ILS {rwy:5} {ident:5} {freq} MHz  crs {crs}  @ {la},{lo}")


if __name__ == "__main__":
    main()
