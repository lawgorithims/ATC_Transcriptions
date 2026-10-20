#!/usr/bin/env python3
"""check_cycles.py — is there a newer aeronautical cycle upstream than the one we ship?

Answers that question CHEAPLY, every day, so a cycle roll is never discovered by a pilot. It
downloads nothing but a few KB: a ranged GET of the first two bytes tells you whether the FAA has
posted a cycle, and the d-TPP metafile's opening tag carries its cycle in the first 400 bytes.

This exists because of a measured failure, not a hypothetical one. On 2026-10-19 the shipped app
carried d-TPP cycle 2607 (expired 2026-08-06) and built every plate URL from it, so
`aeronav.faa.gov/d-tpp/2607/<pdf>` returned 404 for every approach plate in the app — for 74 days,
silently, because nothing was watching. The same day, CIFP was three cycles behind and the chart
cycle was ten days from expiry with its replacement already downloadable.

DELIBERATELY DETECTION ONLY. It builds nothing and publishes nothing. The chart rebuild is ~4 hours
and ~17 GB of intermediates, which is a poor fit for a scheduled runner and a worse one for a job
whose output nobody inspects. Knowing a cycle landed is the part that was missing; building is a
decision a human should still take.

Exit codes:  0 = nothing new    10 = something new (the workflow opens an issue)    1 = probe error

    python3 .github/scripts/check_cycles.py            # human-readable
    python3 .github/scripts/check_cycles.py --json     # for the workflow
"""
import argparse, datetime, json, re, sys, urllib.error, urllib.request

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
TIMEOUT = 30

# A known-good FAA 56-day chart cycle, to generate the chain from. Any real effective date works.
CHART_ANCHOR = datetime.date(2026, 5, 14)
CHART_PROBE = "https://aeronav.faa.gov/visual/{cycle}/sectional-files/Albuquerque.zip"
CIFP_PROBE = "https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_{yymmdd}.zip"
DTPP_METAFILE = "https://nfdc.faa.gov/webContent/dtpp/current.xml"


