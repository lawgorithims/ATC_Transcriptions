#!/usr/bin/env python3
"""fetch.py — source adapters for the LZ pipeline: probe, fetch, and prove coverage.

WHAT IT MAKES
    lz/data/<cell>/<source>/...      the materialised inputs
    lz/data/<cell>/manifest.json     provenance for every source: url, sha256, bytes, vintage,
                                     coverage, status. The pack's metadata row is built from this,
                                     so "where did this byte come from" is answerable after the fact.

THE THREE VERBS
    probe()           — a CHEAP version token (ETag, release id, cycle date, API count). No payload.
                        Sources here cannot be subscribed to; we poll. Probing must not cost a
                        gigabyte to discover that nothing changed.
    fetch()           — materialise or resolve. See MATERIALISED vs STREAMED below.
    assert_coverage() — prove the artifact actually covers the cell and is READABLE.

WHY assert_coverage EXISTS (this is not paperwork)
    If a source moves, changes schema, or 404s and the pipeline quietly emits an empty layer, the
    app renders that as "no wires here" — the worst output this product can produce. A missing
    source must BREAK THE BUILD, not thin the hazard plane.

    This is not hypothetical. While building this adapter, the obvious-looking MRLC S3 key
    `mrlc/Annual_NLCD_LndCov_2023_CU_C1V0.tif` returned **HTTP 200 with a 42-byte body**: a valid
    little-endian TIFF header, width and height both 0xFFFFFFFF, and no image directory at all.
    Every status-code check in the world passes that. GDAL refuses to open it. So coverage checks
    OPEN the data, they do not trust the transport.

MATERIALISED vs STREAMED
    Two kinds of source, deliberately:
      MATERIALISED — downloaded to disk (vectors, small rasters, anything we re-read many times).
      STREAMED     — resolved to a LIST OF URLS recorded in the manifest, read later through GDAL's
                     /vsicurl/. 3DEP 1 m is 155 tiles x ~198 MB = ~30 GB for this one cell; the
                     tiles are LZW GeoTIFFs with `Accept-Ranges: bytes` and internal overviews, so
                     the terrain stage streams them and never stores them. Disk cost stays at the
                     size of the 10 m OUTPUT, which is a few hundred MB.

A NOTE ON 3DEP AND WHY THE TERRAIN STAGE READS NATIVE 1 m
    Do not be tempted to warp the DEM to 10 m here and hand terrain.py a tidy grid. Detrended
    roughness and micro-relief are DEFINED as sub-10 m variation; resampling to 10 m first destroys
    exactly the signal they measure and yields a smooth, confident, wrong answer. fetch.py's job is
    to resolve 1 m sources; terrain.py reduces from native resolution.

CELL COVERAGE NOTE — n33w107
    3DEP 1 m covers 100% of this cell, from SIX projects with vintages 2014-2020
    (NM_SouthEast_2018_D19, NM_SouthCentral_2018_D19, NM_WhiteSandsNM_2020_D20, TX_DesertMountains_2018_D19,
    TX_RioGrand_FTWhit_2014, NM_WhiteSands_2015). Good: the multi-vintage seam case is exercised.
    Bad: the COARSE-DEM cap is NOT exercised anywhere in this cell, so the test fixture has to
    carry a coarse tile or that safety rule ships untested.

USAGE
    python3 lz/fetch.py --list
    python3 lz/fetch.py --probe                       # cheap: no payloads
    python3 lz/fetch.py --fetch [--source dof ...]
    python3 lz/fetch.py --assert-coverage             # non-zero exit if a required source is short
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzcommon as C  # noqa: E402

UA = "CommSight-LZ/1.0 (+https://flycommsight.com) python-urllib"
HTTP_TIMEOUT = 120
MAX_RETRIES = 3
RETRY_BACKOFF_S = 4

TNM_API = "https://tnmaccess.nationalmap.gov/api/v1/products"
SB_ITEM = "https://www.sciencebase.gov/catalog/item/{}?format=json"
SB_KIDS = "https://www.sciencebase.gov/catalog/items?parentId={}&format=json&max=60"
# The Annual NLCD Collection 1 parent on ScienceBase. Children are resolved BY TITLE at probe time
# rather than hardcoded: this product went 1.0 -> 1.1 -> 1.2 inside two years and a pinned child id
# silently keeps building last year's land cover.
SB_ANNUAL_NLCD_PARENT = "655ceb8ad34ee4b6e05cc51a"

STATUS_OK = "ok"
STATUS_STREAM = "stream"
STATUS_MISSING = "missing"
STATUS_STALE_FROZEN = "frozen"


# ---------------------------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------------------------

def _req(url, method="GET", headers=None):
    h = {"User-Agent": UA}
    h.update(headers or {})
    return urllib.request.Request(url, method=method, headers=h)


# Statuses worth trying again. Everything else — 400, 403, 404 — is the server telling us something
# true about the request, and hammering it wastes the retry budget on an answer that will not change.
RETRYABLE_STATUS = {408, 425, 429, 500, 502, 503, 504}

# How long an UNATTENDED run will ride out a federal API being down, set by --patience. Measured
# reason for existing: The National Map returned 504 to every query shape for a sustained period
# mid-build (2026-08-02), after the same queries had succeeded twenty minutes earlier. Eight cells
# is eight chances to meet that, and a build that aborts at 2 a.m. because a government gateway
# hiccuped is a build nobody can leave running.
PATIENCE_S = 0.0
BACKOFF_CAP_S = 120.0


def _retryable(e):
    if isinstance(e, urllib.error.HTTPError):
        return e.code in RETRYABLE_STATUS
    return isinstance(e, (urllib.error.URLError, TimeoutError, ConnectionError, OSError,
                          json.JSONDecodeError))


def http_json(url):
    """GET + parse, retrying transient failures with exponential backoff.

    Retries for at least MAX_RETRIES attempts, and then keeps going until PATIENCE_S has elapsed if
    the caller asked for patience. A terminal status (4xx that is not 408/425/429) raises at once —
    waiting out a 404 only delays the truth."""
    deadline = time.monotonic() + PATIENCE_S
    attempt = 0
    while True:
        try:
            with urllib.request.urlopen(_req(url), timeout=HTTP_TIMEOUT) as r:
                return json.load(r)
        except Exception as e:                                   # noqa: BLE001 — re-raised below
            attempt += 1
            if not _retryable(e):
                raise
            more = attempt < MAX_RETRIES or time.monotonic() < deadline
            if not more:
                raise
            # Exponential, capped, so a long patience window does not become a tight loop.
            delay = min(RETRY_BACKOFF_S * (2 ** (attempt - 1)), BACKOFF_CAP_S)
            if PATIENCE_S > 0:
                left = max(0.0, deadline - time.monotonic())
                print(f"     retry {attempt} in {delay:.0f}s ({left/60:.0f} min patience left): {e}",
                      flush=True)
            time.sleep(delay)


def http_version_token(url):
    """A cheap probe: ETag / Last-Modified / Content-Length without pulling the body.

    Some CDNs refuse HEAD, so this falls back to a 1-byte ranged GET — still free."""
    assert url, "http_version_token: empty url"
    try:
        with urllib.request.urlopen(_req(url, "HEAD"), timeout=HTTP_TIMEOUT) as r:
            info = r.headers
    except Exception:
        try:
            with urllib.request.urlopen(_req(url, headers={"Range": "bytes=0-0"}),
                                        timeout=HTTP_TIMEOUT) as r:
                info = r.headers
        except Exception as e:
            return {"status": "unreachable", "error": str(e)[:120]}
    return {"status": "reachable",
            "etag": (info.get("ETag") or "").strip('"') or None,
            "last_modified": info.get("Last-Modified"),
            "bytes": int(info.get("Content-Length") or 0) or None}


def download(url, dest, expect_min_bytes=1024):
    """Stream to disk with a size floor. Resumes by skipping an already-complete file.

    expect_min_bytes is the cheap half of the stub-detection story: a 42-byte "GeoTIFF" dies here
    before it ever reaches a reader. The expensive half is assert_coverage opening it."""
    assert expect_min_bytes > 0, "download: nonsensical size floor"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest) >= expect_min_bytes:
        return dest, False
    tmp = dest + ".part"
    for attempt in range(MAX_RETRIES):
        try:
            with urllib.request.urlopen(_req(url), timeout=HTTP_TIMEOUT) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            break
        except Exception:
            if os.path.exists(tmp):
                os.remove(tmp)
            if attempt == MAX_RETRIES - 1:
                raise
            time.sleep(RETRY_BACKOFF_S * (attempt + 1))
    n = os.path.getsize(tmp)
    if n < expect_min_bytes:
        os.remove(tmp)
        raise RuntimeError(f"{url} returned {n} B, below the {expect_min_bytes} B floor "
                           f"— treat as a stub, not a file")
    os.replace(tmp, dest)
    return dest, True


def sha256_of(path, cap_bytes=256 << 20):
    """Hash the file, or its first cap_bytes for very large ones (recorded as a prefix hash).

    A prefix hash still detects the realistic failure — a truncated or replaced download — without
    spending minutes re-reading 30 GB on every run."""
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            n += len(chunk)
            if n >= cap_bytes:
                return f"sha256-prefix{cap_bytes}:{h.hexdigest()}"
    return f"sha256:{h.hexdigest()}"


def gdal_can_open(path_or_vsi):
    """Open the dataset for real. This is what catches a 200-OK stub."""
    exe = shutil.which("gdalinfo")
    if not exe:
        return False, "gdalinfo not on PATH"
    r = subprocess.run([exe, "-json", path_or_vsi], capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        return False, (r.stderr or "gdalinfo failed").strip().splitlines()[0][:160]
    try:
        j = json.loads(r.stdout)
    except json.JSONDecodeError:
        return False, "gdalinfo emitted no JSON"
    size = j.get("size") or [0, 0]
    if size[0] <= 0 or size[1] <= 0 or size[0] > 10_000_000 or size[1] > 10_000_000:
        return False, f"implausible raster size {size}"
    return True, f"{size[0]}x{size[1]}"


def ogr_feature_count(path, where=None):
    exe = shutil.which("ogrinfo")
    if not exe:
        return None
    cmd = [exe, "-ro", "-so", "-al", path]
    if where:
        cmd += ["-where", where]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        return None
    total = 0
    for line in r.stdout.splitlines():
        if line.strip().startswith("Feature Count:"):
            total += int(line.split(":")[1].strip())
    return total


# ---------------------------------------------------------------------------------------------
# Adapter base
# ---------------------------------------------------------------------------------------------

class Source:
    name = "?"
    title = "?"
    licence = "public domain (US Gov)"
    required = True          # a missing required source fails the build
    quarantined = False      # ODbL: may never be read by hazard.py

    def dir(self):
        return C.cell_dir(os.path.join(C.DATA_DIR, C.CELL_ID), ".")  # placeholder, overridden below

    def path(self, *parts):
        d = os.path.join(C.DATA_DIR, C.CELL_ID, self.name)
        os.makedirs(d, exist_ok=True)
        return os.path.join(d, *parts) if parts else d

    def probe(self):
        raise NotImplementedError

    def fetch(self):
        raise NotImplementedError

    def assert_coverage(self):
        raise NotImplementedError

    def _record(self, **kw):
        kw.setdefault("licence", self.licence)
        kw.setdefault("quarantined", self.quarantined)
        return C.record_source(self.name, **kw)


# ---------------------------------------------------------------------------------------------
# T1 — 3DEP elevation (STREAMED)
# ---------------------------------------------------------------------------------------------

class Dem3DEP(Source):
    name = "dem_3dep"
    title = "USGS 3DEP elevation (1 m where flown, 1/3 arc-second fallback)"
    DS_1M = "Digital Elevation Model (DEM) 1 meter"
    DS_13 = "National Elevation Dataset (NED) 1/3 arc-second"
    # A real 1 m tile for this cell is ~198 MB; anything tiny is a stub or an error page.
    MIN_TILE_BYTES = 1 << 20

    def _query(self, dataset, mx=1000):
        bbox = f"{C.CELL_LON_MIN},{C.CELL_LAT_MIN},{C.CELL_LON_MAX},{C.CELL_LAT_MAX}"
        u = (f"{TNM_API}?datasets={urllib.parse.quote(dataset)}&bbox={bbox}"
             f"&max={mx}&outputFormat=JSON")
        return http_json(u) or {"items": []}

    def probe(self):
        d = self._query(self.DS_1M, mx=1)
        return {"status": "reachable", "tnm_total_1m": d.get("total")}

    def fetch(self):
        """Resolve to a URL list. Nothing is downloaded — see MATERIALISED vs STREAMED."""
        items = self._query(self.DS_1M).get("items", [])
        tiles, projects, vintages = [], set(), set()
        for it in items:
            url = it.get("downloadURL") or ""
            if not url.endswith(".tif"):
                continue
            proj = url.split("/Projects/")[1].split("/")[0] if "/Projects/" in url else "?"
            projects.add(proj)
            if it.get("publicationDate"):
                vintages.add(str(it["publicationDate"])[:4])
            tiles.append({"url": url, "project": proj, "bbox": it.get("boundingBox")})
        cov = self._coverage_pct(tiles)

        # The 1/3 arc-second tile is the documented fallback wherever 1 m is absent. Resolve it
        # even at 100% 1 m coverage: it is how terrain.py fills a hole if a stream read fails.
        fb = []
        for it in self._query(self.DS_13).get("items", []):
            u = it.get("downloadURL") or ""
            if u.endswith(".tif") and "/current/" in u:
                fb.append(u)
        if not fb:
            fb = [f"https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current/"
                  f"{C.CELL_ID}/USGS_13_{C.CELL_ID}.tif"]

        with open(self.path("tiles_1m.json"), "w") as f:
            json.dump({"tiles": tiles, "fallback_13": sorted(set(fb))}, f, indent=2)
        self._record(status=STATUS_STREAM, url=TNM_API, tiles_1m=len(tiles),
                     projects=sorted(projects), vintage=sorted(vintages),
                     coverage_pct=round(cov, 2), fallback_13=sorted(set(fb)),
                     note="streamed via /vsicurl; never materialised")
        # `fallback_13` is REPORTED, not just recorded. Without it the caller sees coverage_pct 0
        # and concludes the cell is empty — but a cell with no 1 m lidar and a working 1/3
        # arc-second tile is entirely buildable, just coarse throughout, which is precisely what the
        # terrain_source cap exists for. Large parts of the rural west have no lidar at all.
        return {"tiles": len(tiles), "coverage_pct": round(cov, 2), "projects": len(projects),
                "fallback_13": len(fb)}

    @staticmethod
    def _coverage_pct(tiles, n=600):
        """Union of tile footprints over the cell, as a percentage. Drives terrain_source."""
        try:
            import numpy as np
        except ImportError:
            return 0.0
        lons = np.linspace(C.CELL_LON_MIN, C.CELL_LON_MAX, n)
        lats = np.linspace(C.CELL_LAT_MIN, C.CELL_LAT_MAX, n)
        LO, LA = np.meshgrid(lons, lats)
        hit = np.zeros((n, n), bool)
        for t in tiles:
            b = t.get("bbox") or {}
            if not b:
                continue
            hit |= ((LO >= b["minX"]) & (LO <= b["maxX"]) & (LA >= b["minY"]) & (LA <= b["maxY"]))
        return float(hit.mean() * 100.0)

    def assert_coverage(self):
        p = self.path("tiles_1m.json")
        if not os.path.exists(p):
            return False, "not resolved — run --fetch"
        with open(p) as f:
            d = json.load(f)
        tiles = d.get("tiles", [])
        if not tiles:
            return False, "no 1 m tiles resolved"
        cov = self._coverage_pct(tiles)
        # Open the first and last tile for real. A resolved URL list that cannot be READ is the
        # 42-byte-stub failure wearing a different hat.
        for probe_tile in (tiles[0], tiles[-1]):
            ok, why = gdal_can_open("/vsicurl/" + probe_tile["url"])
            if not ok:
                return False, f"stream read failed ({probe_tile['project']}): {why}"
        if cov < 99.0:
            fb = d.get("fallback_13") or []
            if not fb:
                return False, f"1 m covers {cov:.1f}% and no 1/3 arc-second fallback resolved"
            return True, f"1 m {cov:.1f}% + 1/3 arc-second fallback (tiles will be MIXED/COARSE)"
        return True, f"1 m {cov:.1f}% of cell, {len(tiles)} tiles streamable"


# ---------------------------------------------------------------------------------------------
# T3 — Annual NLCD land cover (+ optional confidence)
# ---------------------------------------------------------------------------------------------

class AnnualNLCD(Source):
    name = "nlcd"
    title = "Annual NLCD Collection 1 land cover (CONUS)"
    # CONUS-wide, so cached OUTSIDE the per-cell dir — one download serves every future cell.
    SHARED = os.path.join(C.DATA_DIR, "_shared")
    MIN_BYTES = 100 << 20

    def _resolve(self):
        """Find the newest Collection-1.x CONUS 'Land Cover' item and its most recent year zip.

        Resolved by TITLE, never by pinned id: this product went 1.0 -> 1.1 -> 1.2 within two years
        and a hardcoded child id silently keeps building last year's land cover."""
        kids = http_json(SB_KIDS.format(SB_ANNUAL_NLCD_PARENT)).get("items", [])
        best = None
        for k in kids:
            t = k["title"]
            if "Conterminous" not in t or not t.rstrip().endswith("Land Cover"):
                continue
            ver = t.split("Collection")[1].split("Land Cover")[0].strip() if "Collection" in t else "0"
            try:
                vnum = float(ver)
            except ValueError:
                vnum = 0.0
            if best is None or vnum > best[0]:
                best = (vnum, k["id"], t)
        if not best:
            return None
        item = http_json(SB_ITEM.format(best[1]))
        years = []
        for f in item.get("files", []):
            n = f.get("name", "")
            if n.startswith("Annual_NLCD_LndCov_") and n.endswith(".zip"):
                try:
                    years.append((int(n.split("_")[3]), n, f.get("downloadUri"), f.get("size", 0)))
                except (IndexError, ValueError):
                    continue
        if not years:
            return None
        years.sort()
        y, nm, uri, size = years[-1]
        # Do NOT use the item's `downloadUri`. For S3-backed files (pathOnDisk == "__s3__") that
        # endpoint serves the ScienceBase manager SPA — HTTP 200, content-type text/html, ~4 kB of
        # JavaScript. Only the size floor in download() distinguishes it from a real 1.4 GB zip.
        # The by-name catalog endpoint returns the actual archive.
        direct = (f"https://www.sciencebase.gov/catalog/file/get/{best[1]}"
                  f"?name={urllib.parse.quote(nm)}")
        return {"collection": best[2], "year": y, "file": nm, "url": direct,
                "manager_uri": uri, "bytes": size}

    def probe(self):
        r = self._resolve()
        if not r:
            return {"status": "unreachable", "error": "could not resolve an Annual NLCD item"}
        return {"status": "reachable", "collection": r["collection"], "year": r["year"],
                "file": r["file"], "bytes": r["bytes"]}

    def fetch(self):
        r = self._resolve()
        if not r:
            raise RuntimeError("Annual NLCD: no resolvable CONUS Land Cover product")
        os.makedirs(self.SHARED, exist_ok=True)
        dest = os.path.join(self.SHARED, r["file"])
        path, did = download(r["url"], dest, expect_min_bytes=self.MIN_BYTES)
        self._record(status=STATUS_OK, url=r["url"], file=r["file"], vintage=str(r["year"]),
                     collection=r["collection"], bytes=os.path.getsize(path),
                     sha256=sha256_of(path), local=path,
                     note="CONUS-wide, cached in data/_shared and clipped per cell")
        return {"file": r["file"], "downloaded": did}

    @staticmethod
    def vsi_path(zip_path):
        """/vsizip must address the .tif INSIDE the archive, not the archive itself."""
        import zipfile
        with zipfile.ZipFile(zip_path) as z:
            tifs = [n for n in z.namelist() if n.lower().endswith(".tif")]
        if not tifs:
            return None
        return f"/vsizip/{os.path.abspath(zip_path)}/{tifs[0]}"

    def assert_coverage(self):
        m = C.load_manifest()["sources"].get(self.name, {})
        local = m.get("local")
        if not local or not os.path.exists(local):
            return False, "not fetched"
        vsi = self.vsi_path(local)
        if not vsi:
            return False, "no .tif inside the land-cover archive"
        # Open the raster for real. This is the check that catches the 42-byte stub TIFF that
        # MRLC's S3 key serves with HTTP 200, and the 4 kB HTML SPA that ScienceBase's
        # manager/download endpoint serves in place of a 1.4 GB archive.
        ok, why = gdal_can_open(vsi)
        if not ok:
            return False, f"unreadable land-cover raster: {why}"
        return True, f"land cover readable ({why}), vintage {m.get('vintage')}"


