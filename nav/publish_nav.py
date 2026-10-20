#!/usr/bin/env python3
"""publish_nav.py — publish the bundled nav databases so the app can refresh them without a release.

`cifp.sqlite` (coded procedures) and `apt.sqlite` (airports, runways, frequencies) are built by
ios/Tools/build_cifp.py and ios/Tools/build_apt.py straight into the app bundle, and shipped only by
an App Store release. They are on a 28-day AIRAC cycle, so in practice they expire and stay expired:
measured 2026-10-19, both were cycle 2607 (effective 2026-07-09, expired 2026-08-06) while the FAA
had published 2608, 2609 and 2610.

The READ half of the fix already shipped. `NavDataUpdate` verifies a candidate against the same
invariants the builder enforces, installs it atomically, refuses one older than the bundle or not yet
in effect, and falls back to the bundle on any doubt. `CIFP.swift` and `AirportData.swift` already
resolve through `NavDataUpdate.activeURL`. What was missing was anything to download — and anywhere
to download it FROM. This is that second half.

Modelled on charts/publish_packs.py, and deliberately sharing its three hard-won rules:

  1. HF_HUB_DISABLE_XET=1, FORCED before huggingface_hub is imported. The app fetches with a plain
     anonymous GET; Xet-backed storage answers 403. A pack that uploads perfectly and cannot be read
     is the failure this project has already paid for twice.
  2. Every upload is VERIFIED with the same anonymous ranged GET the app will make, before the
     manifest that names it is published.
  3. index.json goes LAST, so a failure leaves the previous cycle whole rather than half-replaced.

Plus one rule of its own:

  4. REFUSE A CYCLE THAT IS NOT YET EFFECTIVE unless --stage-next is given, in which case it is
     published under a "next" key instead of the live one. The FAA posts a cycle weeks early; the
     device-side guard in NavDataUpdate.isNotYetEffective is the backstop, but publishing it as live
     would make every client depend on that backstop being correct.

  CYCLE_SANITY=1 python3 nav/publish_nav.py --dry-run
  python3 nav/publish_nav.py --publish
"""
import os, sys, json, sqlite3, hashlib, argparse, datetime, urllib.request, urllib.error

os.environ["HF_HUB_DISABLE_XET"] = "1"      # FORCED before the import below — see rule 1.
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")

REPO = os.environ.get("HF_NAV_DATASET", "SingularityUS/commsight-nav")
BASE = f"https://huggingface.co/datasets/{REPO}/resolve/main"
IOS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ios")
NAV = os.path.normpath(os.path.join(IOS, "ATCTranscribe", "Resources", "nav"))

# dataset key -> (local file, remote path, invariant queries mirroring NavDataUpdate.verify)
DATASETS = {
    "cifp": ("cifp.sqlite", "cifp.sqlite", [
        ("SELECT COUNT(*) FROM procedure", 1),
        ("SELECT COUNT(*) FROM leg", 1),
        ("SELECT COUNT(*) FROM leg WHERE substr(wp_desc,4,1)='M'", 1),
        ("SELECT COUNT(*) FROM leg WHERE substr(wp_desc,4,1)='F'", 1),
    ]),
    "apt": ("apt.sqlite", "apt.sqlite", [
        ("SELECT COUNT(*) FROM airport", 1),
        ("SELECT COUNT(*) FROM runway_end", 1),
        ("SELECT COUNT(*) FROM frequency", 1),
    ]),
    # JSON, not SQLite — handled by read_meta/check_invariants' json branches. It is here because it
    # is the dataset whose staleness broke a feature outright: Procedures.plateURL interpolates this
    # file's cycle into the d-TPP URL, the FAA ages old cycles off, and every plate 404'd for 74 days.
    "procedures": ("procedures.json", "procedures.json", []),
}


def read_meta(path):
    """Provenance, normalised to cycle/effective/expires whatever the container is.

    procedures.json keeps it as top-level cycle/from/to; the SQLite databases keep it in a `meta`
    table. NavDataUpdate.meta does the same normalisation on the device, so both sides agree.
    """
    if path.endswith(".json"):
        o = json.load(open(path))
        return {k: v for k, v in (("cycle", o.get("cycle")),
                                  ("effective", o.get("from")),
                                  ("expires", o.get("to"))) if v}
    c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        return dict(c.execute("SELECT key, value FROM meta").fetchall())
    finally:
        c.close()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_invariants(path, queries):
    """The same checks NavDataUpdate.verify runs on the device.

    Running them HERE as well is not redundant: the device check protects one pilot who already
    downloaded a bad file, this one stops it being published to everyone. A build that silently
    produced an empty table is the failure both exist for.
    """
    if path.endswith(".json"):
        # The corpus check NavDataUpdate.verifyProcedures makes: enough airports to be the real
        # index rather than a stub. 3,197 airports silently replaced by four would leave most of the
        # country with no plates and nothing saying why.
        o = json.load(open(path))
        n = len(o.get("airports") or {})
        if n < 1000:
            raise SystemExit(
                f"REFUSING {os.path.basename(path)}: only {n} airports. The device applies the same "
                f"floor, so publishing this would ship a file every client must then reject.")
        return
    c = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        for sql, at_least in queries:
            try:
                n = c.execute(sql).fetchone()[0]
            except sqlite3.Error as ex:
                raise SystemExit(f"REFUSING {os.path.basename(path)}: {sql} failed — {ex}")
            if n < at_least:
                raise SystemExit(
                    f"REFUSING {os.path.basename(path)}: `{sql}` returned {n}, expected >= {at_least}. "
                    f"NavDataUpdate.verify applies the same check on device, so publishing this would "
                    f"ship a file every client is then obliged to reject.")
    finally:
        c.close()