def _exists(url):
    """Two bytes is enough to learn whether a multi-hundred-MB zip has been posted."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": "bytes=0-1"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status in (200, 206)
    except urllib.error.HTTPError as ex:
        if ex.code == 404:
            return False
        raise
    except Exception:
        raise


def chart_cycles(today, ahead=2):
    """The 56-day chain around today: (current_effective, [future effective dates])."""
    d = CHART_ANCHOR
    while d + datetime.timedelta(days=56) <= today:
        d += datetime.timedelta(days=56)
    return d, [d + datetime.timedelta(days=56 * (i + 1)) for i in range(ahead)]


def check_charts(today):
    """Has the FAA posted a chart cycle beyond the one in force?

    The FAA posts roughly one cycle ahead, so this normally finds the NEXT cycle available well
    before it takes effect — which is the useful warning, not an alarm.
    """
    current, future = chart_cycles(today)
    out = {"source": "FAA raster charts", "current": current.strftime("%m-%d-%Y"),
           "expires": (current + datetime.timedelta(days=56)).isoformat(), "available": []}
    for f in future:
        c = f.strftime("%m-%d-%Y")
        if _exists(CHART_PROBE.format(cycle=c)):
            out["available"].append({"cycle": c, "effective": f.isoformat()})
    days_left = (current + datetime.timedelta(days=56) - today).days
    out["days_until_expiry"] = days_left
    out["new"] = bool(out["available"])
    return out


def check_cifp(today, shipped=None):
    """CIFP is a 28-day cycle named by its effective date: CIFP_<YYMMDD>.zip."""
    d = CHART_ANCHOR
    while d + datetime.timedelta(days=28) <= today:
        d += datetime.timedelta(days=28)
    cands = [d, d + datetime.timedelta(days=28)]
    out = {"source": "FAA CIFP", "shipped": shipped, "available": []}
    # Identified by EFFECTIVE DATE and by the YYMMDD the URL uses — never by a cycle label computed
    # here. AIRAC cycles are numbered sequentially within the year (1..13), which `%y%m` only
    # coincidentally matches: it gives "2610" for BOTH 2026-10-01 and 2026-10-29, because two 28-day
    # cycles fall in October. The database stamps its own `cycle` at build time; a probe that cannot
    # read the file should not guess what it will say.
    for c in cands:
        if _exists(CIFP_PROBE.format(yymmdd=c.strftime("%y%m%d"))):
            out["available"].append({"file": f"CIFP_{c.strftime('%y%m%d')}.zip",
                                     "effective": c.isoformat(), "in_force": c <= today})
    in_force = [a for a in out["available"] if a["in_force"]]
    out["current"] = in_force[-1]["effective"] if in_force else None
    out["new"] = bool(shipped and out["current"] and out["current"] > shipped)
    return out


def check_dtpp(today, shipped=None):
    """The d-TPP metafile names its own cycle and validity in the opening tag."""
    req = urllib.request.Request(DTPP_METAFILE, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        head = r.read(400).decode("utf-8", "replace")
    m = re.search(r'cycle="(\d+)"\s+from_edate="([^"]+)"\s+to_edate="([^"]+)"', head)
    if not m:
        raise RuntimeError("d-TPP metafile did not carry a cycle in its opening tag")
    cycle, frm, to = m.group(1), m.group(2), m.group(3)

    def _d(s):                                  # "0901Z  10/01/26" -> date
        mm, dd, yy = re.search(r"(\d\d)/(\d\d)/(\d\d)", s).groups()
        return datetime.date(2000 + int(yy), int(mm), int(dd))

    out = {"source": "FAA d-TPP (plates)", "shipped": shipped, "current": cycle,
           "effective": _d(frm).isoformat(), "expires": _d(to).isoformat()}
    out["new"] = bool(shipped and cycle != shipped)
    out["days_until_expiry"] = (_d(to) - today).days
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--shipped-cifp", help="effective date of the cifp.sqlite we ship, YYYY-MM-DD")
    ap.add_argument("--shipped-dtpp", help="cycle of the procedures.json we ship, e.g. 2610")
    a = ap.parse_args()

    today = datetime.date.today()
    report, failed = {"checked": today.isoformat(), "sources": []}, False
    for fn, kw in ((check_charts, {}),
                   (check_cifp, {"shipped": a.shipped_cifp}),
                   (check_dtpp, {"shipped": a.shipped_dtpp})):
        try:
            report["sources"].append(fn(today, **kw))
        except Exception as ex:
            # A probe that cannot reach its source must not read as "nothing new" — that is the
            # same silence this script exists to break, one level up. HIFLD taught this project the
            # distinction: unchanged-because-stable is not unchanged-because-dead.
            failed = True
            report["sources"].append({"source": fn.__name__, "error": f"{type(ex).__name__}: {ex}"})

    report["new"] = any(s.get("new") for s in report["sources"])
    report["error"] = failed

    if a.json:
        print(json.dumps(report, indent=2))
    else:
        for s in report["sources"]:
            if "error" in s:
                print(f"  !! {s['source']}: {s['error']}")
                continue
            tag = "NEW" if s.get("new") else "  –"
            extra = ""
            if s.get("days_until_expiry") is not None:
                extra = f"  (expires in {s['days_until_expiry']}d)"
            print(f"  {tag} {s['source']}: current {s.get('current')}{extra}")
            for av in s.get("available", []):
                label = av.get("cycle") or av.get("file")
                force = "" if av.get("in_force", True) else "  [not in force yet]"
                print(f"        available upstream: {label} effective {av['effective']}{force}")

    if failed:
        sys.exit(1)
    sys.exit(10 if report["new"] else 0)


if __name__ == "__main__":
    main()
