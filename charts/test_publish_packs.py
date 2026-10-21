"""Refusals and composition for `publish_packs.py --stage-next / --promote`.

WHY THESE EXIST. Promotion is the one step that will run UNATTENDED against the live manifest, and it
is a write that every device reads within the hour. It has no packs to upload and therefore none of
the natural friction that makes the publish path self-limiting — a bad promote is a 30 KB JSON write
that takes a layer away from every pilot, or calls next cycle's charts current nine hours early.

Run:  python3 charts/test_publish_packs.py
"""
import datetime
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("CYCLE", "10-29-2026")
os.environ.setdefault("OUT", "/tmp")

spec = importlib.util.spec_from_file_location("pp", os.path.join(HERE, "publish_packs.py"))
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)

FAILURES = []


def check(label, fn, expect):
    """`fn` must raise SystemExit whose message contains `expect` (or not raise, when expect is None)."""
    try:
        fn()
    except SystemExit as ex:
        got = str(ex)
        if expect is None:
            FAILURES.append(f"{label}: unexpected refusal: {got}")
        elif expect not in got:
            FAILURES.append(f"{label}: refused for the wrong reason\n    want ~{expect!r}\n    got  {got!r}")
        return
    if expect is not None:
        FAILURES.append(f"{label}: expected a refusal containing {expect!r}, got none")


def pack(i, cycle):
    return {"id": f"P{i}", "bounds": [-100, 30, -90, 40], "bytes": 1,
            "minzoom": 5, "maxzoom": 11, "path": f"c/{cycle}/x/P{i}.mbtiles"}


def families(cycle, counts=None):
    counts = counts or pp.EXPECTED
    return {k: [pack(i, cycle) for i in range(counts[k])] for k in pp.EXPECTED}


def hosted(live="09-03-2026", staged="10-29-2026", staged_counts=None, with_next=True):
    m = {"cycle": live}
    m.update(families(live))
    if with_next:
        n = {"cycle": staged, "effective": "2026-10-29"}
        n.update(families(staged, staged_counts))
        m["next"] = n
    return m


def run():
    today = datetime.date(2026, 10, 29)
    pp.verify_anonymous = lambda path: (True, "ok")          # the network is not under test here

    # --- the refusals ------------------------------------------------------
    pp.hosted_manifest = lambda: hosted(with_next=False)
    check("nothing staged", lambda: pp.promote("10-29-2026", today, dry_run=True),
          "has no `next` block")

    pp.hosted_manifest = lambda: hosted(staged="12-24-2026")
    check("cycle mismatch", lambda: pp.promote("10-29-2026", today, dry_run=True),
          "staged cycle is")

    pp.hosted_manifest = lambda: hosted()
    check("promoting early", lambda: pp.promote("10-29-2026", datetime.date(2026, 10, 28), dry_run=True),
          "takes effect")

    pp.hosted_manifest = lambda: hosted(staged_counts={"sectional": 37, "ifrLow": 36, "ifrHigh": 12})
    check("short family", lambda: pp.promote("10-29-2026", today, dry_run=True),
          "staged families are")

    # A pack that 404s must stop the promotion BEFORE the manifest is written — the staged upload
    # happened weeks ago and anything could have happened to the repo since.
    pp.hosted_manifest = lambda: hosted()
    pp.verify_anonymous = lambda path: (False, "HTTP 403  <-- XET: the app cannot fetch this")
    check("staged pack unfetchable", lambda: pp.promote("10-29-2026", today, dry_run=True),
          "not fetchable")
    pp.verify_anonymous = lambda path: (True, "ok")

    # --- the happy path ----------------------------------------------------
    import json
    out = os.path.join(pp.OUT, "index.json")
    if os.path.exists(out):
        os.remove(out)
    pp.hosted_manifest = lambda: hosted()
    check("promote composes", lambda: pp.promote("10-29-2026", today, dry_run=True), None)
    if not os.path.exists(out):
        FAILURES.append("promote composes: no index.json written")
    else:
        m = json.load(open(out))
        if m.get("cycle") != "10-29-2026":
            FAILURES.append(f"promote composes: live cycle is {m.get('cycle')!r}")
        if "next" in m:
            FAILURES.append("promote composes: the promoted manifest must not keep a `next` block — "
                            "it would have devices pre-cache the cycle they just started flying")
        for k, want in pp.EXPECTED.items():
            if len(m.get(k, [])) != want:
                FAILURES.append(f"promote composes: {k} has {len(m.get(k, []))}, want {want}")
        # The promoted entries must point at the ALREADY-HOSTED staged paths. If promotion rewrote
        # them to the canonical layout, every device would fetch a URL nothing was uploaded to, and
        # every pre-cached pack on every device would be re-downloaded for nothing.
        if not all(e["path"].startswith("c/10-29-2026/") for e in m["sectional"]):
            FAILURES.append("promote composes: staged paths were rewritten; pre-cached packs would "
                            "no longer match the manifest")
        os.remove(out)


run()
if FAILURES:
    print(f"FAILED ({len(FAILURES)}):")
    for f in FAILURES:
        print("  - " + f)
    sys.exit(1)
print("publish_packs: all promotion refusals and the compose path check out")