# ---------------------------------------------------------------------------------------------
# T5 — Meta/WRI canopy height v2 (CC-BY-4.0)
# ---------------------------------------------------------------------------------------------

class CanopyMeta(Source):
    name = "canopy"
    title = "Meta/WRI Global Canopy Height v2 (1 m)"
    licence = "CC-BY-4.0 (attribution required)"
    BUCKET = "https://dataforgood-fb-data.s3.amazonaws.com"
    CHM = "forests/v2/global/dinov3_global_chm_v2_ml3/chm/"
    QUAD_ZOOM = 10          # the bucket's tiling: every key is a 10-digit quadkey

    @staticmethod
    def quadkey(x, y, z):
        """Bing/Meta quadkey for an XYZ tile."""
        assert 0 < z <= 24, "quadkey: zoom out of range"
        out = []
        for i in range(z, 0, -1):
            d, m = 0, 1 << (i - 1)
            if x & m:
                d += 1
            if y & m:
                d += 2
            out.append(str(d))
        return "".join(out)

    def _cell_keys(self):
        """The keys this cell needs, COMPUTED — not discovered by listing.

        Listing is the wrong tool here: the bucket holds far more than one page, S3 returns keys
        lexicographically, and this cell's keys start 0231... while the first page stops in
        0013... . An adapter that listed one page found zero matches and reported success."""
        return sorted({self.CHM + self.quadkey(x, y, self.QUAD_ZOOM) + ".tif"
                       for x, y in C.cell_tiles(self.QUAD_ZOOM)})

    def _head(self, key):
        try:
            with urllib.request.urlopen(_req(f"{self.BUCKET}/{key}", "HEAD"),
                                        timeout=HTTP_TIMEOUT) as r:
                return int(r.headers.get("Content-Length") or 0)
        except Exception:
            return 0

    def probe(self):
        keys = self._cell_keys()
        n = self._head(keys[0])
        return {"status": "reachable" if n else "unreachable",
                "keys_needed": len(keys), "first_key_bytes": n}

    def fetch(self):
        """Canopy tiles are COGs; recorded as STREAMED like 3DEP. The vintage matters more than
        the bytes: v2's source imagery is 2016, so by 2026 this is a ~10-year-old MINIMUM height.
        Trees grew; the surface stage must treat it as a floor, never as truth."""
        present, missing, total = [], [], 0
        for k in self._cell_keys():
            n = self._head(k)
            (present if n else missing).append(k)
            total += n
        with open(self.path("keys.json"), "w") as f:
            json.dump({"bucket": self.BUCKET, "keys": present, "missing": missing}, f, indent=2)
        self._record(status=STATUS_STREAM, url=self.BUCKET + "/" + self.CHM,
                     keys=len(present), missing=len(missing), bytes=total,
                     vintage="2016 (source imagery)",
                     attribution="Canopy height: Meta/WRI, CC-BY-4.0",
                     note="treat as MINIMUM canopy height; ~10 yr of unmodelled growth")
        return {"present": len(present), "missing": len(missing),
                "MB": round(total / 1e6, 1)}

    def assert_coverage(self):
        p = self.path("keys.json")
        if not os.path.exists(p):
            return False, "not resolved — run --fetch"
        with open(p) as f:
            d = json.load(f)
        present, missing = d.get("keys", []), d.get("missing", [])
        if not present:
            return False, ("no canopy tiles resolved for this cell — the surface stage would "
                           "silently treat every forest as open ground")
        if missing:
            return True, f"{len(present)} canopy tiles, {len(missing)} absent (land cover fills in)"
        return True, f"all {len(present)} canopy tiles covering the cell are present"


