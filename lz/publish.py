#!/usr/bin/env python3
"""publish.py — upload built .lzpack cells to HuggingFace and regenerate the catalog.

WHAT THIS PUBLISHES
    lz/out/<cell>.lzpack  ->  https://huggingface.co/datasets/<REPO>/resolve/main/cells/<cell>.lzpack
    a generated index.json at the repo root, which the app reads to know what exists.

    Its own dataset repo, not a folder inside faa-charts: house style is one repo per content class
    (charts / models / this), and a separate repo lets the public-domain sourcing and the ODbL
    quarantine be stated once, in one README, next to the only files they govern.

=================================================================================================
THE XET TRAP — READ THIS BEFORE CHANGING ANY UPLOAD CODE
=================================================================================================
HuggingFace migrated large-file storage to Xet, which serves files ONLY via a chunk-reconstruction
protocol. The app fetches packs with a plain anonymous `GET /resolve/main/<path>` (ChartLibrary's
`URLSession.shared.download(from:)`, which requires a hard 200) and CANNOT speak that protocol, so
a Xet-backed file answers **403** and the layer silently has no data.

This already happened once to the FAA chart packs and cost a full re-host of every pack
(charts/rehost_classic_lfs.sh). Worse, it is not simply repairable by re-uploading: Xet dedups by
CONTENT HASH, so pushing identical bytes with Xet disabled just re-links the existing Xet object.
The rehost script has to mutate every file with a junk metadata row first to break the hash.

    => The ONLY cheap fix is to never create the Xet object in the first place.
    => HF_HUB_DISABLE_XET must be set BEFORE huggingface_hub is imported, because the library
       decides its storage backend at import time.
    => It is FORCED here, not defaulted. An inherited `HF_HUB_DISABLE_XET=0` would silently
       reintroduce the bug, and the symptom appears days later as "the layer stopped working".

`charts/build_all_packs.sh` still does NOT set it. Do not copy that script's upload path.

=================================================================================================
WHY THIS SCRIPT IS NOISY ON FAILURE
=================================================================================================
The chart uploader is `up(){ ... "$HF" upload ... >/dev/null 2>&1 && echo "  up $2"; }` under
`set -uo pipefail` with no `-e`: every error is discarded, only successes print, and a whole run
can report success having uploaded nothing at all. Here every failure raises, and the run ends with
an INDEPENDENT verification pass that fetches what was published the way the app would.

USAGE
    python3 lz/publish.py --list                     # what is built locally vs what is hosted
    python3 lz/publish.py --dry-run                  # build the catalog, upload nothing
    python3 lz/publish.py --publish                  # upload packs + index.json, then verify
    python3 lz/publish.py --publish --cell n33w107   # just one cell
    python3 lz/publish.py --verify                   # verification pass alone, against what is live

    HF_TOKEN is read from the environment, else ~/.hf_token (mode 600). A WRITE token is needed to
    publish; verification is anonymous and needs none.
"""

# ---------------------------------------------------------------------------------------------
# THE ONE LINE THAT MATTERS. Must precede the huggingface_hub import — see the header.
# ---------------------------------------------------------------------------------------------
import os

os.environ["HF_HUB_DISABLE_XET"] = "1"          # FORCED, not setdefault (see header)

import argparse
import hashlib
import json
import sqlite3
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lzcommon as C  # noqa: E402

# ---------------------------------------------------------------------------------------------
# 1. WHERE THINGS LIVE
# ---------------------------------------------------------------------------------------------

REPO = os.environ.get("LZ_HF_REPO", "SingularityUS/commsight-lz")
REPO_TYPE = "dataset"
BASE_URL = f"https://huggingface.co/datasets/{REPO}/resolve/main"
CELL_PREFIX = "cells"                    # mirrors the charts' sectional/ ifr/ ifrhigh/ convention
INDEX_NAME = "index.json"
CATALOG_SCHEMA = 1

OUT_DIR = os.path.join(HERE, "out")
DONE_PATH = os.path.join(OUT_DIR, ".published.json")

