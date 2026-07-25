#!/usr/bin/env python3
"""Inspect the bundled navigation databases — the tool that should have existed before the CIFP rebuild.

Every subcommand here replaces something that was done by hand, with a throwaway script, during the
cycle-2607 work. Three of those scripts re-implemented the missed-approach split slightly differently,
which is precisely the situation an inspection tool exists to prevent: one decoder, used by everyone.

    navdb.py show KBOS --proc H33LX [--transition BBOGG] [--json]
    navdb.py airport KBOS
    navdb.py verify [--source /path/FAACIFP18]
    navdb.py diff old.sqlite new.sqlite

Read-only. Never writes to a database.
"""
import argparse, collections, json, os, sqlite3, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DB = os.path.join(HERE, "..", "ATCTranscribe", "Resources", "nav", "cifp.sqlite")
PROCEDURES_JSON = os.path.join(HERE, "..", "ATCTranscribe", "Resources", "nav", "procedures.json")

# The waypoint-description role letters, expanded. I and B are the pair that are easy to transpose:
# I opens the approach-proper row (the final approach COURSE fix), B ends a transition (the intermediate
# fix). Getting them backwards is a documented hazard in Core/CIFP.swift — keep this table in step.
ROLE = {"A": "IAF", "F": "FAF", "I": "FACF", "B": "IF", "M": "MAP", "D": "IAF/FACF"}

# ARINC altitude-description qualifier. Anything outside this set is UNMODELLED and must render as such
# rather than being guessed at — the same rule Core/LegConstraint.swift enforces at runtime.
ALT_DESC = {"": "at", "+": "at or above", "-": "at or below", "B": "between"}


def connect(path):
    if not os.path.exists(path):
        sys.exit(f"no database at {path}")
    return sqlite3.connect(f"file:{os.path.abspath(path)}?mode=ro", uri=True)


def meta(con):
    try:
        return dict(con.execute("SELECT key, value FROM meta"))
    except sqlite3.Error:
        return {}


def cycle_line(con):
    m = meta(con)
    if not m:
        return "cycle: UNKNOWN (no meta table — this database predates provenance)"
    return (f"cycle {m.get('cycle', '?')}  effective {m.get('effective', '?')}  "
            f"expires {m.get('expires', '?')}  · {m.get('source', '?')}")


def feet(alt_desc, alt, alt2):
    """Render a leg's altitude constraint the way the chart states it, or flag it unmodelled."""
    alt, alt2 = (alt or "").strip(), (alt2 or "").strip()
    if not alt:
        return ""
    d = (alt_desc or "").strip().upper()
    if d not in ALT_DESC:
        return f"[unmodelled qualifier {d!r}: {alt}/{alt2}]"
    if d == "B":
        if not alt2:
            return f"[between, but only one altitude published: {alt}]"
        lo, hi = sorted((alt, alt2))
        return f"between {lo} and {hi}"
    return f"{ALT_DESC[d]} {alt}"


def split_missed(legs):
    """(approach, missed) indices, split at the PUBLISHED missed-approach point.

    The single authoritative decoder — Core/ApproachActivation.swift's twin. Falls back to the runway
    threshold only for a record that carries no M marker.
    """
    for i, l in enumerate(legs):
        if (l["wp_desc"] or "    ")[3:4] == "M":
            return list(range(i + 1)), list(range(i + 1, len(legs)))
    last_rw = None
    for i, l in enumerate(legs):
        f = (l["fix"] or "").upper()
        if len(f) in (4, 5) and f.startswith("RW") and f[2:4].isdigit():
            last_rw = i
    if last_rw is not None and last_rw + 1 < len(legs):
        return list(range(last_rw + 1)), list(range(last_rw + 1, len(legs)))
    return list(range(len(legs))), []


