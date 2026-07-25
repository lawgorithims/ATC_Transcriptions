#!/usr/bin/env python3
"""Build `apt.sqlite` — airports, runway geometry and frequencies — from the FAA NASR subscription.

This is the AIRPORT half of the terminal-data layer, and the only half NASR still adds. The fix,
airway and airspace parts are already ingested elsewhere: `build_nav_db.py` reads NASR's own FIX.txt
(70k points) and `build_airspace_db.py` reads its Class_Airspace shapefile, while airways with MEA/MAA
come from CIFP. What is genuinely missing is everything about the FIELD:

  * RUNWAY GEOMETRY. CIFP codes only airports with published instrument procedures — 9,942 of the
    14,078 airports the app knows have no runway geometry at all. NASR covers 19,436 facilities with
    both runway ends, width, surface, displaced thresholds, TDZE, declared distances and lighting.
  * FREQUENCIES. OurAirports gives KDFW seven; NASR carries 211 for DFW alone, each tagged by use and
    sectorization. This is not cosmetic — SlotSnap verifies a heard frequency against the published
    list and ABSTAINS when it is absent, so every missing frequency is a silently lost ATC verification.

Source: the 28-day subscription zip, member `extra/<DD_Mon_YYYY>_CSV.zip`, itself holding APT_BASE.csv,
APT_RWY.csv, APT_RWY_END.csv, FRQ.csv and ATC_BASE.csv.

    python3 build_apt.py [--zip 28DaySubscription.zip | --csv-zip CSV.zip] [--out path.sqlite]

Follows build_cifp.py's contract: the effective date is read from the DATA, absent stays NULL, and the
build REFUSES to write if a table regresses against the CSV row count it came from.
"""
import argparse, csv, datetime as dt, io, os, sqlite3, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "ATCTranscribe", "Resources", "nav", "apt.sqlite")
MEMBERS = ("APT_BASE.csv", "APT_RWY.csv", "APT_RWY_END.csv", "FRQ.csv", "ATC_BASE.csv")


def num(s, cast=float):
    """Absent stays absent. NASR leaves a field blank rather than zero when it has no value, and a
    zero here would read as a real measurement — a 0 ft TDZE is sea level, not 'unknown'."""
    s = (s or "").strip()
    if not s:
        return None
    try:
        return cast(s)
    except ValueError:
        return None


def latlon(row, base):
    """NASR CSVs carry decimal degrees alongside the DMS strings; prefer the decimal."""
    lat, lon = num(row.get(base + "_DECIMAL")), num(row.get(base.replace("LAT", "LONG") + "_DECIMAL"))
    return (lat, lon) if lat is not None and lon is not None else (None, None)


def open_csv_zip(args):
    """The CSV bundle, either given directly or extracted from the full subscription zip."""
    if args.csv_zip:
        return zipfile.ZipFile(args.csv_zip)
    if not args.zip:
        sys.exit("give --zip (the 28-day subscription) or --csv-zip")
    outer = zipfile.ZipFile(args.zip)
    inner = [n for n in outer.namelist() if n.upper().endswith("_CSV.ZIP")]
    if not inner:
        sys.exit("no <date>_CSV.zip inside the subscription — is this the right archive?")
    inner.sort()
    print(f"  CSV bundle: {inner[-1]}")
    return zipfile.ZipFile(io.BytesIO(outer.read(inner[-1])))