# Named groupings the Downloads UI offers as a unit. A pilot does not think in degree cells; they
# think "the area I fly in". Cells stay the download UNIT (they are what the pipeline emits and what
# the app mounts) — a region is only a label over a set of them.
REGIONS = [
    {
        "id": "southern-nm",
        "title": "Southern New Mexico",
        "note": "Las Cruces, the Mesilla Valley, the Organ and San Andres ranges, the "
                "Tularosa Basin and the Rio Grande corridor north toward Socorro.",
        # USGS 3DEP naming: nXXwYYY is the cell whose NORTH-WEST corner is XX N, YYY W, so
        # n33w107 covers lat 32-33, lon -107..-106.
        #
        # ⚠️ THE SOUTHERN ROW OF THE OBVIOUS 3x3 RING IS IN MEXICO. n32w107 and n32w108 span lat
        # 31-32, which is almost entirely south of the border, and 3DEP is US-only — both resolved
        # 0.0% DEM coverage and can never be built. n32w106 survives at 94.65% because the border
        # dips south near El Paso. The ring is therefore shifted NORTH into New Mexico rather than
        # squared around Las Cruces.
        "cells": ["n32w105", "n32w106",
                  "n33w105", "n33w106", "n33w107", "n33w108",
                  "n34w105", "n34w106", "n34w107", "n34w108"],
    },
    {
        "id": "northern-nm",
        "title": "Northern New Mexico",
        "note": "Albuquerque, Santa Fe, the middle Rio Grande, the Sandias and the Jemez, "
                "north toward the Colorado line.",
        "cells": ["n35w105", "n35w106", "n35w107", "n35w108",
                  "n36w105", "n36w106", "n36w107", "n36w108",
                  "n37w105", "n37w106", "n37w107", "n37w108"],
    },
    {
        "id": "eastern-az",
        "title": "Eastern Arizona",
        "note": "The White Mountains, the Mogollon Rim, the Little Colorado and the high "
                "desert north toward the Navajo Nation.",
        "cells": ["n32w110", "n33w110", "n34w110", "n35w110", "n36w110", "n37w110",
                  "n32w111", "n33w111", "n34w111", "n35w111", "n36w111", "n37w111"],
    },
    {
        "id": "central-az",
        "title": "Central Arizona",
        "note": "Phoenix and the Valley, Prescott, Sedona and the Verde, Flagstaff and the "
                "San Francisco Peaks, north to the Grand Canyon.",
        "cells": ["n32w112", "n33w112", "n34w112", "n35w112", "n36w112", "n37w112",
                  "n32w113", "n33w113", "n34w113", "n35w113", "n36w113", "n37w113"],
    },
    {
        # ⚠️ THE n32 ROW IS MEXICO HERE AND IS DELIBERATELY ABSENT. West of Nogales the border runs
        # from the Colorado River at about 32.7 N south-east to 31.33 N, so n32w114 and n32w115 —
        # lat 31-32 — lie entirely in Sonora and Baja. 3DEP is US-only: they would resolve 0.0%
        # coverage and can never be built, exactly like n32w107 and n32w108. n33w114 and n33w115
        # straddle the line and build at partial coverage, which is the border and not a fault.
        "id": "lower-colorado",
        "title": "Lower Colorado River",
        "note": "Yuma and the Imperial Valley, Blythe and the Palo Verde, Parker, Lake Havasu, "
                "Bullhead City and Kingman — the river corridor and the eastern Mojave.",
        "cells": ["n33w114", "n34w114", "n35w114", "n36w114", "n37w114",
                  "n33w115", "n34w115", "n35w115", "n36w115", "n37w115"],
    },
    {
        "id": "socal",
        "title": "Southern California",
        "note": "San Diego and the back country, Anza-Borrego and the Salton Sea, Palm Springs "
                "and the Inland Empire, the Los Angeles basin and Orange County out to the coast.",
        # ⚠️ THE n32 ROW IS ABSENT WEST OF w115 AND ALWAYS WILL BE. From the Colorado River the
        # border runs straight to the Pacific at 32.53 N, so lat 31-32 here is entirely Baja.
        "cells": ["n33w116", "n33w117", "n33w118", "n33w119",
                  "n34w116", "n34w117", "n34w118", "n34w119"],
    },
    {
        "id": "mojave-sierra",
        "title": "Mojave and the Eastern Sierra",
        "note": "Barstow and the high desert, the Antelope Valley, China Lake, Death Valley, "
                "the Owens Valley under the Sierra crest, and Las Vegas.",
        "cells": ["n35w116", "n35w117", "n35w118",
                  "n36w116", "n36w117", "n36w118",
                  "n37w116", "n37w117", "n37w118"],
    },
    {
        "id": "central-california",
        "title": "Central California",
        "note": "Santa Barbara and the Channel, San Luis Obispo and Paso Robles, Bakersfield and "
                "the southern San Joaquin, the southern Sierra, Big Sur and Monterey.",
        # ⚠️ FIVE CANDIDATE CELLS ARE OPEN PACIFIC AND ARE NOT HERE: n33w120, n33w121, n33w122,
        # n34w122 and n35w122. The survey index reports no 1 m lidar over any of them, which is not
        # a gap in 3DEP — there is no land under them to survey.
        "cells": ["n34w120", "n34w121",
                  "n35w119", "n35w120", "n35w121",
                  "n36w119", "n36w120", "n36w121", "n36w122",
                  "n37w119", "n37w120", "n37w121", "n37w122"],
    },
    {
        "id": "western-nm",
        "title": "Western New Mexico",
        "note": "The Continental Divide, the Gila high country and the Arizona border.",
        "cells": ["n33w109", "n34w109", "n35w109", "n36w109", "n37w109"],
    },
]