# ---------------------------------------------------------------------------------------------
# O1 — FAA Digital Obstacle File
# ---------------------------------------------------------------------------------------------

class FaaDOF(Source):
    name = "dof"
    title = "FAA Digital Obstacle File (daily)"
    URL = "https://aeronav.faa.gov/Obst_Data/DAILY_DOF_DAT.ZIP"
    MIN_BYTES = 1 << 20

    def probe(self):
        return http_version_token(self.URL)

    def fetch(self):
        dest = self.path("DAILY_DOF_DAT.ZIP")
        path, did = download(self.URL, dest, expect_min_bytes=self.MIN_BYTES)
        self._record(status=STATUS_OK, url=self.URL, bytes=os.path.getsize(path),
                     sha256=sha256_of(path), local=path,
                     vintage=time.strftime("%Y-%m-%d", time.gmtime(os.path.getmtime(path))))
        return {"downloaded": did}

    def assert_coverage(self):
        m = C.load_manifest()["sources"].get(self.name, {})
        local = m.get("local")
        if not local or not os.path.exists(local):
            return False, "not fetched"
        import zipfile
        try:
            with zipfile.ZipFile(local) as z:
                names = z.namelist()
                dat = [n for n in names if n.upper().endswith(".DAT")]
                if not dat:
                    return False, f"no .DAT inside DOF zip (saw {names[:4]})"
                # DOF is fixed-width; the NM file must exist and be non-trivial.
                nm = [n for n in dat if os.path.basename(n).upper().startswith(("NM", "34-NM"))]
                probe_name = nm[0] if nm else dat[0]
                with z.open(probe_name) as fh:
                    lines = sum(1 for _ in fh)
                if lines < 100:
                    return False, f"{probe_name} has only {lines} rows — suspect truncation"
        except zipfile.BadZipFile:
            return False, "not a valid zip"
        return True, f"{len(dat)} DAT file(s), {lines} rows in {os.path.basename(probe_name)}"


