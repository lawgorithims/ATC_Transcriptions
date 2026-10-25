#!/usr/bin/env python3
"""publish.py — upload built marine region packs to HuggingFace and regenerate the catalog.

WHAT THIS PUBLISHES
    marine/out/<region>.mbtiles  ->  https://huggingface.co/datasets/<REPO>/resolve/main/regions/<region>.mbtiles
    a generated index.json at the repo root, which the app reads to know what exists.

    Its own dataset repo, not a folder inside faa-charts. House style is one repo per content class
    (`lz/publish.py`: "house style is one repo per content class"), and here there are two further
    reasons it is not merely style:
      * `charts/publish_packs.py` hardcodes a family registry (EXPECTED) iterated as the
        authoritative key set in nine places, including exact-equality guards in promote() and the
        --stage-next hosted checks. A fourth family means touching all nine.
      * The chart pipeline's currency maths is FAA 56-DAY CYCLES (ChartCatalog.provenance derives
        expiry as effective + 56 days). NOAA ENC is rebuilt WEEKLY. Forcing marine packs through
        that model would make every one of them mis-report its own currency — and there is no
        cycle roll here, so none of the --stage-next / --promote machinery applies either.

=================================================================================================
THE XET TRAP — READ THIS BEFORE CHANGING ANY UPLOAD CODE
=================================================================================================
HuggingFace migrated large-file storage to Xet, which serves files ONLY via a chunk-reconstruction
protocol. The app fetches packs with a plain anonymous `GET /resolve/main/<path>` and cannot speak
that protocol, so a Xet-backed file answers **403** and the layer silently has no data.

This already happened to the FAA chart packs and cost a full re-host of every one of them
(charts/rehost_classic_lfs.sh). It is not cheaply repairable: Xet dedups by CONTENT HASH, so
pushing identical bytes with Xet disabled merely re-links the existing Xet object — the rehost
script has to mutate every file with a junk metadata row first just to break the hash.

    => The only cheap fix is to never create the Xet object at all.
    => HF_HUB_DISABLE_XET must be set BEFORE huggingface_hub is imported: the library picks its
       storage backend at import time.
    => It is FORCED here, not defaulted, because an inherited HF_HUB_DISABLE_XET=0 would quietly
       reintroduce the bug and the symptom would surface days later as "the layer stopped working".

`charts/build_all_packs.sh` still does not set it. Do not copy that script's upload path.

=================================================================================================
WHY THIS SCRIPT IS NOISY ON FAILURE
=================================================================================================
The chart uploader is `up(){ ... "$HF" upload ... >/dev/null 2>&1 && echo "  up $2"; }` under
`set -uo pipefail` with no `-e`: every error is discarded, only successes print, and a whole run can
report success having uploaded nothing. Here every failure raises, and a run ends with an
INDEPENDENT anonymous verification pass that fetches what was published the way the app would.

USAGE
    python3 marine/publish.py --list                        # built locally vs hosted
    python3 marine/publish.py --dry-run                     # compose the catalog, upload nothing
    python3 marine/publish.py --publish                     # upload packs + index.json, then verify
    python3 marine/publish.py --publish --region puget_sound
    python3 marine/publish.py --verify                      # verification pass alone, against live

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
# Only encspec — NOT build_marine_packs, which imports GDAL at module scope. The publisher has to
# run in the environment that has huggingface_hub, and that environment has no GDAL.
import encspec                      # noqa: E402

# ---------------------------------------------------------------------------------------------
# 1. WHERE THINGS LIVE
# ---------------------------------------------------------------------------------------------

REPO = os.environ.get("MARINE_HF_REPO", "SingularityUS/commsight-marine")
REPO_TYPE = "dataset"
BASE_URL = f"https://huggingface.co/datasets/{REPO}/resolve/main"
REGION_PREFIX = "regions"          # mirrors the charts' sectional/ ifr/ and lz's cells/
INDEX_NAME = "index.json"

# Bumped whenever a pack's SHAPE changes in a way an older app build cannot read. Published in
# every catalog entry so a device can decline a pack it cannot use INSTEAD of spending 170 MB and
# then failing to mount it — the same reasoning as `lz_schema` in LZPack.installable().
MARINE_SCHEMA = 1

# These packs are VECTOR tiles. Every other MBTiles this app has ever mounted is raster, and the
# existing MapLibre path binds MLNRasterTileSource. The catalog states the encoding explicitly so
# that an app build without the vector path refuses the pack rather than mounting it and drawing
# nothing — "absent" is a far better failure than "broken".
TILE_ENCODING = "pbf"

OUT_DIR = os.environ.get("MARINE_OUT", os.path.join(HERE, "out"))
DONE_PATH = os.path.join(OUT_DIR, ".published.json")
REGIONS_CONF = os.path.join(HERE, "regions.conf")

VERIFY_RANGE_BYTES = 1024


def _fail(msg):
    print(f"\n!! {msg}", file=sys.stderr)
    sys.exit(msg)


def hf_token():
    tok = os.environ.get("HF_TOKEN")
    if tok:
        return tok.strip()
    path = os.path.expanduser("~/.hf_token")
    if not os.path.exists(path):
        _fail("no HF_TOKEN in the environment and no ~/.hf_token — a WRITE token is needed to publish")
    mode = os.stat(path).st_mode & 0o777
    if mode & 0o077:
        _fail(f"~/.hf_token is mode {mode:o}; it holds a write credential — chmod 600 it first")
    with open(path) as fh:
        tok = fh.read().strip()
    if not tok:
        _fail("~/.hf_token is empty")
    return tok


# ---------------------------------------------------------------------------------------------
# 2. READING A PACK
# ---------------------------------------------------------------------------------------------

def pack_metadata(path):
    """The pack's own MBTiles metadata table. Everything the catalog needs is already in here,
    written by build_marine_packs.py — so the catalog cannot drift from the artifact it describes."""
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        rows = dict(db.execute("SELECT name, value FROM metadata").fetchall())
        db.close()
        return rows
    except sqlite3.Error as e:
        _fail(f"{os.path.basename(path)}: not readable as MBTiles ({e})")


def pack_tile_stats(path):
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        n, zlo, zhi = db.execute(
            "SELECT count(*), min(zoom_level), max(zoom_level) FROM tiles").fetchone()
        db.close()
        return n or 0, zlo, zhi
    except sqlite3.Error as e:
        _fail(f"{os.path.basename(path)}: tiles table unreadable ({e})")


def sha256_of(path):
    """Streamed so a 171 MB pack does not land in memory."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def catalog_entry(path, labels):
    """One `regions[]` record. Fails rather than publishing a pack the app would refuse to mount.

    Every refusal below is a condition the DEVICE would hit. A pack that ships and then silently
    fails to mount is the worst outcome: the pilot pays 170 MB for nothing and the layer looks
    broken rather than absent."""
    name = os.path.basename(path)[: -len(".mbtiles")]
    m = pack_metadata(path)

    if m.get("format") != TILE_ENCODING:
        _fail(f"{name}: format is {m.get('format')!r}, expected {TILE_ENCODING!r} — "
              f"a raster pack cannot be served through the vector source")

    # Refuse an undated artifact. The vintage is derived from the newest DSID_ISDT among the cells
    # in the pack, so a pack built from a stale ENC download cannot label itself current — but only
    # if it is actually stamped. Publishing an unstamped pack would leave the app with no way to
    # tell a pilot how old their chart is.
    vintage = (m.get("enc_vintage") or "").strip()
    if not (len(vintage) == 8 and vintage.isdigit()):
        _fail(f"{name}: enc_vintage is {m.get('enc_vintage')!r}, expected YYYYMMDD — "
              f"rebuild it; publish refuses an undated artifact")

    try:
        west, south, east, north = [float(x) for x in m["bounds"].split(",")]
    except (KeyError, ValueError):
        _fail(f"{name}: unusable bounds {m.get('bounds')!r}")

    # The bounds claim is what the app selects a pack by, so it must not reach outside the region
    # the pack was cut to. build_marine_packs clips geometry to achieve this; re-check it here
    # because publishing is the last point at which an overstated claim can still be stopped.
    rb = m.get("region_bbox")
    if rb:
        try:
            rw, rs, re_, rn = [float(x) for x in rb.split(",")]
        except ValueError:
            _fail(f"{name}: unusable region_bbox {rb!r}")
        slack = encspec.CLIP_MARGIN_DEG + 1e-6
        if west < rw - slack or south < rs - slack or east > re_ + slack or north > rn + slack:
            _fail(f"{name}: bounds {m['bounds']} reach outside region_bbox {rb} — the app would "
                  f"choose this pack for water it does not chart")

    n_tiles, zlo, zhi = pack_tile_stats(path)
    if not n_tiles:
        _fail(f"{name}: pack contains zero tiles")

    try:
        layers = [L["id"] for L in json.loads(m.get("json", "{}")).get("vector_layers", [])]
    except json.JSONDecodeError:
        _fail(f"{name}: metadata 'json' is not valid JSON — the client cannot build a style from it")
    if not layers:
        _fail(f"{name}: no vector_layers in metadata — nothing for the client to render")

    # A region pack with no cable or bridge layer is not necessarily wrong (a region may genuinely
    # have none), but it is worth stating in the catalog so the client can say "no charted cables
    # in this region" rather than leaving a pilot to read an empty overlay as "no cables here".
    clearance_layers = [L for L in encspec.CLEARANCE_BEARING_LAYERS if L in layers]

    return {
        "id": name,
        "title": labels.get(name, name.replace("_", " ").title()),
        "path": f"{REGION_PREFIX}/{name}.mbtiles",
        "schema": MARINE_SCHEMA,
        "format": TILE_ENCODING,
        "bytes": os.path.getsize(path),
        "sha256": sha256_of(path),
        # [west, south, east, north] — the SAME order the chart and LZ catalogs use, so the app's
        # ChartCatalog.Entry.mapRect geometry and its rect-intersection selection port verbatim.
        "bounds": [west, south, east, north],
        "minzoom": int(m.get("minzoom", zlo if zlo is not None else encspec.MIN_ZOOM)),
        "maxzoom": int(m.get("maxzoom", zhi if zhi is not None else encspec.MAX_ZOOM)),
        # YYYYMMDD of the newest ENC cell in the pack. NOT a 56-day FAA cycle — NOAA reissues ENC
        # weekly, so the app must compute staleness from this date and not from a cycle table.
        "enc_vintage": vintage,
        "enc_cell_count": int(m.get("enc_cell_count", 0) or 0),
        "enc_bands": [int(b) for b in (m.get("enc_bands") or "").split(",") if b.strip().isdigit()],
        "tiles": n_tiles,
        "layers": sorted(layers),
        "clearance_layers": clearance_layers,
        "attribution": m.get("attribution", ""),
        "built_at": m.get("commsight_built", ""),
    }