# ⚠️ A REGION LISTS CELLS THAT MAY NOT EXIST YET. `build_catalog` filters each region down to what
# is actually published, and drops a region entirely when none of its cells are — so naming the
# whole planned block here is safe, and the catalog never offers a download that 404s. Forgetting
# to add a cell here is the failure that bites: it builds, it publishes, and it is invisible.


def assert_every_pack_has_a_region(cells):
    """Refuse to publish a pack that no region names.

    ⚠️ THIS HAS BITTEN TWICE. The region list is hand-maintained and the cell list is generated by
    whatever the build queue happened to run, so they drift apart silently every time coverage
    grows. Both times the packs uploaded perfectly, sat in the repo, and were ABSENT from index.json
    — invisible to the app, with nothing anywhere reporting a problem. Six cells the first time
    (everything east or north, including Albuquerque); twelve the second (all of Arizona).

    It is the same shape as every other defect in this pipeline: a step that succeeds while
    producing nothing usable. So it is a hard failure now rather than a thing to remember.
    """
    listed = {c for r in REGIONS for c in r["cells"]}
    orphans = sorted(set(cells) - listed)
    if orphans:
        _fail("these packs are in no region, so they would upload and be INVISIBLE in the app:\n"
              + "    " + " ".join(orphans)
              + "\n  Add them to REGIONS in lz/publish.py and re-run.")

VERIFY_RANGE_BYTES = 1 << 20             # first MiB is plenty to prove the transport works


def _fail(msg):
    """Every failure path in this script ends here. Loud, non-zero, no partial-success illusion."""
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def hf_token():
    """WRITE token for publishing. Same idiom as every other uploader in this repo."""
    tok = os.environ.get("HF_TOKEN")
    if tok:
        return tok.strip()
    path = os.path.expanduser("~/.hf_token")
    if os.path.exists(path):
        with open(path) as fh:
            return fh.read().strip()
    return None


# ---------------------------------------------------------------------------------------------
# 2. READING A BUILT PACK — the catalog is DERIVED, never hand-maintained
# ---------------------------------------------------------------------------------------------

