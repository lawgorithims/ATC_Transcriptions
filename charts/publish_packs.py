#!/usr/bin/env python3
"""publish_packs.py — publish a complete chart cycle to HuggingFace, correct by construction.

Replaces the upload path in build_all_packs.sh + build_ifr_high_conus.sh, which between them
have three defects this script exists to not have:

1. ⚠️ THEY DO NOT DISABLE XET. They set HF_HUB_ENABLE_HF_TRANSFER=1 and nothing else, so every
   pack lands Xet-backed — and the app fetches packs with a plain anonymous GET, which Xet answers
   with 403. That is what `rehost_classic_lfs.sh` is for: an entire second pass that re-downloads
   and re-uploads every pack to undo it. `lz/publish.py` learned this and FORCES the flag before
   importing huggingface_hub; the chart scripts never did. Forced here too, for the same reason —
   an inherited HF_HUB_DISABLE_XET=0 would silently re-enable it.

2. ⚠️ build_all_packs.sh WRITES A MANIFEST WITH NO ifrHigh. Its index.json has only `sectional`
   and `ifrLow`, and build_ifr_high_conus.sh patches ifrHigh back in afterwards by merging into
   the HOSTED copy. Run the two in sequence with uploads on and there is a window — however long
   12 IFR-high charts take — where the published manifest has taken the IFR-high layer away from
   every pilot. This composes all three families from local packs and uploads ONE complete
   manifest, last.

3. ⚠️ NOTHING PROVED THE TRANSPORT. A pack can upload "successfully" and still be unfetchable by
   the app. Every pack is verified after upload with the same plain anonymous ranged GET the app
   makes, and a failure is loud.

The manifest is uploaded only after every pack has uploaded AND verified, so a partial run never
points pilots at packs that are not there. Resumable: re-running skips packs already done.

⚠️ RUN IT WITH THE chartenv INTERPRETER, not system python3 — huggingface_hub lives only in that
venv (the shell scripts all reach for ~/chartenv/bin/hf for the same reason). System python3 gets
as far as composing the manifest and then dies on the import:

  CYCLE=09-03-2026 OUT=/path/to/packs ~/chartenv/bin/python3 publish_packs.py --dry-run
  CYCLE=09-03-2026 OUT=/path/to/packs ~/chartenv/bin/python3 publish_packs.py --publish

--dry-run needs no huggingface_hub at all, so it works under either interpreter — which is exactly
how a --publish run can look fine right up to the upload. The import is deferred to the publish
branch on purpose, but that means the failure lands after the manifest is written; it lands BEFORE
any upload, so the hosted cycle is never left half-replaced.
"""
import os, sys, json, glob, sqlite3, urllib.request, urllib.error, argparse

os.environ["HF_HUB_DISABLE_XET"] = "1"   # FORCED before the import below — see defect 1 above.
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")

REPO = os.environ.get("HF_DATASET", "SingularityUS/faa-charts")
BASE = f"https://huggingface.co/datasets/{REPO}/resolve/main"
OUT  = os.environ.get("OUT", "/Users/bsusl/CommSight/charts-build/packs")
CYCLE = os.environ.get("CYCLE", "")

# family -> (local glob, remote subdirectory, manifest key)
FAMILIES = [
    ("sectional", "*_SEC.mbtiles",   "sectional", "sectional"),
    ("IFR-low",   "ENR_L*.mbtiles",  "ifr",       "ifrLow"),
    ("IFR-high",  "ENR_H*.mbtiles",  "ifrhigh",   "ifrHigh"),
]
EXPECTED = {"sectional": 37, "ifrLow": 37, "ifrHigh": 12}


def read_pack(path):
    """Pull the manifest record out of a pack, and refuse one that is not WEBP or not this cycle."""
    m = dict(sqlite3.connect(path).execute("select name,value from metadata").fetchall())
    fmt = (m.get("format") or "").lower()
    if fmt != "webp":
        raise SystemExit(
            f"REFUSING: {os.path.basename(path)} is format={fmt!r}, not webp. charts.conf documents "
            f"that an unexported TILE_FORMAT silently builds PNG at ~5x the size (~15 GB of packs "
            f"instead of ~3 GB, on the host AND on every pilot's iPad). Rebuild it."
        )
    # ⚠️ THE PACK MUST SAY WHICH CYCLE IT IS, AND IT MUST AGREE WITH THIS RUN.
    #
    # Every resumability check in this pipeline is "does the output file exist" — build_all_packs.sh
    # skips a built pack, build_ifr_high_conus.sh skips a built pack, and .published_charts.json skips
    # a published one. On a hand-run build from a clean directory that is correct. On a SCHEDULED build
    # with a persistent scratch volume it is catastrophic: on cycle-roll day every check passes, not one
    # chart is rebuilt, and last cycle's packs are published under the new cycle number. The manifest
    # says 10-29-2026, the tiles are 09-03-2026, and nothing downstream can tell. A pilot briefing off
    # charts the app calls current is the worst output this pipeline can produce.
    #
    # build_chart.sh stamps `faa_cycle` at build time, so the artifact carries its own provenance and a
    # mismatch is caught here rather than in the cockpit. Absent is refused too — a pack built before
    # the stamp existed cannot be verified, and "cannot verify" is not "fine".
    stamped = m.get("faa_cycle")
    if stamped != CYCLE:
        raise SystemExit(
            f"REFUSING: {os.path.basename(path)} is stamped faa_cycle={stamped!r} but this run is "
            f"publishing {CYCLE!r}.\n"
            f"  Most likely a scratch directory left over from the previous cycle: the build skipped it "
            f"because the file already existed.\n"
            f"  Rebuild into a cycle-scoped OUT (e.g. OUT=$SCRATCH/packs/{CYCLE}), or delete the stale "
            f"packs and rebuild.\n"
            f"  If stamped is None the pack predates the faa_cycle stamp and must be rebuilt."
        )
    name = os.path.splitext(os.path.basename(path))[0]
    return {
        "id": name,
        "bounds": [float(x) for x in m["bounds"].split(",")],
        "bytes": os.path.getsize(path),
        "minzoom": int(m["minzoom"]),
        "maxzoom": int(m["maxzoom"]),
    }