def region_labels():
    """Pilot-facing titles, read from regions.conf so the catalog and the builder cannot disagree
    about what a region is called."""
    return {r["name"]: r["label"] for r in encspec.load_regions(REGIONS_CONF)}


def local_packs(only=None):
    if not os.path.isdir(OUT_DIR):
        _fail(f"{OUT_DIR} does not exist — build some regions first "
              f"(python3 marine/build_marine_packs.py --help)")
    names = sorted(f[: -len(".mbtiles")] for f in os.listdir(OUT_DIR) if f.endswith(".mbtiles"))
    known = set(region_labels())
    unknown = [n for n in names if n not in known]
    if unknown:
        # A stray .mbtiles in out/ is almost always a rename or a hand-built experiment. Publishing
        # it would put a region in the catalog that regions.conf cannot rebuild.
        _fail(f"{OUT_DIR} holds pack(s) no region defines: {', '.join(unknown)} — "
              f"remove them or add the region to regions.conf")
    if only:
        missing = sorted(set(only) - set(names))
        if missing:
            _fail(f"no built pack for: {', '.join(missing)}")
        names = [n for n in names if n in set(only)]
    if not names:
        _fail(f"no .mbtiles in {OUT_DIR}")
    return [os.path.join(OUT_DIR, f"{n}.mbtiles") for n in names]