def pack_metadata(path):
    """The pack's own MBTiles metadata table. Everything the catalog needs is already in here,
    written by package.py — so the catalog cannot drift from the artifact it describes."""
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        rows = dict(db.execute("SELECT name, value FROM metadata").fetchall())
        db.close()
        return rows
    except sqlite3.Error as e:
        _fail(f"{os.path.basename(path)}: not readable as MBTiles ({e})")


def sha256_of(path):
    """Streamed so an 88 MB pack does not land in memory."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):   # bounded (rule 2)
            h.update(chunk)
    return h.hexdigest()


def catalog_entry(path):
    """One `cells[]` record. Fails rather than publishing a pack the app would refuse to mount."""
    m = pack_metadata(path)
    cell = m.get("lz_cell")
    if not cell:
        _fail(f"{os.path.basename(path)}: no lz_cell in metadata — not an lzpack")
    # Refuse at PUBLISH time what the device would refuse at MOUNT time. A pack that ships and then
    # silently fails to mount is the worst outcome: the pilot pays 88 MB for nothing and the layer
    # looks broken rather than absent. LZPackStore.reload() checks exactly these two.
    schema = int(m.get("lz_schema", 0))
    if schema != C.LZ_SCHEMA:
        _fail(f"{cell}: built at schema {schema}, this pipeline is at {C.LZ_SCHEMA}. "
              f"Re-run: python3 lz/package.py --cell {cell} --build  (~2 min, terrain is cached)")
    if m.get("lz_planes") != ",".join(C.PLANE_NAMES):
        _fail(f"{cell}: lz_planes {m.get('lz_planes')!r} != {','.join(C.PLANE_NAMES)}")

    try:
        west, south, east, north = [float(x) for x in m["bounds"].split(",")]
    except (KeyError, ValueError):
        _fail(f"{cell}: unusable bounds {m.get('bounds')!r}")

    try:
        vintages = json.loads(m.get("lz_vintages", "{}"))
    except json.JSONDecodeError:
        vintages = {}

    return {
        "id": cell,
        "path": f"{CELL_PREFIX}/{cell}.lzpack",
        # Published so an app can decline a pack it cannot read INSTEAD of downloading 90 MB and
        # rejecting it at mount. Backward compatibility only runs one way — a new app reads an old
        # pack, never the reverse — so a build that predates a schema must be able to see that a
        # cell is out of reach before it spends the bytes.
        "schema": int(m.get("lz_schema", 1)),
        "bytes": os.path.getsize(path),
        "sha256": sha256_of(path),
        # [west, south, east, north] — the SAME order the chart catalog uses, so the app's
        # ChartCatalog.Entry.mapRect geometry and its rect-intersection selection port verbatim.
        "bounds": [west, south, east, north],
        "minzoom": int(m.get("minzoom", C.MIN_ZOOM)),
        "maxzoom": int(m.get("maxzoom", C.NATIVE_ZOOM)),
        "built_at": m.get("built_at", ""),
        # How much of this cell could NOT have its ditch/berm checks run, because only 10 m
        # elevation was available there. Published so the app can tell a pilot where the layer is
        # working with less than it wants, rather than hiding it.
        "coarse_terrain_tiles": int(m.get("lz_terrain_source_coarse_tiles", 0)),
        "vintages": vintages,
        "attribution": m.get("attribution", ""),
    }


def local_packs(only=None):
    """Built packs on disk, id -> path."""
    if not os.path.isdir(OUT_DIR):
        return {}
    found = {}
    for name in sorted(os.listdir(OUT_DIR)):            # bounded by the directory (rule 2)
        if not name.endswith(".lzpack"):
            continue
        # The fixture is a 4-tile toy for XCTest, never a publishable cell.
        if name.startswith("lz_fixture"):
            continue
        cell = name[: -len(".lzpack")]
        if only and cell not in only:
            continue
        found[cell] = os.path.join(OUT_DIR, name)
    return found


# ---------------------------------------------------------------------------------------------
# 3. THE HOSTED SIDE
# ---------------------------------------------------------------------------------------------

def fetch_hosted_index():
    """The live catalog, or None when there isn't one yet. Anonymous — the same request the app
    makes, so a failure here is also a signal about what the app would see."""
    try:
        with urllib.request.urlopen(f"{BASE_URL}/{INDEX_NAME}", timeout=30) as r:
            return json.loads(r.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        return None


def merged_catalog(entries, hosted):
    """New entries win; hosted-only cells are CARRIED FORWARD.

    Publishing one cell must never delete the others from the catalog. The chart pipeline learned
    this the hard way in build_ifr_high_conus.sh, which refuses to publish an index at all when its
    build produced zero packs — because overwriting the catalog with a partial one takes the data
    away from every pilot who already downloaded it."""
    by_id = {}
    if hosted:
        for e in hosted.get("cells", []):
            if isinstance(e, dict) and "id" in e:
                by_id[e["id"]] = e
    for e in entries:
        by_id[e["id"]] = e
    cells = [by_id[k] for k in sorted(by_id)]

    have = {e["id"] for e in cells}
    regions = []
    for r in REGIONS:
        present = [c for c in r["cells"] if c in have]
        if present:                     # a region with nothing published yet is not offered
            regions.append({**r, "cells": present})
    return {"schema": CATALOG_SCHEMA, "regions": regions, "cells": cells}


# ---------------------------------------------------------------------------------------------
# 4. UPLOAD
# ---------------------------------------------------------------------------------------------

def upload(api, local_path, path_in_repo, token):
    """One file. Raises on failure — deliberately unlike the chart uploader."""
    api.upload_file(path_or_fileobj=local_path, path_in_repo=path_in_repo,
                    repo_id=REPO, repo_type=REPO_TYPE, token=token)


def load_done():
    if os.path.exists(DONE_PATH):
        try:
            with open(DONE_PATH) as fh:
                return json.load(fh)
        except json.JSONDecodeError:
            return {}
    return {}


def save_done(done):
    os.makedirs(OUT_DIR, exist_ok=True)
    tmp = DONE_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(done, fh, indent=2, sort_keys=True)
    os.replace(tmp, DONE_PATH)


def assert_new_packs_are_verified(cells, done):
    """Refuse the whole run if any pack being uploaded for the first time has no verify receipt.

    ⚠️ THE GATE HAD NO TEETH. verify.py judged each pack and this script never asked the verdict —
    it uploaded whatever was in lz/out/. When a stage fails, build_cell.sh exits, but the pack
    package.py already wrote STAYS ON DISK looking exactly like a good one. n33w119 and n34w119
    failed their structural gate and were one `--publish` away from every device.

    Scoped to NEW bytes on purpose. A cell already published with this exact sha256 is skipped by
    the uploader anyway, and demanding receipts for the 72 cells built before receipts existed
    would block every future publish over history that cannot be re-verified without a rebuild.
    What matters is that nothing NEW ships ungated.
    """
    missing = []
    for cell, path in sorted(cells.items()):
        sha = sha256_of(path)
        if done.get(cell, {}).get("sha256") == sha:
            continue                                   # unchanged, already live, not a new upload
        rec_path = path + ".verified.json"
        try:
            with open(rec_path) as fh:
                rec = json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError):
            missing.append(f"{cell}: no verify receipt — did `verify.py --cell {cell}` pass?")
            continue
        if rec.get("sha256") != sha:
            missing.append(f"{cell}: receipt is for different bytes "
                           f"({rec.get('sha256', '?')[:12]}… vs {sha[:12]}…) — pack rebuilt since")
    if missing:
        _fail("REFUSING TO PUBLISH — these packs are not vouched for by a passing gate:\n  "
              + "\n  ".join(missing)
              + "\n\nA pack that failed verification stays on disk looking exactly like one that "
                "passed. Rebuild or re-verify before publishing.")


def do_publish(cells, token, force):
    """Upload each pack, then the catalog, then verify. Resumable: a cell whose sha256 matches what
    was published last run is skipped, so an interrupted 9-cell push resumes instead of re-sending
    800 MB."""
    # BEFORE anything is uploaded — a pack in no region is worse than an unpublished one, because
    # it looks published.
    assert_every_pack_has_a_region(cells)
    assert_new_packs_are_verified(cells, load_done())

    from huggingface_hub import HfApi, create_repo     # imported AFTER the Xet export

    if not token:
        _fail("no HF_TOKEN and no ~/.hf_token — a WRITE token is required to publish")

    api = HfApi()
    try:
        create_repo(REPO, repo_type=REPO_TYPE, token=token, exist_ok=True)
    except Exception as e:                              # noqa: BLE001 — report and stop
        _fail(f"could not create/open {REPO}: {e}")

    done = load_done()
    entries, uploaded, skipped = [], [], []
    for cell, path in sorted(cells.items()):
        e = catalog_entry(path)
        entries.append(e)
        if not force and done.get(cell, {}).get("sha256") == e["sha256"]:
            skipped.append(cell)
            print(f"  = {cell}  already published ({e['bytes']/1e6:.1f} MB)")
            continue
        print(f"  ^ {cell}  uploading {e['bytes']/1e6:.1f} MB ...", flush=True)
        try:
            upload(api, path, e["path"], token)
        except Exception as ex:                         # noqa: BLE001
            _fail(f"{cell}: upload failed: {ex}")
        done[cell] = {"sha256": e["sha256"], "bytes": e["bytes"], "path": e["path"]}
        save_done(done)                                 # checkpoint after EVERY file
        uploaded.append(cell)

    # The repo README carries the CC-BY attribution the canopy source REQUIRES, plus the advisory
    # framing. Publishing the data without it would be a licence problem, not just untidy.
    readme = os.path.join(HERE, "HF_README.md")
    if os.path.exists(readme):
        print("  ^ README.md")
        try:
            upload(api, readme, "README.md", token)
        except Exception as ex:                         # noqa: BLE001
            _fail(f"README upload failed: {ex}")

    catalog = merged_catalog(entries, fetch_hosted_index())
    idx_tmp = os.path.join(OUT_DIR, INDEX_NAME)
    with open(idx_tmp, "w") as fh:
        json.dump(catalog, fh, indent=2, sort_keys=True)
    print(f"  ^ {INDEX_NAME}  {len(catalog['cells'])} cells, {len(catalog['regions'])} region(s)")
    try:
        upload(api, idx_tmp, INDEX_NAME, token)
    except Exception as ex:                             # noqa: BLE001
        _fail(f"index.json upload failed: {ex}")

    print(f"\nuploaded {len(uploaded)}, skipped {len(skipped)}")
    return catalog


# ---------------------------------------------------------------------------------------------
# 5. VERIFY — the step that would have caught the Xet outage
# ---------------------------------------------------------------------------------------------

def do_verify(expect_cells=None):
    """Fetch what was published THE WAY THE APP DOES: anonymous, plain HTTP, no HF client.

    urllib sends no Authorization header, so this is genuinely the app's request and not a
    privileged one that happens to work. A Xet-backed object answers 403 here — which is exactly
    the failure that shipped silently once and cost a re-host of every chart pack."""
    catalog = fetch_hosted_index()
    if catalog is None:
        _fail(f"{BASE_URL}/{INDEX_NAME} is not anonymously readable — the app cannot see the catalog")
    cells = catalog.get("cells", [])
    if expect_cells:
        missing = sorted(set(expect_cells) - {c["id"] for c in cells})
        if missing:
            _fail(f"published but absent from the hosted catalog: {', '.join(missing)}")
    print(f"index.json OK — {len(cells)} cell(s)")

    bad = []
    for e in cells:                                     # bounded by the catalog (rule 2)
        url = f"{BASE_URL}/{e['path']}"
        req = urllib.request.Request(url)
        req.add_header("Range", f"bytes=0-{VERIFY_RANGE_BYTES - 1}")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                code, body = r.status, r.read()
        except urllib.error.HTTPError as ex:
            hint = "  <-- XET: re-upload with HF_HUB_DISABLE_XET=1" if ex.code == 403 else ""
            bad.append(f"{e['id']}: HTTP {ex.code}{hint}")
            continue
        except (urllib.error.URLError, OSError) as ex:
            bad.append(f"{e['id']}: {ex}")
            continue
        # A range request must be answered with 206 and the bytes asked for. A 200 here means the
        # server ignored Range and is streaming the whole file — workable, but worth knowing.
        if code not in (200, 206):
            bad.append(f"{e['id']}: HTTP {code}")
        elif body[:4] != b"SQLi":
            # MBTiles is SQLite; the header is "SQLite format 3\0". Anything else means we are
            # reading a Xet pointer, an LFS stub or an HTML error page rather than a pack.
            bad.append(f"{e['id']}: first bytes {body[:16]!r} — not a SQLite file")
        else:
            print(f"  ok {e['id']}  HTTP {code}  {len(body)} bytes")

    if bad:
        for b in bad:
            print(f"  FAIL {b}", file=sys.stderr)
        _fail(f"{len(bad)} of {len(cells)} packs are not fetchable the way the app fetches them")
    print(f"\nall {len(cells)} pack(s) anonymously fetchable — classic LFS confirmed")


# ---------------------------------------------------------------------------------------------
# 6. CLI
# ---------------------------------------------------------------------------------------------

def do_list(cells):
    hosted = fetch_hosted_index()
    hosted_ids = {c["id"] for c in hosted.get("cells", [])} if hosted else set()
    print(f"repo   {REPO}")
    print(f"local  {OUT_DIR}")
    print(f"hosted {len(hosted_ids)} cell(s)" if hosted else "hosted (no catalog yet)")
    print()
    ids = sorted(set(cells) | hosted_ids)
    if not ids:
        print("  nothing built and nothing hosted")
        return
    for cell in ids:
        where = []
        if cell in cells:
            where.append(f"local {os.path.getsize(cells[cell])/1e6:.1f} MB")
        if cell in hosted_ids:
            where.append("hosted")
        print(f"  {cell:10} {' + '.join(where)}")


def main():
    ap = argparse.ArgumentParser(description="Publish LZ fact-tile packs to HuggingFace.")
    ap.add_argument("--list", action="store_true", help="what is built locally vs hosted")
    ap.add_argument("--dry-run", action="store_true", help="build the catalog, upload nothing")
    ap.add_argument("--publish", action="store_true", help="upload packs + index.json, then verify")
    ap.add_argument("--verify", action="store_true", help="verification pass alone, against live")
    ap.add_argument("--cell", action="append", default=None, help="limit to this cell (repeatable)")
    ap.add_argument("--force", action="store_true", help="re-upload even if unchanged")
    args = ap.parse_args()

    if not any([args.list, args.dry_run, args.publish, args.verify]):
        ap.print_help()
        return 0

    cells = local_packs(only=set(args.cell) if args.cell else None)

    if args.list:
        do_list(cells)
        return 0

    if args.dry_run:
        if not cells:
            _fail("no packs in lz/out — build one first (see lz/README.md)")
        catalog = merged_catalog([catalog_entry(p) for p in cells.values()], fetch_hosted_index())
        print(json.dumps(catalog, indent=2, sort_keys=True))
        return 0

    if args.publish:
        if not cells:
            _fail("no packs in lz/out — build one first (see lz/README.md)")
        print(f"publishing {len(cells)} pack(s) to {REPO}  (Xet DISABLED — see the header)\n")
        catalog = do_publish(cells, hf_token(), args.force)
        print("\nverifying as the app would (anonymous, plain HTTP) ...")
        do_verify(expect_cells=list(cells))
        return 0

    if args.verify:
        do_verify()
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