# ---------------------------------------------------------------------------------------------
# O2 — HIFLD transmission, FROZEN (upstream discontinued 2025)
# ---------------------------------------------------------------------------------------------

class HifldFrozen(Source):
    name = "hifld_tx"
    title = "HIFLD electric transmission lines (frozen public-domain snapshot)"
    required = False

    def _local(self):
        if not os.path.isdir(C.STATIC_DIR):
            return None
        for fn in sorted(os.listdir(C.STATIC_DIR)):
            if fn.startswith("hifld_transmission") and fn.endswith((".geojson", ".json", ".zip")):
                return os.path.join(C.STATIC_DIR, fn)
        return None

    def probe(self):
        """Deliberately never touches the network.

        HIFLD Open was withdrawn 2025-08-25/26 and the site went down 2025-09-16. There is no live
        public feed to poll, and EIA's Atlas layer is not an independent replacement — EIA re-hosts
        HIFLD and says so. The adapter therefore reports FROZEN, and the distinction between
        'unchanged because stable' and 'unchanged because dead' stays visible in the manifest
        instead of being laundered into a fresh-looking timestamp."""
        p = self._local()
        return {"status": STATUS_STALE_FROZEN, "local": p,
                "upstream": "discontinued 2025-09-16 (HIFLD Open withdrawn)",
                "present": bool(p)}

    def fetch(self):
        p = self._local()
        if not p:
            self._record(status=STATUS_MISSING, url=None, vintage=None,
                         note="no frozen snapshot in lz/static/ — hazard plane will carry DOF + "
                              "heuristics only, and the pack metadata must say so")
            return {"present": False}
        vintage = "unknown"
        for tok in os.path.basename(p).replace(".", "_").split("_"):
            if len(tok) == 8 and tok.isdigit():
                vintage = f"{tok[:4]}-{tok[4:6]}-{tok[6:]}"
        self._record(status=STATUS_STALE_FROZEN, url="frozen snapshot (upstream discontinued)",
                     local=p, bytes=os.path.getsize(p), sha256=sha256_of(p), vintage=vintage,
                     note="FIXED VINTAGE — never present this layer as refreshed")
        return {"present": True, "vintage": vintage}

    def assert_coverage(self):
        p = self._local()
        if not p:
            return True, "absent (optional) — hazard plane falls back to DOF + heuristics"
        n = ogr_feature_count(p)
        if n is None:
            return False, "present but unreadable by OGR"
        return True, f"{n} transmission features (frozen)"


