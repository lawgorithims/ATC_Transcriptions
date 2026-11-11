#!/usr/bin/env python3
"""Watch the PUBLISHED nav cycle and shout before it goes stale.

WHY THIS EXISTS. On 2026-11-11 the live channel was serving cycle 2610, which had expired on
2026-10-29 — thirteen days earlier. Cycle 2611 had been BUILT on 2026-10-20 and was sitting in
`~/CommSight/navbuild/2611` the whole time. Nothing was broken; nobody was told. The same thing had
already happened once before, and `publish_nav.py`'s own header records it: measured 2026-10-19,
both databases were cycle 2607, which had expired on 2026-08-06.

A dropped cycle is silent by construction. The app falls back to its bundled floor, so a fresh
install looks fine, and the only pilots who see anything are the ones who took an over-the-air
update and are now carrying expired procedures. That is the failure this guards.

WHAT IT CHECKS, in the order that matters:
  1. Has the published cycle EXPIRED?            -> exit 1. Pilots are on stale data now.
  2. Does it expire within `--warn-days`?        -> exit 2. There is still time to build and stage.
  3. Has the FAA posted the NEXT cycle's CIFP?   -> reported either way; it is what unblocks a build.
  4. Is a next cycle already STAGED?             -> staging is what makes the roll invisible.

⚠️ IT NEEDS NO CREDENTIALS. It reads the same public dataset over plain HTTPS that the app reads,
and HEADs a public FAA URL. That is deliberate: a watchdog that needs a token is a watchdog that
stops running when the token expires, which is exactly when you stop hearing about dropped cycles.
Run it anywhere, on any box, as any user.

Exit codes are the interface — cron, a systemd timer or a CI step can act on them without parsing:
    0  everything current
    1  EXPIRED — published data is stale right now
    2  expiring soon
    3  could not tell (network, malformed manifest) — treated as a failure ON PURPOSE, because a
       watchdog that goes quiet when it cannot reach the network is worse than no watchdog

    python3 nav/cycle_watch.py                 # check, human-readable
    python3 nav/cycle_watch.py --json          # same, for a machine
    python3 nav/cycle_watch.py --warn-days 21  # start warning earlier
"""
import argparse
import datetime
import json
import sys
import urllib.error
import urllib.request

NAV_INDEX = "https://huggingface.co/datasets/SingularityUS/commsight-nav/resolve/main/index.json"

# The FAA posts each CIFP cycle at a date-stamped URL; `cifp.sqlite`'s own `source_url` records the
# shape, e.g. .../cifp/CIFP_261029.zip for the cycle effective 2026-10-29. Probing the NEXT one is
# how we know a build is possible, without scraping a page whose markup is not ours to depend on.
CIFP_URL = "https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_{yymmdd}.zip"

CYCLE_DAYS = 28                     # AIRAC. Nav data only; charts roll on their own 56-day clock.
TIMEOUT = 60


def fetch_index(url: str = NAV_INDEX) -> dict:
    """The published manifest, read the way the app reads it: plain anonymous HTTPS."""
    with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
        return json.load(r)


def faa_has_cycle(effective: datetime.date) -> bool:
    """True when the FAA has posted the CIFP for a cycle effective on this date.

    A HEAD, not a GET: the payload is tens of megabytes and we only want to know it is there.
    """
    url = CIFP_URL.format(yymmdd=effective.strftime("%y%m%d"))
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return 200 <= r.status < 300
    except urllib.error.HTTPError:
        return False                # 404 = not posted yet; any other code is still "cannot build"