def verify_anonymous(remote_path):
    """Fetch the first KiB exactly the way the app does: plain, anonymous, no token, no Xet client.

    A 403 here is the Xet failure mode; anything that is not SQLite means the app would get a
    file it cannot open.
    """
    req = urllib.request.Request(f"{BASE}/{remote_path}", headers={"Range": "bytes=0-1023"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            head = r.read(16)
    except urllib.error.HTTPError as ex:
        hint = "  <-- XET: the app cannot fetch this" if ex.code == 403 else ""
        return False, f"HTTP {ex.code}{hint}"
    except Exception as ex:
        return False, f"{type(ex).__name__}: {ex}"
    if not head.startswith(b"SQLite format 3"):
        return False, f"not SQLite (got {head[:16]!r})"
    return True, "ok"


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--dry-run", action="store_true", help="compose + validate the manifest, upload nothing")
    g.add_argument("--publish", action="store_true", help="upload packs, verify each, then the manifest")
    ap.add_argument("--allow-partial", action="store_true",
                    help="publish even if a family is short of its expected pack count")
    a = ap.parse_args()

    if not CYCLE:
        raise SystemExit("REFUSING: CYCLE is unset. A manifest whose cycle does not match its packs "
                         "is worse than no manifest — the app trusts it to decide what is current.")

    manifest, plan, problems = {"cycle": CYCLE}, [], []
    for label, pattern, subdir, key in FAMILIES:
        recs = []
        for p in sorted(glob.glob(os.path.join(OUT, pattern))):
            r = read_pack(p)
            r["path"] = f"{subdir}/{r['id']}.mbtiles"
            recs.append(r)
            plan.append((p, r["path"]))
        manifest[key] = recs
        want = EXPECTED[key]
        flag = "" if len(recs) == want else f"  <-- expected {want}"
        if len(recs) != want:
            problems.append(f"{label}: {len(recs)}/{want}")
        print(f"  {label:10s} {len(recs):3d} packs  "
              f"{sum(r['bytes'] for r in recs)/2**30:6.2f} GiB{flag}")

    print(f"\ncycle={CYCLE}  total {sum(r['bytes'] for k in EXPECTED for r in manifest[k])/2**30:.2f} GiB "
          f"across {len(plan)} packs")

    if any(not manifest[k] for k in EXPECTED):
        raise SystemExit("REFUSING: a family is EMPTY. Publishing that manifest would take a whole "
                         "layer away from every pilot (the same guard build_ifr_high_conus.sh has).")
    if problems and not a.allow_partial:
        raise SystemExit(f"REFUSING: incomplete families: {', '.join(problems)}. "
                         f"Finish the build, or pass --allow-partial deliberately.")

    out_idx = os.path.join(OUT, "index.json")
    json.dump(manifest, open(out_idx, "w"), separators=(",", ":"))
    print(f"manifest written: {out_idx}")

    if a.dry_run:
        print("\nDRY RUN — nothing uploaded.")
        return

    from huggingface_hub import upload_file
    token = os.environ.get("HF_TOKEN") or open(os.path.expanduser("~/.hf_token")).read().strip()
    done_path = os.path.join(OUT, ".published_charts.json")
    done = json.load(open(done_path)) if os.path.exists(done_path) else {}

    for i, (local, remote) in enumerate(plan, 1):
        sz = os.path.getsize(local)
        if done.get(remote) == sz:
            print(f"[{i}/{len(plan)}] skip {remote} (already published)")
            continue
        upload_file(path_or_fileobj=local, path_in_repo=remote, repo_id=REPO,
                    repo_type="dataset", token=token)
        ok, why = verify_anonymous(remote)
        if not ok:
            raise SystemExit(f"[{i}/{len(plan)}] !! {remote} uploaded but NOT fetchable: {why}\n"
                             f"   index.json was NOT touched, so the hosted cycle is still intact.")
        done[remote] = sz
        json.dump(done, open(done_path, "w"), indent=1)
        print(f"[{i}/{len(plan)}] up+verified {remote} ({sz/2**20:.1f} MiB)")

    # The manifest goes LAST and only once every pack above is proven fetchable.
    upload_file(path_or_fileobj=out_idx, path_in_repo="index.json", repo_id=REPO,
                repo_type="dataset", token=token)
    print(f"\nindex.json published — cycle {CYCLE} is now live "
          f"({len(manifest['sectional'])} sectional / {len(manifest['ifrLow'])} ifrLow / "
          f"{len(manifest['ifrHigh'])} ifrHigh)")


if __name__ == "__main__":
    main()
