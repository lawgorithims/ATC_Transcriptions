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
import os, sys, json, glob, sqlite3, urllib.request, urllib.error, argparse, datetime

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


def hosted_manifest():
    """The live index.json as devices see it — what staging must add to and promotion reads from."""
    req = urllib.request.Request(f"{BASE}/index.json", headers={"User-Agent": "commsight-publisher"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def promote(cycle, today, dry_run=False):
    """Make the staged cycle live.

    THIS UPLOADS NOTHING BUT THE MANIFEST, and that is the point of the whole staging design. Packs
    are hosted under a CYCLE-SCOPED prefix (`c/<cycle>/...`), so the bytes a device pre-cached weeks
    ago are at the same URL the live manifest will now point at. Promotion is a 30 KB JSON write.
    """
    live = hosted_manifest()
    nxt = live.get("next")
    if not nxt:
        raise SystemExit("REFUSING: the hosted manifest has no `next` block — nothing is staged. "
                         "Run --stage-next first.")
    if nxt.get("cycle") != cycle:
        raise SystemExit(f"REFUSING: staged cycle is {nxt.get('cycle')!r} but CYCLE={cycle!r}. "
                         f"Set CYCLE to the staged one, or re-stage.")
    eff = datetime.datetime.strptime(cycle, "%m-%d-%Y").date()
    if today < eff:
        raise SystemExit(f"REFUSING: {cycle} takes effect {eff} — {(eff - today).days} days from now "
                         f"(today {today}). Promoting early makes every device call these charts "
                         f"current, which is what staging exists to avoid.")
    counts = {k: len(nxt.get(k, [])) for k in EXPECTED}
    if counts != EXPECTED:
        raise SystemExit(f"REFUSING: staged families are {counts}, expected {EXPECTED}. Promoting a "
                         f"short manifest takes charts away from every pilot.")

    # ⚠️ PROVE THE STAGED PACKS ARE STILL FETCHABLE BEFORE POINTING EVERY DEVICE AT THEM. The upload
    # happened weeks ago; a repo reorganisation, a failed LFS migration or a Xet flip since then would
    # turn promotion into a manifest that lists 86 packs nobody can download, with no way back except
    # a re-upload. One range request each is seconds.
    print("verifying the staged packs are still fetchable...")
    bad = []
    for k in EXPECTED:
        for rec in nxt[k]:
            ok, why = verify_anonymous(rec["path"])
            if not ok:
                bad.append(f"{rec['path']}: {why}")
    if bad:
        raise SystemExit("REFUSING: staged packs are not fetchable, index.json NOT touched:\n  "
                         + "\n  ".join(bad[:10]))

    out = {"cycle": cycle}
    for k in EXPECTED:
        out[k] = nxt[k]
    out_idx = os.path.join(OUT, "index.json")
    json.dump(out, open(out_idx, "w"), separators=(",", ":"))
    print(f"manifest written: {out_idx}")
    if dry_run:
        print(f"DRY RUN — index.json NOT uploaded. Would make {cycle} live with "
              f"{sum(len(out[k]) for k in EXPECTED)} packs already hosted.")
        return

    from huggingface_hub import upload_file
    token = os.environ.get("HF_TOKEN") or open(os.path.expanduser("~/.hf_token")).read().strip()
    upload_file(path_or_fileobj=out_idx, path_in_repo="index.json", repo_id=REPO,
                repo_type="dataset", token=token)
    print(f"index.json published — cycle {cycle} is now LIVE, and no pack was re-uploaded.")
    stale = live.get("cycle")
    if stale and stale != cycle:
        print(f"\nNote: cycle {stale}'s packs are still hosted under c/{stale}/ and are now "
              f"unreferenced. Delete them when you are satisfied nothing is reading them; this "
              f"script will not remove hosted data on its own.")


def main():
    ap = argparse.ArgumentParser()
    # The ACTION is exclusive; --dry-run is a modifier on whichever action is chosen, so a staging or
    # promotion run can be rehearsed. (It was in the exclusive group, which made `--dry-run
    # --stage-next` an argparse error — i.e. the two riskiest modes were the two that could not be
    # practised.) --dry-run alone keeps its old meaning: compose and validate a live publish.
    g = ap.add_mutually_exclusive_group(required=False)
    g.add_argument("--publish", action="store_true", help="upload packs, verify each, then the manifest")
    g.add_argument("--stage-next", action="store_true",
                   help="upload a FUTURE cycle's packs and advertise them under `next` for "
                        "pre-caching, leaving the live cycle untouched")
    g.add_argument("--promote", action="store_true",
                   help="make the already-staged `next` cycle live. Rewrites index.json only — the "
                        "packs are already hosted, so this moves no data at all")
    ap.add_argument("--dry-run", action="store_true",
                    help="compose + validate, upload nothing. Combine with --stage-next / --promote "
                         "to rehearse those without touching the hosted manifest")
    ap.add_argument("--publish-early", action="store_true",
                    help="publish a cycle that has not taken effect yet (the FAA posts weeks ahead)")
    ap.add_argument("--allow-partial", action="store_true",
                    help="publish even if a family is short of its expected pack count")
    a = ap.parse_args()
    if not (a.publish or a.stage_next or a.promote or a.dry_run):
        raise SystemExit("pick an action: --dry-run / --publish / --stage-next / --promote")

    if not CYCLE:
        raise SystemExit("REFUSING: CYCLE is unset. A manifest whose cycle does not match its packs "
                         "is worse than no manifest — the app trusts it to decide what is current.")

    # ⚠️ REFUSE A CYCLE THAT IS NOT IN FORCE YET, unless asked explicitly.
    #
    # The FAA posts a chart cycle weeks ahead — 10-29-2026 was fully downloadable on 2026-10-19 — and
    # the app derives currency from this manifest's `cycle` alone (ChartCatalog.provenance: effective
    # date + 56 days). Publish early and every device treats next cycle's charts as today's, with no
    # banner and nothing to notice. That is worse than publishing late: an expired chart announces
    # itself, a premature one looks exactly like a current one.
    #
    # `publish_nav.py` has refused this since it was written; charts had no such guard, which is the
    # asymmetry this closes. --publish-early is there because BUILDING ahead is correct and someone
    # will legitimately want to stage the artifacts; it just must be a decision, not a default.
    try:
        eff = datetime.datetime.strptime(CYCLE, "%m-%d-%Y").date()
    except ValueError:
        raise SystemExit(f"REFUSING: CYCLE {CYCLE!r} is not MM-DD-YYYY, so its effective date cannot "
                         f"be checked.")
    # UTC, not the runner's local date. FAA cycles turn at 0901Z and a CI runner can be hours
    # either side of that; a local date makes "is this effective yet" wrong for a whole day around
    # every rollover, in whichever direction the runner happens to sit.
    today = datetime.datetime.now(datetime.timezone.utc).date()

    if a.promote:
        promote(CYCLE, today, dry_run=a.dry_run)
        return

    if a.stage_next:
        # Staging is for the FUTURE. A cycle already in force belongs in the live block, and putting it
        # under `next` would leave devices pre-caching a cycle they should be flying.
        if eff <= today:
            raise SystemExit(
                f"REFUSING: cycle {CYCLE} took effect {eff} (today {today}), so it is not a NEXT "
                f"cycle. Publish it live with --publish.")
    elif eff > today and not a.publish_early:
        raise SystemExit(
            f"REFUSING: cycle {CYCLE} takes effect {eff} — {(eff - today).days} days from now "
            f"(today {today}).\n"
            f"  Building ahead is correct; publishing ahead makes every device call these charts "
            f"current.\n"
            f"  Pass --stage-next to host it for pre-caching without changing what any device calls "
            f"current (then --promote on {eff}), or --publish-early if you have a reason.")

    # ⚠️ CYCLE-SCOPED REMOTE PATHS, FOR BOTH MODES.
    #
    # These used to be `sectional/New_York_SEC.mbtiles` — constant per pack, so publishing a new cycle
    # OVERWROTE the live bytes in place. Two consequences, one of which was already shipping:
    #
    #   * index.json goes up last, deliberately, so during the hours a 3 GB upload takes, every device
    #     is still reading the OLD manifest while the packs underneath it are being replaced with the
    #     NEW cycle's. Entry says 09-03-2026, bytes say 10-29-2026, nothing can tell.
    #   * Staging would be impossible: there is no second place to put next cycle's pack.
    #
    # One prefix per cycle fixes both, and makes promotion a manifest rewrite with no data movement.
    remote_prefix = f"c/{CYCLE}/"

    manifest, plan, problems = {"cycle": CYCLE}, [], []
    for label, pattern, subdir, key in FAMILIES:
        recs = []
        for p in sorted(glob.glob(os.path.join(OUT, pattern))):
            r = read_pack(p)
            r["path"] = f"{remote_prefix}{subdir}/{r['id']}.mbtiles"
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

    if a.stage_next:
        # The staged block replaces nothing: the live cycle, and every pack path in it, is carried
        # over from the HOSTED manifest untouched. Composing it from local files instead is the defect
        # publish_nav.py had — on a staging run every local pack is next cycle's, so a locally-composed
        # live block is next cycle's packs advertised as current, or empty. Either one is worse than
        # not staging at all.
        try:
            live = hosted_manifest()
        except Exception as ex:
            raise SystemExit(
                f"REFUSING: --stage-next must merge into the hosted manifest, and it could not be "
                f"read ({type(ex).__name__}: {ex}). The live cycle was NOT touched.")
        live_cycle = live.get("cycle")
        if not live_cycle:
            raise SystemExit("REFUSING: the hosted manifest has no live `cycle`. Publish a live cycle "
                             "first, then stage the next one.")
        if live_cycle == CYCLE:
            raise SystemExit(f"REFUSING: {CYCLE} is already the LIVE cycle — staging it as `next` "
                             f"would have devices pre-cache what they are already flying.")
        for k in EXPECTED:
            if not live.get(k):
                raise SystemExit(f"REFUSING: the hosted manifest's `{k}` is empty, so merging into it "
                                 f"would publish a manifest missing that layer.")
        staged_block = {"cycle": CYCLE, "effective": eff.isoformat()}
        for k in EXPECTED:
            staged_block[k] = manifest[k]
        merged = {"cycle": live_cycle}
        for k in EXPECTED:
            merged[k] = live[k]
        merged["next"] = staged_block
        manifest = merged
        print(f"\nstaging {CYCLE} (effective {eff}) as `next`; live cycle {live_cycle} preserved "
              f"with {sum(len(live[k]) for k in EXPECTED)} packs")

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
    if a.stage_next:
        n = manifest["next"]
        print(f"\nindex.json published — cycle {CYCLE} is STAGED for pre-caching "
              f"({len(n['sectional'])} sectional / {len(n['ifrLow'])} ifrLow / "
              f"{len(n['ifrHigh'])} ifrHigh). Live cycle is still {manifest['cycle']}.\n"
              f"Run with --promote on or after {eff} to make it live (no re-upload).")
    else:
        print(f"\nindex.json published — cycle {CYCLE} is now live "
              f"({len(manifest['sectional'])} sectional / {len(manifest['ifrLow'])} ifrLow / "
              f"{len(manifest['ifrHigh'])} ifrHigh)")


if __name__ == "__main__":
    main()