def legs_of(con, proc_id):
    cols = "seq,fix,lat,lon,leg_type,course_mag,alt,COALESCE(wp_desc,''),COALESCE(alt_desc,'')," \
           "COALESCE(alt2,''),speed_limit,vertical_angle,rnp,recd_navaid,turn"
    out = []
    for r in con.execute(f"SELECT {cols} FROM leg WHERE procedure_id=? ORDER BY seq", (proc_id,)):
        out.append(dict(zip(["seq", "fix", "lat", "lon", "leg_type", "course", "alt", "wp_desc",
                             "alt_desc", "alt2", "speed", "vangle", "rnp", "recd", "turn"], r)))
    return out


def cmd_show(args):
    con = connect(args.db)
    print(cycle_line(con))
    rows = list(con.execute(
        "SELECT id, kind, ident, name, runway, transition, COALESCE(route_type,''), COALESCE(incomplete,0) "
        "FROM procedure WHERE airport=? AND ident=? ORDER BY transition", (args.airport.upper(), args.proc.upper())))
    if not rows:
        sys.exit(f"no procedure {args.proc} at {args.airport}")
    if args.transition is not None:
        rows = [r for r in rows if r[5].upper() == args.transition.upper()]
        if not rows:
            sys.exit(f"no transition {args.transition!r} on {args.proc}")

    payload = []
    for pid, kind, ident, name, runway, trans, rtype, incomplete in rows:
        legs = legs_of(con, pid)
        approach_idx, missed_idx = split_missed(legs) if kind == "IAP" and not trans else (list(range(len(legs))), [])
        missed = set(missed_idx)
        label = f"{ident}  {name}" + (f"  · transition {trans}" if trans else "  · approach proper")
        print(f"\n{label}   [{kind}{'/' + rtype if rtype else ''}"
              + (", INCOMPLETE" if incomplete else "") + f", runway {runway or '—'}]")
        print(f"  {'seq':>4}  {'fix':<6} {'pt':<3} {'role':<5} {'course':>6}  {'constraint'}")
        for i, l in enumerate(legs):
            role = ROLE.get((l["wp_desc"] or "    ")[3:4], "")
            bits = [feet(l["alt_desc"], l["alt"], l["alt2"])]
            if l["speed"]:
                bits.append(f"max {int(l['speed'])} kt")
            if l["vangle"]:
                bits.append(f"{l['vangle']:.2f}° glidepath")
            if l["rnp"]:
                bits.append(f"RNP {l['rnp']}")
            if l["recd"]:
                bits.append(f"ref {l['recd']}")
            geo = "" if l["lat"] is not None else "  (no coordinate)"
            mark = " <<< MISSED APPROACH BEGINS" if i and i == min(missed_idx or [-1]) else ""
            print(f"  {int(l['seq']):>4}  {l['fix'] or '—':<6} {l['leg_type']:<3} {role:<5} "
                  f"{(f'{l['course']:.0f}°' if l['course'] is not None else '—'):>6}  "
                  f"{' · '.join(b for b in bits if b)}{geo}{mark}")
        if kind == "IAP" and not trans:
            print(f"  → flown to the runway: {len(approach_idx)} legs · missed approach: {len(missed)} legs")
        payload.append({"ident": ident, "name": name, "transition": trans, "legs": legs,
                        "missed_seqs": [legs[i]["seq"] for i in missed_idx]})
    if args.json:
        print(json.dumps(payload, indent=2, default=str))