def rows(zf, member):
    """Every row of one CSV member, as dicts. NASR ships them UTF-8 with a BOM."""
    names = {n.split("/")[-1].upper(): n for n in zf.namelist()}
    if member.upper() not in names:
        sys.exit(f"{member} missing from the CSV bundle")
    with zf.open(names[member.upper()]) as fh:
        for r in csv.DictReader(io.TextIOWrapper(fh, encoding="utf-8-sig")):
            yield r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip"); ap.add_argument("--csv-zip")
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    print("reading NASR CSV bundle…", flush=True)
    zf = open_csv_zip(args)

    con = sqlite3.connect(":memory:")
    con.executescript("""
      CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE airport(
        ident TEXT, icao TEXT, name TEXT, city TEXT, state TEXT,
        lat REAL, lon REAL, elev_ft REAL, mag_var TEXT, artcc TEXT,
        ownership TEXT, use TEXT, status TEXT, tower TEXT, beacon TEXT,
        fuel TEXT, tpa_ft REAL, sectional TEXT);
      CREATE TABLE runway(
        ident TEXT, designator TEXT, length_ft REAL, width_ft REAL,
        surface TEXT, condition TEXT, lights TEXT);
      CREATE TABLE runway_end(
        ident TEXT, designator TEXT, end_id TEXT, true_align REAL,
        lat REAL, lon REAL, elev_ft REAL, tdze_ft REAL,
        displaced_ft REAL, tora_ft REAL, toda_ft REAL, asda_ft REAL, lda_ft REAL,
        vgsi TEXT, app_lights TEXT);
      CREATE TABLE frequency(
        ident TEXT, freq TEXT, use TEXT, sectorization TEXT, facility TEXT);
      CREATE INDEX ix_apt_ident ON airport(ident);
      CREATE INDEX ix_rwy_ident ON runway(ident);
      CREATE INDEX ix_rwyend_ident ON runway_end(ident);
      CREATE INDEX ix_frq_ident ON frequency(ident);
    """)

    eff = ""
    counts = {}

    # ---- airports -------------------------------------------------------------------------------
    n = 0
    for r in rows(zf, "APT_BASE.csv"):
        eff = eff or (r.get("EFF_DATE") or "").strip()      # from the DATA, never the filename
        lat, lon = latlon(r, "LAT")
        con.execute("INSERT INTO airport VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            (r.get("ARPT_ID") or "").strip(), (r.get("ICAO_ID") or "").strip(),
            (r.get("ARPT_NAME") or "").strip(), (r.get("CITY") or "").strip(),
            (r.get("STATE_CODE") or "").strip(), lat, lon, num(r.get("ELEV")),
            (r.get("MAG_VARN") or "").strip(), (r.get("RESP_ARTCC_ID") or "").strip(),
            (r.get("OWNERSHIP_TYPE_CODE") or "").strip(), (r.get("FACILITY_USE_CODE") or "").strip(),
            (r.get("ARPT_STATUS") or "").strip(), (r.get("TWR_TYPE_CODE") or "").strip(),
            (r.get("BCN_LENS_COLOR") or "").strip(), (r.get("FUEL_TYPES") or "").strip(),
            num(r.get("TPA")), (r.get("CHART_NAME") or "").strip()))
        n += 1
    counts["airport"] = n

    # ---- runways --------------------------------------------------------------------------------
    n = 0
    for r in rows(zf, "APT_RWY.csv"):
        con.execute("INSERT INTO runway VALUES(?,?,?,?,?,?,?)", (
            (r.get("ARPT_ID") or "").strip(), (r.get("RWY_ID") or "").strip(),
            num(r.get("RWY_LEN")), num(r.get("RWY_WIDTH")),
            (r.get("SURFACE_TYPE_CODE") or "").strip(), (r.get("COND") or "").strip(),
            (r.get("RWY_LGT_CODE") or "").strip()))
        n += 1
    counts["runway"] = n

    # ---- runway ends ----------------------------------------------------------------------------
    n = 0
    for r in rows(zf, "APT_RWY_END.csv"):
        lat, lon = latlon(r, "LAT")
        con.execute("INSERT INTO runway_end VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (
            (r.get("ARPT_ID") or "").strip(), (r.get("RWY_ID") or "").strip(),
            (r.get("RWY_END_ID") or "").strip(), num(r.get("TRUE_ALIGNMENT")),
            lat, lon, num(r.get("RWY_END_ELEV")), num(r.get("TDZ_ELEV")),
            num(r.get("DISPLACED_THR_LEN")), num(r.get("TKOF_RUN_AVBL")),
            num(r.get("TKOF_DIST_AVBL")), num(r.get("ACLT_STOP_DIST_AVBL")),
            num(r.get("LNDG_DIST_AVBL")), (r.get("VGSI_CODE") or "").strip(),
            (r.get("APCH_LGT_SYSTEM_CODE") or "").strip()))
        n += 1
    counts["runway_end"] = n

    # ---- frequencies ----------------------------------------------------------------------------
    # The reason this table matters is SlotSnap: it verifies a frequency it heard against the airport's
    # published list and abstains when the frequency is absent, so a thin list silently loses
    # verifications rather than producing wrong ones.
    n = 0
    for r in rows(zf, "FRQ.csv"):
        # SERVICED_FACILITY is the airport the frequency serves; FACILITY is the ATC
        # facility providing it (an approach control can serve many fields).
        ident = (r.get("SERVICED_FACILITY") or "").strip()
        freq = (r.get("FREQ") or "").strip()
        if not ident or not freq:
            continue
        con.execute("INSERT INTO frequency VALUES(?,?,?,?,?)", (
            ident, freq, (r.get("FREQ_USE") or "").strip(),
            (r.get("SECTORIZATION") or "").strip(),
            (r.get("FACILITY_TYPE") or "").strip()))
        n += 1
    counts["frequency"] = n

    # ---- provenance -----------------------------------------------------------------------------
    eff_iso = ""
    for fmt in ("%Y/%m/%d", "%m/%d/%Y", "%Y-%m-%d", "%d-%b-%Y"):
        try:
            eff_iso = dt.datetime.strptime(eff, fmt).date().isoformat(); break
        except (ValueError, TypeError):
            continue
    if not eff_iso:
        sys.exit(f"could not read an effective date from the data (saw {eff!r}) — refusing to ship undated")
    exp_iso = (dt.date.fromisoformat(eff_iso) + dt.timedelta(days=28)).isoformat()
    for k, v in [("source", "FAA NASR 28-day subscription"),
                 ("cycle", eff_iso), ("effective", eff_iso), ("expires", exp_iso),
                 ("ingested_at", dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")),
                 ("builder", os.path.basename(__file__))]:
        con.execute("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)", (k, v))

    # ---- self-check -----------------------------------------------------------------------------
    # Same contract as build_cifp.py: refuse to write rather than ship a table that silently lost rows.
    lost = []
    for table, want in counts.items():
        got = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"  {table:<12} csv={want:<8} database={got:<8}" + ("" if got == want else "  *** LOST ***"))
        if got != want:
            lost.append(f"{table}: {want - got} lost")
    if not counts.get("airport") or not counts.get("runway_end"):
        lost.append("a required table is empty")
    if lost:
        raise SystemExit("REFUSING TO WRITE: " + "; ".join(lost))

    con.commit()
    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    disk = sqlite3.connect(out)
    con.backup(disk)
    disk.execute("VACUUM")
    disk.close()
    print(f"cycle={eff_iso} expires={exp_iso} bytes={os.path.getsize(out)} -> {out}")

    for apt in ("KDFW", "KBOS", "KJFK", "KEGE"):
        a = con.execute("SELECT name, elev_ft, sectional FROM airport WHERE ident=? OR icao=?",
                        (apt.lstrip("K"), apt)).fetchone()
        nr = con.execute("SELECT COUNT(*) FROM runway_end WHERE ident=? OR ident=?",
                         (apt.lstrip("K"), apt)).fetchone()[0]
        nf = con.execute("SELECT COUNT(*) FROM frequency WHERE ident=? OR ident=?",
                         (apt.lstrip("K"), apt)).fetchone()[0]
        print(f"  {apt}: {a[0] if a else '(absent)'} · {nr} runway ends · {nf} frequencies")


if __name__ == "__main__":
    main()