# ---------------------------------------------------------------------------------------------
# 3. THE CATALOG
# ---------------------------------------------------------------------------------------------

def _get_json(url, label):
    """(status, parsed-or-None). Raises nothing; callers decide what a status means."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "commsight-publisher"})
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
        try:
            return r.status, json.loads(body.decode())
        except json.JSONDecodeError as ex:
            _fail(f"the hosted {label} is not valid JSON ({ex}). Refusing to overwrite it blind — "
                  f"inspect {url} by hand.")
    except urllib.error.HTTPError as ex:
        return ex.code, None
    except (urllib.error.URLError, OSError) as ex:
        _fail(f"cannot reach {url} ({ex}). Refusing to continue, because a network failure must "
              f"not be read as 'the catalog is empty'.")


def hosted_state():
    """Distinguish "no catalog yet" from "cannot read the catalog". Returns
    ("catalog", obj) | ("empty-repo", None) | ("no-repo", None), or refuses.

    ⚠️ THIS CANNOT BE DECIDED FROM THE index.json STATUS ALONE, and getting it wrong is how a
    live catalog gets deleted. HuggingFace deliberately does not leak repo existence: a dataset
    that does not exist answers **401**, not 404, for every path under it. Measured 2026-10-24:

        repo exists, file present   /api/datasets/<repo> 200   resolve/index.json 206
        repo exists, file ABSENT    /api/datasets/<repo> 200   resolve/index.json 404
        repo absent or invisible    /api/datasets/<repo> 401   resolve/index.json 401

    So a 401 on index.json is ambiguous and must be disambiguated by probing the repo itself. The
    dangerous case — repo present, catalog not anonymously readable — is REFUSED, because if this
    script cannot read the catalog anonymously then neither can the app, and composing a fresh
    index from only what is built locally would take every other region away from every pilot who
    already has it. `publish_nav.py --stage-next` did exactly that once and would have written
    `"datasets": {}` over the live manifest.
    """
    status, catalog = _get_json(f"{BASE_URL}/{INDEX_NAME}", INDEX_NAME)
    if status == 200 and catalog is not None:
        return "catalog", catalog

    repo_status, _ = _get_json(f"https://huggingface.co/api/datasets/{REPO}", "repo metadata")

    if status == 404:
        # The repo is there and simply has no catalog yet — a genuine first publish.
        return "empty-repo", None
    if status in (401, 403):
        if repo_status in (401, 403, 404):
            return "no-repo", None          # nothing exists to overwrite
        _fail(f"{BASE_URL}/{INDEX_NAME} answered HTTP {status} but the dataset {REPO} IS visible "
              f"(HTTP {repo_status}). Refusing to continue: the app fetches the catalog "
              f"anonymously too, so it cannot read it either, and composing a fresh index now "
              f"would delete every hosted region from the catalog every pilot reads. Check the "
              f"dataset's visibility and whether index.json is Xet-backed.")
    _fail(f"{BASE_URL}/{INDEX_NAME} answered HTTP {status}. Refusing to continue: this is not the "
          f"same as 'no catalog yet'.")


def fetch_hosted_index():
    """The live catalog, or None when there genuinely is not one. See hosted_state()."""
    state, catalog = hosted_state()
    return catalog if state == "catalog" else None


def merged_catalog(entries, hosted):
    """New entries win; hosted-only regions are CARRIED FORWARD.

    Publishing one region must never delete the others from the catalog. The chart pipeline learned
    this the hard way in build_ifr_high_conus.sh, which refuses to publish an index at all when its
    build produced zero packs — because overwriting the catalog with a partial one takes the data
    away from every pilot who already downloaded it."""
    by_id = {}
    if hosted:
        for e in hosted.get("regions", []):
            if isinstance(e, dict) and "id" in e:
                by_id[e["id"]] = e
    for e in entries:
        by_id[e["id"]] = e
    regions = [by_id[k] for k in sorted(by_id)]

    vintages = sorted(e["enc_vintage"] for e in regions if e.get("enc_vintage"))
    return {
        "schema": MARINE_SCHEMA,
        "format": TILE_ENCODING,
        # The band -> zoom contract the packs were cut with. Published so a client can reason about
        # what detail to expect at a zoom without hardcoding a copy of encspec.BAND_ZOOM.
        "band_zoom": {str(b): list(z) for b, z in sorted(encspec.BAND_ZOOM.items())},
        "newest_vintage": vintages[-1] if vintages else "",
        "oldest_vintage": vintages[0] if vintages else "",
        "source": "NOAA Office of Coast Survey Electronic Navigational Charts (ENC)",
        "attribution": "Chart data © NOAA / NOS Office of Coast Survey (public domain). "
                       "Not for navigation.",
        "regions": regions,
    }


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


def verify_anonymous(remote_path):
    """Fetch the first KiB exactly the way the app does: plain, anonymous, no token, no Xet client.

    A 403 here is the Xet failure mode; anything that is not SQLite means the app would get a file
    it cannot open."""
    req = urllib.request.Request(f"{BASE_URL}/{remote_path}",
                                 headers={"Range": f"bytes=0-{VERIFY_RANGE_BYTES - 1}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            code, head = r.status, r.read(16)
    except urllib.error.HTTPError as ex:
        hint = "  <-- XET: the app cannot fetch this; re-upload with HF_HUB_DISABLE_XET=1" \
            if ex.code == 403 else ""
        return False, f"HTTP {ex.code}{hint}"
    except Exception as ex:
        return False, f"{type(ex).__name__}: {ex}"
    if code not in (200, 206):
        return False, f"HTTP {code}"
    if not head.startswith(b"SQLite format 3"):
        return False, f"not SQLite (got {head[:16]!r})"
    return True, "ok"


def newest_available_per_region(index_path, regions):
    """{region: newest DSID_ISDT among the cells that region covers}, from enc_index.json."""
    with open(index_path) as fh:
        index = json.load(fh)

    def ov(a, b):
        return not (a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1])

    out = {}
    for r in regions:
        dates = [c["issued"] for c in index["cells"]
                 if c.get("issued") and ov(c["bbox"], r["bbox"])]
        if dates:
            out[r["name"]] = max(dates)
    return out


def check_pack_currency(entries, index_path, regions):
    """Refuse a pack that is older than the data available for its own region.

    ⚠️ A .mbtiles is published on the strength of being in the output directory. The builder now
    removes or quarantines its own bad output, but it cannot know about a pack left behind by an
    EARLIER run of different code, and `local_packs` accepts it because its region is defined.
    That is the hazard charts/build_all_packs.sh is called out for — resuming on "does the output
    file exist" publishes last cycle's data under this cycle's label — and ENC rolls weekly rather
    than every 56 days, so the window to notice is 8x shorter.

    ⚠️ COMPARE AGAINST THE REGION'S OWN NEWEST CELL, NOT AGAINST SIBLING PACKS. The first version
    of this check flagged any pack far behind the newest pack in the same publish, and it was
    provably noisy: 12 of the 43 regions have no cell newer than 2026-10-01 because that is simply
    when NOAA last reissued them. `antarctica`'s newest available cell is 2025-05-13 — 521 days
    old and perfectly current. Vintage spread between regions is real survey currency, not
    staleness, and a guard that cannot tell the difference teaches people to ignore it.
    """
    available = newest_available_per_region(index_path, regions)
    stale = []
    for e in entries:
        want = available.get(e["id"])
        if not want or not e.get("enc_vintage"):
            continue
        if e["enc_vintage"] < want:
            stale.append((e["id"], e["enc_vintage"], want))
    for ident, got, want in stale:
        print(f"  !! {ident}: built from ENC vintage {got}, but {want} is available for that "
              f"region — this pack predates the current chart data", file=sys.stderr)
    if stale:
        _fail(f"{len(stale)} pack(s) are older than the ENC data available for their region. "
              f"Rebuild them (build_marine_packs.py --region ...) or remove them from the output "
              f"directory; publishing them would label stale charts as current.")
    print(f"  currency: all {len(entries)} pack(s) match the newest ENC data for their region")


def do_publish(paths, token, dry_run, force, index_path=None):
    labels = region_labels()
    print(f"composing catalog entries for {len(paths)} pack(s)…")
    entries = [catalog_entry(p, labels) for p in paths]
    for e in entries:
        print(f"  {e['id']:22s} {e['bytes']/1e6:7.1f} MB  z{e['minzoom']}-{e['maxzoom']}  "
              f"{e['tiles']:>8,} tiles  {len(e['layers'])} layers  vintage {e['enc_vintage']}")

    if index_path:
        check_pack_currency(entries, index_path, encspec.load_regions(REGIONS_CONF))
    else:
        print("  (no --index given, so pack currency was not checked against the ENC set — a pack "
              "left over from an older build would be published as-is)")

    state, hosted = hosted_state()
    if state == "no-repo":
        print(f"\nthe dataset {REPO} does not exist yet — --publish will create it")
    elif state == "empty-repo":
        print(f"\n{REPO} exists but has no {INDEX_NAME} yet — this is its first catalog")
    catalog = merged_catalog(entries, hosted)
    carried = len(catalog["regions"]) - len(entries)
    print(f"\ncatalog: {len(entries)} new/updated, {max(0, carried)} carried forward from hosted, "
          f"{len(catalog['regions'])} total")

    if dry_run:
        out = os.path.join(OUT_DIR, "index.dry-run.json")
        with open(out, "w") as fh:
            json.dump(catalog, fh, indent=2, sort_keys=True)
        print(f"--dry-run: wrote {out}, uploaded nothing")
        return 0

    from huggingface_hub import HfApi          # imported late; see the XET header
    api = HfApi()
    if state == "no-repo":
        # Explicit, and only on a real --publish: creating a public dataset repo is outward-facing.
        print(f"  + creating dataset {REPO}")
        api.create_repo(repo_id=REPO, repo_type=REPO_TYPE, token=token, exist_ok=True,
                        private=False)
    done = load_done()

    # Packs first, index LAST. A catalog that names a pack which is not yet uploaded would have
    # every device fetch a 404; the reverse — an uploaded pack not yet in the catalog — is simply
    # invisible until the index lands, which is harmless.
    for e, path in zip(entries, paths):
        prev = done.get(e["id"], {})
        if prev.get("sha256") == e["sha256"] and not force:
            print(f"  = {e['id']} unchanged (sha256 match) — skipped")
            continue
        print(f"  ↑ {e['id']}  {e['bytes']/1e6:.1f} MB")
        upload(api, path, e["path"], token)
        ok, why = verify_anonymous(e["path"])
        if not ok:
            _fail(f"{e['id']} uploaded but is not anonymously fetchable: {why}. "
                  f"The index has NOT been updated, so no device will be pointed at it.")
        print(f"    verified anonymously: {why}")
        done[e["id"]] = {"sha256": e["sha256"], "bytes": e["bytes"],
                         "enc_vintage": e["enc_vintage"], "built_at": e["built_at"]}
        save_done(done)

    index_local = os.path.join(OUT_DIR, INDEX_NAME)
    with open(index_local, "w") as fh:
        json.dump(catalog, fh, indent=2, sort_keys=True)
    print(f"  ↑ {INDEX_NAME}")
    upload(api, index_local, INDEX_NAME, token)

    print()
    return do_verify(expect=[e["id"] for e in entries])


def do_verify(expect=None):
    """Fetch what was published THE WAY THE APP DOES: anonymous, plain HTTP, no HF client."""
    state, catalog = hosted_state()
    if state != "catalog":
        _fail(f"no catalog is hosted at {BASE_URL}/{INDEX_NAME} yet "
              f"({'the dataset does not exist' if state == 'no-repo' else 'the dataset is empty'})"
              f" — publish something first")
    regions = catalog.get("regions", [])
    if expect:
        missing = sorted(set(expect) - {r["id"] for r in regions})
        if missing:
            _fail(f"published but absent from the hosted catalog: {', '.join(missing)}")
    print(f"{INDEX_NAME} OK — {len(regions)} region(s), newest vintage "
          f"{catalog.get('newest_vintage') or '?'}")

    bad = []
    for e in regions:
        ok, why = verify_anonymous(e["path"])
        if ok:
            print(f"  ok {e['id']:22s} {why}")
        else:
            bad.append(f"{e['id']}: {why}")
    if bad:
        for b in bad:
            print(f"  FAIL {b}", file=sys.stderr)
        _fail(f"{len(bad)} of {len(regions)} packs are not fetchable the way the app fetches them")
    print(f"\nall {len(regions)} pack(s) anonymously fetchable — classic LFS confirmed")
    return 0


def do_list(paths):
    labels = region_labels()
    state, hosted = hosted_state()
    hosted_by_id = {r["id"]: r for r in (hosted or {}).get("regions", [])}
    if state != "catalog":
        print(f"({REPO}: {'dataset does not exist yet' if state == 'no-repo' else 'no catalog yet'})\n")
    done = load_done()
    print(f"{'region':22s} {'local MB':>9} {'vintage':>9}  {'hosted':>9} {'hosted vintage':>14}  state")
    for p in paths:
        name = os.path.basename(p)[: -len(".mbtiles")]
        m = pack_metadata(p)
        h = hosted_by_id.get(name)
        local_sha = done.get(name, {}).get("sha256")
        if h is None:
            state = "NOT PUBLISHED"
        elif local_sha and h.get("sha256") == local_sha:
            state = "in sync"
        else:
            state = "differs — needs --publish"
        print(f"{name:22s} {os.path.getsize(p)/1e6:9.1f} {m.get('enc_vintage','?'):>9}  "
              f"{(h['bytes']/1e6 if h else 0):9.1f} {(h.get('enc_vintage','-') if h else '-'):>14}  {state}")
    only_hosted = sorted(set(hosted_by_id) - {os.path.basename(p)[:-8] for p in paths})
    if only_hosted:
        print(f"\nhosted but not built locally (will be carried forward): {', '.join(only_hosted)}")
    unbuilt = sorted(set(labels) - {os.path.basename(p)[: -len('.mbtiles')] for p in paths}
                     - set(hosted_by_id))
    if unbuilt:
        print(f"\ndefined in regions.conf but never built ({len(unbuilt)}): {', '.join(unbuilt)}")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--list", action="store_true", help="what is built locally vs what is hosted")
    g.add_argument("--dry-run", action="store_true", help="compose the catalog, upload nothing")
    g.add_argument("--publish", action="store_true", help="upload packs + index.json, then verify")
    g.add_argument("--verify", action="store_true", help="verification pass alone, against live")
    ap.add_argument("--region", action="append", help="limit to this region (repeatable)")
    ap.add_argument("--index", help="enc_index.json — checks each pack is not older than the ENC "
                                    "data available for its region")
    ap.add_argument("--force", action="store_true",
                    help="re-upload a pack whose sha256 already matches what was published")
    args = ap.parse_args(argv)

    if args.verify:
        return do_verify()
    paths = local_packs(args.region)
    if args.list:
        return do_list(paths)
    token = None if args.dry_run else hf_token()
    return do_publish(paths, token, args.dry_run, args.force, args.index)


if __name__ == "__main__":
    sys.exit(main())