def cmd_airport(args):
    apt = args.airport.upper()
    con = connect(args.db)
    print(f"=== {apt}")
    print(f"  coded procedures  [{cycle_line(con)}]")
    for kind in ("IAP", "SID", "STAR"):
        rows = sorted({(i, n) for i, n in con.execute(
            "SELECT ident, name FROM procedure WHERE airport=? AND kind=?", (apt, kind))})
        if rows:
            print(f"    {kind}: " + ", ".join(f"{i} ({n})" for i, n in rows))
    rwy = list(con.execute("SELECT designator, bearing_mag, length_ft FROM runway WHERE airport=? ORDER BY designator", (apt,)))
    if rwy:
        print("  runways [CIFP]: " + ", ".join(
            f"{d} {int(b) if b else '?'}° {int(l) if l else '?'}ft" for d, b, l in rwy))
    ils = list(con.execute("SELECT runway, ident, freq_mhz, course_mag FROM ils WHERE airport=? ORDER BY runway", (apt,)))
    if ils:
        print("  ILS [CIFP]:     " + ", ".join(f"{r} {i} {f}MHz {c}°" for r, i, f, c in ils))

    if os.path.exists(PROCEDURES_JSON):
        d = json.load(open(PROCEDURES_JSON))
        plates = [p["n"] for p in d["airports"].get(apt, []) if p["c"] == "IAP"]
        print(f"  plates [d-TPP {d.get('cycle', '?')}, eff {d.get('from', '?')}]: {len(plates)}")
        for n in sorted(plates):
            print(f"    {n}")
        # Cross-dataset disagreement is the concrete form of "stamp and surface, never hard-fail".
        coded = {n for (n,) in con.execute("SELECT DISTINCT name FROM procedure WHERE airport=? AND kind='IAP'", (apt,))}
        only_plate = [p for p in plates if not any(c.split(" RWY")[0] in p for c in coded)]
        if only_plate:
            print("  ⚠ published but NOT coded (no legs to fly): " + "; ".join(sorted(only_plate)))


def cmd_verify(args):
    con = connect(args.db)
    print(cycle_line(con))
    bad = 0

    if args.source:
        roles = {"A": 0, "F": 0, "M": 0}
        kinds = {"SID": 0, "STAR": 0, "IAP": 0}
        kind_of = {"D": "SID", "E": "STAR", "F": "IAP"}
        for l in open(args.source, encoding="latin-1"):
            if len(l) < 60 or l[4] != "P" or l[12] not in "DEF" or l[38] not in "01":
                continue
            kinds[kind_of[l[12]]] += 1
            r = l[42] if len(l) > 42 else " "
            if r in roles:
                roles[r] += 1
        checks = [("legs (all)", sum(kinds.values()), con.execute("SELECT COUNT(*) FROM leg").fetchone()[0])]
        for k in sorted(kinds):
            checks.append((f"legs {k}", kinds[k], con.execute(
                "SELECT COUNT(*) FROM leg JOIN procedure ON leg.procedure_id=procedure.id "
                "WHERE procedure.kind=?", (k,)).fetchone()[0]))
        for r in sorted(roles):
            checks.append((f"role {r!r}", roles[r], con.execute(
                "SELECT COUNT(*) FROM leg WHERE substr(wp_desc,4,1)=?", (r,)).fetchone()[0]))
        for label, want, got in checks:
            ok = want == got
            bad += 0 if ok else 1
            print(f"  {label:<12} source={want:<7} db={got:<7} {'ok' if ok else f'*** {want - got} LOST ***'}")

    # Corpus invariants — true of the FAA's own data, so true after any correct ingest.
    n_iap = con.execute("SELECT COUNT(*) FROM procedure WHERE kind='IAP' AND transition=''").fetchone()[0]
    for label, sql, want in [
        ("approach-proper rows with exactly one MAP",
         "SELECT COUNT(*) FROM (SELECT p.id FROM procedure p JOIN leg l ON l.procedure_id=p.id "
         "WHERE p.kind='IAP' AND p.transition='' AND substr(l.wp_desc,4,1)='M' "
         "GROUP BY p.id HAVING COUNT(*)=1)", n_iap),
        ("approach-proper rows with exactly one FAF",
         "SELECT COUNT(*) FROM (SELECT p.id FROM procedure p JOIN leg l ON l.procedure_id=p.id "
         "WHERE p.kind='IAP' AND p.transition='' AND substr(l.wp_desc,4,1)='F' "
         "GROUP BY p.id HAVING COUNT(*)=1)", n_iap),
        ("procedures with no legs", "SELECT COUNT(*) FROM procedure p WHERE NOT EXISTS"
         "(SELECT 1 FROM leg WHERE procedure_id=p.id)", 0),
        ("duplicate (procedure, seq)", "SELECT COUNT(*) FROM (SELECT procedure_id, seq FROM leg "
         "GROUP BY 1,2 HAVING COUNT(*)>1)", 0),
        ("runway pseudo-fixes leaking into terminal_fix",
         "SELECT COUNT(*) FROM terminal_fix WHERE fix GLOB 'RW[0-9][0-9]*'", 0),
        ("IAP names colliding at one airport",
         "SELECT COUNT(*) FROM (SELECT airport, name FROM (SELECT DISTINCT airport, ident, name FROM "
         "procedure WHERE kind='IAP') GROUP BY airport, name HAVING COUNT(*)>1)", 0),
    ]:
        got = con.execute(sql).fetchone()[0]
        ok = got == want
        bad += 0 if ok else 1
        print(f"  {label:<48} {got:>7}  (want {want}) {'ok' if ok else '*** FAIL ***'}")

    print("\nOK" if not bad else f"\n{bad} check(s) FAILED")
    return 1 if bad else 0