# ---------------------------------------------------------------------------------------------
# O8 — TIGER roads
# ---------------------------------------------------------------------------------------------

class TigerRoads(Source):
    name = "tiger_roads"
    title = "Census TIGER/Line roads (NM: state prisec + county all-roads)"
    YEAR = 2024
    STATE_FIPS = "35"
    # Counties intersecting n33w107: Dona Ana (013) holds Las Cruces and the Mesilla Valley,
    # Otero (035) the east side, Sierra (051) the north, Luna (029) the south-west corner.
    COUNTY_FIPS = ["013", "035", "051", "029"]
    MIN_BYTES = 64 << 10

    # PRISECROADS is interstates and state highways only — 2748 features for all of New Mexico.
    # That is the wrong layer for the wire heuristic, whose entire premise is "assume every road
    # has wires": rural distribution follows LOCAL roads, not interstates. Using prisec alone
    # would under-flag the countryside, which is exactly where a forced landing happens. So the
    # county ALL-ROADS layers are the primary input and prisec is kept for road classification.
    def _urls(self):
        base = f"https://www2.census.gov/geo/tiger/TIGER{self.YEAR}"
        out = [(f"{base}/PRISECROADS/tl_{self.YEAR}_{self.STATE_FIPS}_prisecroads.zip",
                "prisecroads")]
        for c in self.COUNTY_FIPS:
            out.append((f"{base}/ROADS/tl_{self.YEAR}_{self.STATE_FIPS}{c}_roads.zip",
                        f"roads_{c}"))
        return out

    def probe(self):
        t = http_version_token(self._urls()[0][0])
        t["layers"] = len(self._urls())
        return t

    def fetch(self):
        got = []
        for url, label in self._urls():
            dest = self.path(os.path.basename(url))
            try:
                path, _ = download(url, dest, expect_min_bytes=self.MIN_BYTES)
                got.append({"label": label, "url": url, "local": path,
                            "bytes": os.path.getsize(path)})
            except Exception as e:
                print(f"     warn tiger {label}: {str(e)[:90]}")
        if not got:
            raise RuntimeError("no TIGER road layers downloaded")
        self._record(status=STATUS_OK, url=self._urls()[0][0], layers=got,
                     local=got[0]["local"], vintage=str(self.YEAR),
                     note="county ALL-ROADS drive the wire heuristic; prisec is classification only")
        return {"layers": len(got)}

    def assert_coverage(self):
        m = C.load_manifest()["sources"].get(self.name, {})
        layers = m.get("layers") or []
        if not layers:
            return False, "not fetched"
        total, counties = 0, 0
        for lyr in layers:
            n = ogr_feature_count(f"/vsizip/{lyr['local']}") or 0
            total += n
            if lyr["label"].startswith("roads_") and n:
                counties += 1
        if counties == 0:
            return False, ("only the prisec layer resolved — the wire heuristic needs local "
                           "roads or it under-flags exactly the rural ground that matters")
        return True, f"{total} road features across {len(layers)} layers ({counties} counties)"