def assess(index: dict, today: datetime.date, warn_days: int) -> dict:
    """Compare what is published against the calendar. Pure, so the tests can drive it."""
    assert warn_days >= 0, "warn-days cannot be negative"
    datasets = index.get("datasets") or {}
    assert isinstance(datasets, dict), "manifest has no datasets object"
    if not datasets:
        raise ValueError("the published manifest lists no datasets at all")

    rows, worst_expiry = [], None
    for name, d in sorted(datasets.items()):                 # bounded by the dataset count
        expires = d.get("expires")
        if not expires:
            raise ValueError(f"{name} has no expiry in the manifest")
        exp = datetime.date.fromisoformat(expires)
        days = (exp - today).days
        rows.append({"dataset": name, "cycle": str(d.get("cycle")),
                     "effective": d.get("effective"), "expires": expires, "days_left": days})
        # The WORST one decides, not the average: one expired dataset is a dropped cycle even if
        # the others are current, and `procedures.json` going stale 404s every plate on its own.
        if worst_expiry is None or days < worst_expiry:
            worst_expiry = days

    # The next cycle starts the day the current one expires — that is what "expires" means here.
    next_effective = min(datetime.date.fromisoformat(r["expires"]) for r in rows)
    # ⚠️ THE KEY IS "next", NOT "staged". Written as "staged" first, from the word the docs use for
    # the ACTION (`--stage-next`) rather than from the manifest. It is not a crash — `.get` returns
    # nothing — so it reported "NOTHING STAGED" against a manifest that had all three staged, which
    # is a false all-clear on the one fact this field exists to carry.
    staged = sorted((index.get("next") or {}).keys())

    # ⚠️ `<= 0`, NOT `< 0`. A cycle's expiry date IS its successor's effective date — 2610 expires
    # 2026-10-29 and 2611 becomes effective that same day — so "expires today" already means the
    # published data is the old cycle. The app activates a staged cycle at 0901Z on that date, so
    # for part of the day the old one is still legitimately in force; alarming from midnight makes
    # this a few hours early rather than a day late, which is the right direction for a safety net.
    if worst_expiry <= 0:
        status, code = "EXPIRED", 1
    elif worst_expiry <= warn_days:
        status, code = "EXPIRING", 2
    else:
        status, code = "CURRENT", 0

    return {"status": status, "exit_code": code, "today": today.isoformat(),
            "days_left": worst_expiry, "next_effective": next_effective.isoformat(),
            "staged": staged, "datasets": rows}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--warn-days", type=int, default=14,
                    help="warn this many days before expiry (default 14 — half a cycle)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--no-faa", action="store_true", help="skip the FAA probe (offline testing)")
    a = ap.parse_args()

    today = datetime.datetime.now(datetime.timezone.utc).date()
    try:
        report = assess(fetch_index(), today, a.warn_days)
    except Exception as e:
        # Exit 3, loudly. Silence here looks identical to "all is well", and that is the one
        # outcome this script must never produce.
        print(f"CANNOT TELL: {type(e).__name__}: {e}", file=sys.stderr)
        print("A watchdog that cannot reach its data is a failure, not a pass.", file=sys.stderr)
        return 3

    if not a.no_faa:
        nxt = datetime.date.fromisoformat(report["next_effective"])
        report["faa_has_next"] = faa_has_cycle(nxt)

    if a.json:
        print(json.dumps(report, indent=1))
        return report["exit_code"]

    print(f"nav cycle check — {report['today']}  [{report['status']}]")
    for r in report["datasets"]:                             # bounded by the dataset count
        late = (f"EXPIRED {-r['days_left']} days ago" if r["days_left"] < 0
                else f"{r['days_left']} days left")
        print(f"  {r['dataset']:<12} cycle {r['cycle']:<12} expires {r['expires']}  {late}")
    print(f"  staged next: {', '.join(report['staged']) if report['staged'] else 'NOTHING STAGED'}")
    if "faa_has_next" in report:
        nxt = report["next_effective"]
        print(f"  FAA CIFP for {nxt}: {'POSTED — buildable now' if report['faa_has_next'] else 'not posted yet'}")

    if report["exit_code"] == 1:
        print("\nPILOTS WHO TOOK AN OTA UPDATE ARE ON EXPIRED DATA RIGHT NOW.", file=sys.stderr)
        print("Build the cycle and run:  python3 nav/publish_nav.py --publish --from-dir <dir>",
              file=sys.stderr)
    elif report["exit_code"] == 2:
        print("\nStage the next cycle before it goes live, so the roll is invisible:", file=sys.stderr)
        print("  python3 nav/publish_nav.py --stage-next --from-dir <next-cycle dir>", file=sys.stderr)
    return report["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