def cmd_diff(args):
    a, b = connect(args.old), connect(args.new)
    print(f"old: {cycle_line(a)}\nnew: {cycle_line(b)}\n")
    for table in ("procedure", "leg", "terminal_fix", "runway", "ils", "airway"):
        try:
            na = a.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            nb = b.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        except sqlite3.Error:
            continue
        d = nb - na
        print(f"  {table:<14} {na:>8} → {nb:>8}   {d:+d}" + ("" if d == 0 else "  <<<"))

    key = "SELECT DISTINCT airport, kind, ident FROM procedure"
    pa, pb = set(a.execute(key)), set(b.execute(key))
    gone, new = sorted(pa - pb), sorted(pb - pa)
    print(f"\n  procedures removed: {len(gone)}   added: {len(new)}")
    for r in gone[:args.limit]:
        print(f"    - {r[0]} {r[2]} ({r[1]})")
    for r in new[:args.limit]:
        print(f"    + {r[0]} {r[2]} ({r[1]})")

    # A renamed procedure is the shape a mislabelled approach type takes — worth calling out by itself.
    na_ = dict(((r[0], r[2]), r[3]) for r in a.execute("SELECT airport, kind, ident, name FROM procedure"))
    nb_ = dict(((r[0], r[2]), r[3]) for r in b.execute("SELECT airport, kind, ident, name FROM procedure"))
    renamed = [(k, na_[k], nb_[k]) for k in na_.keys() & nb_.keys() if na_[k] != nb_[k]]
    print(f"  procedures RENAMED: {len(renamed)}")
    for (apt, ident), old, newn in sorted(renamed)[:args.limit]:
        print(f"    ~ {apt} {ident}: {old!r} → {newn!r}")

    roles = collections.Counter()
    for db, tag in ((a, "old"), (b, "new")):
        for r in ("A", "F", "M", "I", "B"):
            roles[(tag, r)] = db.execute(
                "SELECT COUNT(*) FROM leg WHERE substr(wp_desc,4,1)=?", (r,)).fetchone()[0]
    print("\n  role markers:")
    for r in ("A", "F", "I", "B", "M"):
        d = roles[("new", r)] - roles[("old", r)]
        print(f"    {r}  {roles[('old', r)]:>7} → {roles[('new', r)]:>7}   {d:+d}" + ("" if d == 0 else "  <<<"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default=DEFAULT_DB, help="cifp.sqlite (default: the bundled one)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("show", help="decode one procedure, legs and all")
    s.add_argument("airport"); s.add_argument("--proc", required=True)
    s.add_argument("--transition"); s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_show)

    s = sub.add_parser("airport", help="everything the app knows about one airport, tagged by dataset")
    s.add_argument("airport"); s.set_defaults(fn=cmd_airport)

    s = sub.add_parser("verify", help="source-vs-database counts + corpus invariants, without rebuilding")
    s.add_argument("--source", help="raw FAACIFP18 to check the database against")
    s.set_defaults(fn=cmd_verify)

    s = sub.add_parser("diff", help="what changed between two builds")
    s.add_argument("old"); s.add_argument("new")
    s.add_argument("--limit", type=int, default=15)
    s.set_defaults(fn=cmd_diff)

    args = ap.parse_args()
    sys.exit(args.fn(args) or 0)


if __name__ == "__main__":
    main()