# ---------------------------------------------------------------------------------------------
# T8 — National Wetlands Inventory (bbox query)
# ---------------------------------------------------------------------------------------------

class NWIWetlands(Source):
    name = "nwi"
    title = "USFWS National Wetlands Inventory (cell bbox)"
    # The fws.gov path 301-redirects here. Use the canonical host directly: a redirect on a long
    # query string is fragile, and following one cost this adapter an HTTP 500 during development.
    BASE = ("https://fwspublicservices.wim.usgs.gov/wetlandsmapservice/rest/services/"
            "Wetlands/MapServer/0/query")
    # The layer is a JOIN, so field names are table-qualified and `objectIdField` comes back null.
    # Paging by resultOffset without a stable sort can repeat or skip rows, so order explicitly.
    OID_FIELD = "Wetlands.OBJECTID"
    required = False

    def _url(self, fmt="geojson", count_only=False):
        env = {"xmin": C.CELL_LON_MIN, "ymin": C.CELL_LAT_MIN,
               "xmax": C.CELL_LON_MAX, "ymax": C.CELL_LAT_MAX,
               "spatialReference": {"wkid": 4326}}
        q = {"where": "1=1", "geometry": json.dumps(env), "geometryType": "esriGeometryEnvelope",
             "inSR": "4326", "spatialRel": "esriSpatialRelIntersects", "outFields": "*",
             "outSR": "4326", "f": fmt}
        if count_only:
            q["returnCountOnly"] = "true"
            q["f"] = "json"
        return self.BASE + "?" + urllib.parse.urlencode(q)

    def probe(self):
        try:
            d = http_json(self._url(count_only=True))
        except Exception as e:
            return {"status": "unreachable", "error": str(e)[:120]}
        return {"status": "reachable", "features_in_cell": d.get("count")}

    # WHY THE BULK DOWNLOAD AND NOT THE QUERY SERVICE.
    # The service caps a response at maxRecordCount=1000 and reports it only via
    # `exceededTransferLimit` — never as an error. A naive single request records 1000 features for
    # a cell that holds 6894: a 6.9x silent under-fetch that passes every status-code and
    # file-size check. Paging out of that turned out to be impossible here, measured:
    #   * resultOffset works at 0 and 1000 but HANGS by offset 6000 (the server full-scans);
    #   * `where=Wetlands.OBJECTID>N` is IGNORED — offsets 0, 500k and 1M all return the identical
    #     OID range, so keyset paging silently re-reads page one forever.
    # An adapter that cannot page must not pretend to. So NWI comes from the statewide geodatabase
    # (complete by construction) and the service is kept only as an INDEPENDENT count oracle.
    STATE_URL = ("https://documentst.ecosphere.fws.gov/wetlands/data/State-Downloads/"
                 "NM_geodatabase_wetlands.zip")
    GDB_NAME = "NM_geodatabase_wetlands.gdb"
    LAYER = "NM_Wetlands"
    SHARED = os.path.join(C.DATA_DIR, "_shared")
    MIN_BYTES = 64 << 20

    def fetch(self):
        os.makedirs(self.SHARED, exist_ok=True)
        gdb_zip = os.path.join(self.SHARED, os.path.basename(self.STATE_URL))
        path, did = download(self.STATE_URL, gdb_zip, expect_min_bytes=self.MIN_BYTES)

        ogr = shutil.which("ogr2ogr")
        if not ogr:
            raise RuntimeError("ogr2ogr not on PATH — cannot clip the NWI geodatabase")
        dest = self.path("nwi_cell.geojson")
        if os.path.exists(dest):
            os.remove(dest)
        # /vsizip must address the .gdb DIRECTORY inside the archive, not the archive itself —
        # pointed at the zip root, OpenFileGDB reports "not recognized as a supported format".
        # The layer is NM_Wetlands (the gdb also carries NM_Riparian and metadata layers).
        src = f"/vsizip/{os.path.abspath(path)}/{self.GDB_NAME}"
        # -spat is interpreted in the SOURCE layer's CRS unless told otherwise, and this gdb is
        # already in projected metres (extent ~-1.24e6..-6.1e5 easting — it ships in EPSG:5070,
        # the same grid this pipeline analyses in). Passing a lon/lat box without -spat_srs
        # selected nothing and produced a valid, empty, silent 0-feature layer.
        r = subprocess.run(
            [ogr, "-f", "GeoJSON", dest, src, self.LAYER,
             "-spat", str(C.CELL_LON_MIN), str(C.CELL_LAT_MIN),
             str(C.CELL_LON_MAX), str(C.CELL_LAT_MAX),
             "-spat_srs", "EPSG:4326",
             "-t_srs", "EPSG:4326", "-skipfailures"],
            capture_output=True, text=True, timeout=1800)
        if r.returncode != 0 or not os.path.exists(dest):
            layers = subprocess.run([shutil.which("ogrinfo") or "ogrinfo", "-ro", src],
                                    capture_output=True, text=True, timeout=600).stdout
            raise RuntimeError(f"NWI clip failed: {(r.stderr or '').strip()[:160]} "
                               f"| layers seen: {layers[:220]}")

        expected = (http_json(self._url(count_only=True)) or {}).get("count")
        self._record(status=STATUS_OK, url=self.STATE_URL, local=dest,
                     bytes=os.path.getsize(dest), sha256=sha256_of(dest),
                     vintage="USFWS NM statewide geodatabase", service_count=expected,
                     source_archive=path,
                     note="clipped from the STATEWIDE gdb; the query service cannot be paged "
                          "(offset hangs past ~6000, where-clause ignored)")
        return {"downloaded": did, "service_count": expected}

    def assert_coverage(self):
        m = C.load_manifest()["sources"].get(self.name, {})
        local = m.get("local")
        if not local or not os.path.exists(local):
            return False, "not fetched"
        n = ogr_feature_count(local)
        if n is None:
            return False, "unreadable GeoJSON"
        # Cross-check against what the SERVICE says is in the bbox. Counting our own file only
        # proves we can read what we wrote; it cannot detect that we asked for too little.
        expected = m.get("service_count")
        if expected and n < expected * 0.99:
            return False, (f"under-fetched: {n} of {expected} features the service reports in the "
                           f"cell — paging stopped early")
        # Zero wetlands in the Chihuahuan desert would be a legitimate answer; 1000 exactly is not.
        if expected is None and n in (self.PAGE, self.MAX_PAGES * self.PAGE):
            return False, f"{n} features is exactly a page boundary — suspect silent truncation"
        return True, f"{n} wetland polygons in cell (service reports {expected})"