def verify_anonymous(remote_path):
    """Fetch the first KiB the way the app does: plain, anonymous, no token, no Xet client."""
    req = urllib.request.Request(f"{BASE}/{remote_path}", headers={"Range": "bytes=0-1023"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            head = r.read(16)
    except urllib.error.HTTPError as ex:
        hint = "  <-- XET: the app cannot fetch this" if ex.code == 403 else ""
        return False, f"HTTP {ex.code}{hint}"
    except Exception as ex:
        return False, f"{type(ex).__name__}: {ex}"
    expect_json = remote_path.endswith(".json")
    if expect_json:
        if not head.lstrip().startswith(b"{"):
            return False, f"not JSON (got {head[:16]!r})"
    elif not head.startswith(b"SQLite format 3"):
        return False, f"not SQLite (got {head[:16]!r})"
    return True, "ok"


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dry-run", action="store_true")
    g.add_argument("--publish", action="store_true")
    ap.add_argument("--stage-next", action="store_true",
                    help="publish a not-yet-effective cycle under `next` instead of refusing")
    ap.add_argument("--from-dir", default=NAV,
                    help="where to read the databases from (default: the app's bundled Resources/nav). "
                         "Point this at a build directory to publish a freshly built cycle WITHOUT "
                         "committing a 21 MB binary into the repo — which is the habit this whole "
                         "over-the-air path exists to end (git already carries 13 revisions of "
                         "cifp.sqlite, about 250 MB of history).")
    a = ap.parse_args()

    today = datetime.date.today().isoformat()
    manifest, plan, staged = {"schema": 1, "datasets": {}}, [], {}

    for key, (local_name, remote, queries) in DATASETS.items():
        path = os.path.join(a.from_dir, local_name)
        if not os.path.exists(path):
            raise SystemExit(f"REFUSING: {path} is missing — build it first (ios/Tools/build_{key}.py)")
        m = read_meta(path)
        cycle, eff, exp = m.get("cycle", ""), m.get("effective", ""), m.get("expires", "")
        if not cycle or not eff:
            raise SystemExit(
                f"REFUSING {local_name}: meta has cycle={cycle!r} effective={eff!r}. The device keys "
                f"every staleness decision off these; an undated database cannot be published.")
        check_invariants(path, queries)

        rec = {"dataset": key, "cycle": cycle, "effective": eff, "expires": exp,
               "bytes": os.path.getsize(path), "sha256": sha256(path), "path": remote}

        if exp and exp <= today:
            # Not harmful — the device already has this cycle bundled and would reject it as
            # `olderThanBundle` — but it means the BUILD is stale, and publishing it would let the
            # daily job report success while delivering nothing. The whole point of the job is that
            # nobody notices a cycle rolled; a publisher that shrugs at expired input reproduces
            # exactly that silence one layer down.
            raise SystemExit(
                f"REFUSING {local_name}: cycle {cycle} expired {exp} (today {today}). Rebuild it "
                f"first — ios/Tools/build_{key}.py — then publish. Publishing an expired cycle would "
                f"report success and change nothing on any device.")
        if eff > today:
            # Rule 4. The device refuses this too (NavDataUpdate.isNotYetEffective), but a publisher
            # that leans on the client's backstop has made every client's correctness load-bearing.
            if not a.stage_next:
                raise SystemExit(
                    f"REFUSING {local_name}: cycle {cycle} is effective {eff}, which is in the future "
                    f"(today {today}). The FAA posts cycles weeks early. Pass --stage-next to publish "
                    f"it under `next` for pre-download, or wait until it is in force.")
            # ⚠️ A DISTINCT REMOTE PATH. `remote` is constant per dataset ("cifp.sqlite"), so a staged
            # upload went to the SAME object the live manifest points at — publishing not-yet-effective
            # bytes over the in-force file while omitting the key from `datasets` entirely. Every
            # device would then fetch next cycle's data under this cycle's entry, which is the exact
            # thing --stage-next exists to avoid.
            rec = dict(rec, path=f"next/{remote}")
            staged[key] = rec
            plan.append((path, rec["path"]))
            print(f"  {key:5s} cycle {cycle}  effective {eff}  -> STAGED as next ({rec['bytes']/2**20:.1f} MiB)")
            continue
        else:
            manifest["datasets"][key] = rec
            print(f"  {key:5s} cycle {cycle}  effective {eff}  expires {exp}  "
                  f"({rec['bytes']/2**20:.1f} MiB)")
            plan.append((path, remote))

    if staged:
        manifest["next"] = staged
    if not manifest["datasets"] and not staged:
        raise SystemExit("REFUSING: nothing to publish.")

    # Beside this script (repo-root/nav/), not relative to the app's Resources — the earlier
    # "../../../nav" walked to ios/nav/, which does not exist.
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.json")
    json.dump(manifest, open(out, "w"), indent=1, sort_keys=True)
    print(f"\nmanifest: {out}")

    if a.dry_run:
        print("DRY RUN — nothing uploaded.")
        return

    from huggingface_hub import upload_file
    token = os.environ.get("HF_TOKEN") or open(os.path.expanduser("~/.hf_token")).read().strip()
    for local, remote in plan:
        upload_file(path_or_fileobj=local, path_in_repo=remote, repo_id=REPO,
                    repo_type="dataset", token=token)
        ok, why = verify_anonymous(remote)
        if not ok:
            raise SystemExit(f"!! {remote} uploaded but NOT fetchable: {why}\n"
                             f"   index.json was NOT touched, so the live cycle is intact.")
        print(f"  up+verified {remote}")

    upload_file(path_or_fileobj=out, path_in_repo="index.json", repo_id=REPO,
                repo_type="dataset", token=token)
    print("index.json published — nav data is now refreshable over the air")


if __name__ == "__main__":
    main()
