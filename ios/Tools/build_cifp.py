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
import argparse, io, os, re, sqlite3, urllib.request, zipfile

BASE = "https://aeronav.faa.gov/Upload_313-d/cifp/"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
LATLON = re.compile(r"([NS])(\d{8})([EW])(\d{9})")   # DDMMSSss / DDDMMSSss, as it appears in every geo record

# Approach-ident first letter → readable approach type (common FAA/ARINC codings).
APPROACH_TYPE = {"I": "ILS", "X": "LOC", "L": "LOC", "B": "LOC BC", "R": "RNAV (RNP)", "H": "RNAV (GPS)",
                 "P": "GPS", "V": "VOR", "D": "VOR/DME", "N": "NDB", "Q": "NDB/DME", "S": "VOR",
                 "G": "IGS", "U": "SDF", "T": "TACAN"}


def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=600).read()


def coord(line):
    """First lat/lon in a record → (lat, lon) decimal degrees, or None."""
    m = LATLON.search(line)
    if not m:
        return None
    la = int(m[2][0:2]) + int(m[2][2:4]) / 60 + (int(m[2][4:6]) + int(m[2][6:8]) / 100) / 3600
    lo = int(m[4][0:3]) + int(m[4][3:5]) / 60 + (int(m[4][5:7]) + int(m[4][7:9]) / 100) / 3600
    return (round(-la if m[1] == "S" else la, 6), round(-lo if m[3] == "W" else lo, 6))


def approach_name(ident):
    """"H33LX" → ("RNAV (GPS) RWY 33L", "33L"); SID/STAR idents pass through."""
    t = APPROACH_TYPE.get(ident[0])
    if not t or len(ident) < 3 or not ident[1:3].isdigit():
        return ident, ""
    rwy = ident[1:3] + (ident[3] if len(ident) > 3 and ident[3] in "LCR" else "")
    return f"{t} RWY {rwy}", rwy


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
    print("records:", len(lines), flush=True)

    # ---- pass 1: fix-coordinate table (ident → coord) from every geo-bearing fix/navaid record ----
    fixes = {}   # ident → (lat, lon)   (procedures reference fixes by ident; first geo record wins)
    def add_fix(ident, c):
        if ident and c and ident not in fixes:
            fixes[ident] = c
    for l in lines:
        if len(l) < 40:
            continue
        sec, sub = l[4], (l[12] if len(l) > 12 else " ")
        if sec == "E" and l[5] == "A":                          # enroute waypoint
            add_fix(l[13:18].strip(), coord(l))
        elif sec == "P" and sub == "C":                         # terminal waypoint
            add_fix(l[13:18].strip(), coord(l))
        elif sec == "D":                                        # VHF navaid (VOR/DME/TACAN)
            add_fix(l[13:17].strip(), coord(l))
        elif sec == "P" and sub == "N":                         # terminal NDB
            add_fix(l[13:17].strip(), coord(l))
        elif sec == "P" and sub == "A":                         # airport reference point
            add_fix(l[6:10].strip(), coord(l))

    # ---- pass 2: procedures + legs (subsection D=SID, E=STAR, F=approach), runways (G), ILS (I) ----
    con = sqlite3.connect(args.out if False else ":memory:")
    con.executescript("""
      CREATE TABLE procedure(id INTEGER PRIMARY KEY, airport TEXT, kind TEXT, ident TEXT, name TEXT,
                             runway TEXT, transition TEXT);
      CREATE TABLE leg(procedure_id INTEGER, seq INTEGER, fix TEXT, lat REAL, lon REAL,
                       leg_type TEXT, course_mag REAL, alt TEXT);
      CREATE TABLE ils(airport TEXT, runway TEXT, ident TEXT, freq_mhz REAL, course_mag REAL, lat REAL, lon REAL);
      CREATE TABLE runway(airport TEXT, designator TEXT, lat REAL, lon REAL, bearing_mag REAL, length_ft INTEGER);
      CREATE INDEX ix_proc_apt ON procedure(airport);
      CREATE INDEX ix_leg_proc ON leg(procedure_id);
      CREATE INDEX ix_ils_apt ON ils(airport);
      CREATE INDEX ix_rwy_apt ON runway(airport);
    """)
    proc_id = {}   # (airport, sub, ident, transition) → rowid
    nproc = nleg = 0

    def num(s, scale=1.0):
        s = s.strip()
        return (int(s) / scale) if s.isdigit() else None

    for l in lines:
        if len(l) < 60 or l[4] != "P":
            continue
        sub = l[12]
        apt = l[6:10].strip()
        if sub in "DEF":                                        # SID / STAR / Approach leg
            ident = l[13:19].strip()
            trans = l[20:25].strip()
            seq = num(l[26:29])
            fix = l[29:34].strip()
            leg_type = l[47:49].strip()
            course = num(l[70:74], 10.0)                        # tenths of a degree
            alt = l[84:89].strip()
            key = (apt, sub, ident, trans)
            if key not in proc_id:
                kind = {"D": "SID", "E": "STAR", "F": "IAP"}[sub]
                name, rwy = (approach_name(ident) if sub == "F" else (ident, ""))
                cur = con.execute("INSERT INTO procedure(airport,kind,ident,name,runway,transition) VALUES(?,?,?,?,?,?)",
                                  (apt, kind, ident, name, rwy, trans))
                proc_id[key] = cur.lastrowid
                nproc += 1
            if fix:
                c = fixes.get(fix)
                con.execute("INSERT INTO leg(procedure_id,seq,fix,lat,lon,leg_type,course_mag,alt) VALUES(?,?,?,?,?,?,?,?)",
                            (proc_id[key], seq, fix, c[0] if c else None, c[1] if c else None, leg_type, course, alt))
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

    con.commit()

    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    disk = sqlite3.connect(out)
    con.backup(disk)
    disk.execute("VACUUM")
    disk.close()
    print(f"fixes={len(fixes)} procedures={nproc} legs={nleg} bytes={os.path.getsize(out)} -> {out}")

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