# ---------------------------------------------------------------------------------------------
# O3 — OpenStreetMap power lines. QUARANTINED (ODbL).
# ---------------------------------------------------------------------------------------------

class OSMPowerQuarantined(Source):
    name = "osm_power"
    title = "OpenStreetMap power lines (New Mexico extract)"
    licence = "ODbL — SHARE-ALIKE"
    required = False
    quarantined = True
    URL = "https://download.geofabrik.de/north-america/us/new-mexico-latest.osm.pbf"
    MIN_BYTES = 8 << 20

    def probe(self):
        t = http_version_token(self.URL)
        t["quarantined"] = True
        return t

    def fetch(self):
        """Downloads the extract but marks it QUARANTINED in the manifest.

        The share-alike hazard is not the download, it is the MERGE. Clustering OSM geometry
        together with other wire sources — keep-best, union-attributes — is what converts a
        Collective Database (each source keeps its own licence) into a Derivative one, at which
        point share-alike can reach anything fused into the same table. So: hazard.py must never
        import this, and verify.py proves the planes are bit-identical with this file deleted."""
        dest = self.path(os.path.basename(self.URL))
        path, did = download(self.URL, dest, expect_min_bytes=self.MIN_BYTES)
        self._record(status=STATUS_OK, url=self.URL, local=path, bytes=os.path.getsize(path),
                     sha256=sha256_of(path), vintage=time.strftime("%Y-%m-%d"),
                     attribution="© OpenStreetMap contributors, ODbL",
                     note="QUARANTINED: display-only layer. Never fuse into the hazard plane.")
        return {"downloaded": did}

    def assert_coverage(self):
        m = C.load_manifest()["sources"].get(self.name, {})
        local = m.get("local")
        if not local or not os.path.exists(local):
            return True, "absent (optional, quarantined)"
        return True, f"{os.path.getsize(local) / 1e6:.0f} MB extract present (quarantined)"


REGISTRY = [Dem3DEP(), AnnualNLCD(), CanopyMeta(), FaaDOF(), HifldFrozen(),
            TigerRoads(), NWIWetlands(), OSMPowerQuarantined()]


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------

def _selected(names):
    if not names:
        return REGISTRY
    by = {s.name: s for s in REGISTRY}
    out = []
    for n in names:
        if n not in by:
            sys.exit(f"unknown source '{n}' — try --list")
        out.append(by[n])
    return out


def cmd_list():
    print(f"{'source':<14}{'req':<5}{'quar':<6}licence / title")
    for s in REGISTRY:
        print(f"{s.name:<14}{'yes' if s.required else 'no':<5}"
              f"{'YES' if s.quarantined else '-':<6}{s.licence} — {s.title}")
    return 0


def cmd_probe(sources):
    rc = 0
    for s in sources:
        try:
            r = s.probe()
        except Exception as e:
            r = {"status": "error", "error": str(e)[:140]}
        bad = r.get("status") in ("unreachable", "error")
        if bad and s.required:
            rc = 1
        print(f"{'FAIL' if bad and s.required else ('warn' if bad else 'ok  ')} {s.name:<14}"
              f"{json.dumps(r, default=str)[:150]}")
    return rc


def cmd_fetch(sources):
    rc = 0
    for s in sources:
        t0 = time.time()
        try:
            r = s.fetch()
            # A source that resolved NOTHING is not "ok", whatever it returned without raising.
            # dem_3dep reported ok with {"tiles": 0, "coverage_pct": 0.0} for a cell that is almost
            # entirely in Mexico — 3DEP is US-only — after seventeen minutes of querying. The
            # coverage gate does catch it later and exits non-zero, so nothing unsafe shipped, but
            # a stage that says "ok" for an empty result sends you looking for the fault in the
            # wrong place. Say it here, where it was learned.
            # EMPTY means nothing usable resolved AT ALL — not merely that the best source was
            # absent. A cell with 0% 1 m lidar but a 1/3 arc-second fallback is buildable and
            # coarse, and failing it here would reject much of the rural west. `assert_coverage`
            # remains the authority: it OPENS the data rather than trusting a count.
            has_fallback = isinstance(r, dict) and (r.get("fallback_13") or 0) > 0
            empty = (isinstance(r, dict)
                     and (r.get("coverage_pct") == 0 or r.get("tiles") == 0)
                     and not has_fallback
                     and r.get("status") != STATUS_STALE_FROZEN)
            coarse_only = (isinstance(r, dict) and r.get("coverage_pct") == 0 and has_fallback)
            tag = "EMPTY" if empty else ("coarse" if coarse_only else "ok  ")
            print(f"{tag} {s.name:<14}{json.dumps(r, default=str)[:110]}  ({time.time()-t0:.0f}s)")
            if coarse_only:
                print(f"     ^ no 1 m lidar over {C.CELL_ID}; building from 1/3 arc-second. The whole "
                      f"cell will read as coarse terrain and be capped accordingly.")
            if empty and s.required:
                print(f"     ^ nothing resolved for {C.CELL_ID}, not even a 1/3 arc-second fallback. "
                      f"If this cell is outside the United States, no US federal source covers it.")
                rc = 1
        except Exception as e:
            print(f"{'FAIL' if s.required else 'warn'} {s.name:<14}{str(e)[:140]}")
            if s.required:
                rc = 1
    return rc


def cmd_assert(sources):
    rc = 0
    for s in sources:
        try:
            ok, why = s.assert_coverage()
        except Exception as e:
            ok, why = False, f"check raised: {str(e)[:120]}"
        if not ok and s.required:
            rc = 1
        tag = "ok  " if ok else ("FAIL" if s.required else "warn")
        print(f"{tag} {s.name:<14}{why}")
    if rc:
        print("\nA required source is missing or unreadable. The build stops here BY DESIGN: an "
              "empty layer renders as 'no hazard here', which is the worst output this product "
              "can produce.")
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="show the source registry")
    ap.add_argument("--probe", action="store_true", help="cheap liveness/version check, no payloads")
    ap.add_argument("--fetch", action="store_true", help="materialise or resolve every source")
    ap.add_argument("--assert-coverage", action="store_true",
                    help="prove each source is readable and covers the cell")
    ap.add_argument("--source", action="append", default=[], help="limit to one source (repeatable)")
    ap.add_argument("--patience", type=float, default=0.0, metavar="MIN",
                    help="keep retrying transient HTTP failures for up to MIN minutes, so an "
                         "unattended multi-cell build rides out a federal API outage")
    C.add_cell_argument(ap)
    a = ap.parse_args()
    C.select_cell(a.cell)          # before ANY path, window or URL is built
    global PATIENCE_S
    PATIENCE_S = max(0.0, a.patience) * 60.0

    sel = _selected(a.source)
    if a.list:
        return cmd_list()
    if a.probe:
        return cmd_probe(sel)
    if a.fetch:
        return cmd_fetch(sel)
    if a.assert_coverage:
        return cmd_assert(sel)
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
