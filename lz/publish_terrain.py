#!/usr/bin/env python3
"""Ship a cell's 10 m elevation raster to HuggingFace, then delete the local copy.

    lz/terrain_archive/elev10m_<cell>.tif
        -> https://huggingface.co/datasets/<REPO>/resolve/main/elev10m/<cell>.tif

WHY THIS EXISTS. The landability planes keep only the DERIVATIVES of height, so terrain.py used to
compute elevation and throw it away — discarding the ~45 minutes and ~30 GB of streaming behind
every cell. It is kept now because synthetic vision will want it. But keeping it HERE is the wrong
place: ~120 MB per cell is ~120 GB across CONUS, on a laptop, for data nothing on the device reads
yet. So it goes to object storage and the local copy goes away.

⚠️ DELETE ONLY AFTER THE UPLOAD IS PROVEN FETCHABLE. Not "the API returned 200" — an anonymous
ranged GET of the published URL that comes back 206 with a real GeoTIFF magic number. A pack that
uploaded but cannot be read back is indistinguishable from a successful publish until someone needs
it, and by then the local copy is gone and the source has to be re-streamed. This is the same
failure the chart re-host already cost a day to, and the same reason lz/publish.py verifies from
outside with no token in the environment.

⚠️ THE XET TRAP, AGAIN. HuggingFace serves Xet-backed large files only by chunk reconstruction, so a
plain anonymous GET returns 403. HF_HUB_DISABLE_XET must be exported BEFORE huggingface_hub is
imported, because the library picks its transfer backend at import time. Re-uploading identical
bytes does NOT fix a Xet object — Xet dedups by content hash.

USAGE
    python3 lz/publish_terrain.py --cell n37w107            # upload, verify, delete
    python3 lz/publish_terrain.py --cell n37w107 --keep     # upload + verify, keep the local file
    python3 lz/publish_terrain.py --all                     # every archive present
"""

# ---------------------------------------------------------------------------------------------
# THE ONE LINE THAT MATTERS. Must precede the huggingface_hub import.
# ---------------------------------------------------------------------------------------------
import contextlib
import fcntl
import os

os.environ["HF_HUB_DISABLE_XET"] = "1"          # FORCED, not setdefault

import argparse                                  # noqa: E402
import hashlib                                   # noqa: E402
import json                                      # noqa: E402
import sys                                       # noqa: E402
import time                                      # noqa: E402
import urllib.error                              # noqa: E402
import urllib.request                            # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzcommon as C                             # noqa: E402

REPO = os.environ.get("LZ_TERRAIN_HF_REPO", "SingularityUS/commsight-terrain")
REPO_TYPE = "dataset"
BASE_URL = f"https://huggingface.co/datasets/{REPO}/resolve/main"
ARCHIVE_DIR = os.path.join(C.LZ_ROOT, "terrain_archive")
INDEX_PATH = os.path.join(ARCHIVE_DIR, "published.json")
# A real 1-degree cell at 10 m is tens of MB; anything tiny is a stub or an error page.
MIN_BYTES = 1 << 20
VERIFY_TIMEOUT = 120


def _fail(msg):
    print(f"FAIL  {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def hf_token():
    tok = os.environ.get("HF_TOKEN")
    if tok:
        return tok.strip()
    path = os.path.expanduser("~/.hf_token")
    if os.path.exists(path):
        with open(path) as fh:
            return fh.read().strip()
    return None


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_fetchable(cell, expect_bytes):
    """Anonymous ranged GET of the published URL. 206 + a GeoTIFF magic number, or it did not work.

    Deliberately builds its own opener with NO auth header: publishing with a token and then
    verifying with the same token proves only that the uploader can read its own upload, which is
    exactly the case that passed while every anonymous client got a 403.
    """
    url = f"{BASE_URL}/elev10m/{cell}.tif"
    req = urllib.request.Request(url, headers={"Range": "bytes=0-1023",
                                               "User-Agent": "commsight-lz/1"})
    try:
        with urllib.request.urlopen(req, timeout=VERIFY_TIMEOUT) as r:
            code, head = r.status, r.read(8)
    except urllib.error.HTTPError as ex:
        hint = "  <-- XET: re-upload with HF_HUB_DISABLE_XET=1" if ex.code == 403 else ""
        return False, f"HTTP {ex.code}{hint}"
    except Exception as ex:                                          # noqa: BLE001
        return False, str(ex)
    if code != 206:
        return False, f"expected 206 for a ranged GET, got {code}"
    # TIFF magic: "II*\0" little-endian or "MM\0*" big-endian; BigTIFF uses 43 instead of 42.
    if head[:4] not in (b"II\x2a\x00", b"MM\x00\x2a", b"II\x2b\x00", b"MM\x00\x2b"):
        return False, f"not a GeoTIFF — first bytes {head[:4]!r}"
    if expect_bytes < MIN_BYTES:
        return False, f"local file was only {expect_bytes} bytes"
    return True, f"206, GeoTIFF, {expect_bytes / 1e6:.0f} MB"


@contextlib.contextmanager
def index_lock():
    """Hold an exclusive lock across the index's read-modify-write.

    ⚠️ TWO PUBLISHERS WOULD SILENTLY LOSE AN ENTRY. `load_index` → mutate → `save_index` is atomic
    in its WRITE (tmp + os.replace) but not across the pair: two runs publishing at the same moment
    each load the same snapshot and the second's save drops the first's cell.

    That loss is worse than it sounds. The raster itself is DELETED locally the moment the upload
    verifies, so this index is the only local record that a cell's elevation exists at all. A
    dropped entry leaves the file sitting in object storage with nothing pointing at it, and the
    obvious repair — re-run the build — costs another 45 minutes of streaming for data already
    paid for.

    Needed the moment two build queues run in parallel, which is exactly what a ten-core machine
    invites.
    """
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    with open(INDEX_PATH + ".lock", "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def load_index():
    if os.path.exists(INDEX_PATH):
        try:
            with open(INDEX_PATH) as fh:
                return json.load(fh)
        except json.JSONDecodeError:
            return {}
    return {}


def save_index(idx):
    """Atomic replace — and a tmp name that is unique per writer.

    ⚠️ A SHARED TMP NAME MAKES THE "ATOMIC" WRITE ATOMIC AGAINST A CRASH ONLY, NOT AGAINST A SECOND
    WRITER. With one fixed `published.json.tmp`, two processes write the same file, the first
    `os.replace` consumes it — publishing the OTHER process's bytes under its own name — and the
    second raises FileNotFoundError on a file it thought it owned. Observed, not theoretical: it
    fell out of the concurrency test for `index_lock`.

    `index_lock` already serialises the only caller, so this is defence in depth rather than the
    live fix. It is here because the next caller will not know about the lock.
    """
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    tmp = f"{INDEX_PATH}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(idx, fh, indent=2, sort_keys=True)
        os.replace(tmp, INDEX_PATH)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def publish_one(api, cell, token, keep):
    local = os.path.join(ARCHIVE_DIR, f"elev10m_{cell}.tif")
    if not os.path.exists(local):
        print(f"skip {cell}: no local archive")
        return True
    size = os.path.getsize(local)
    if size < MIN_BYTES:
        _fail(f"{cell}: archive is only {size} bytes — refusing to publish a stub")

    digest = sha256_of(local)
    print(f"{cell}: {size / 1e6:.0f} MB, sha256 {digest[:12]}… uploading", flush=True)
    t0 = time.time()
    api.upload_file(path_or_fileobj=local, path_in_repo=f"elev10m/{cell}.tif",
                    repo_id=REPO, repo_type=REPO_TYPE, token=token)
    print(f"  uploaded in {time.time() - t0:.0f}s, verifying anonymously …", flush=True)

    ok, why = verify_fetchable(cell, size)
    if not ok:
        _fail(f"{cell}: uploaded but NOT fetchable ({why}). Local copy KEPT.")
    print(f"  verified: {why}")

    # Read-modify-write under the lock — see `index_lock`. The window is tiny and the loss is
    # permanent, which is the combination that makes a bug like this survive for months.
    with index_lock():
        idx = load_index()
        idx[cell] = {"bytes": size, "sha256": digest,
                     "url": f"{BASE_URL}/elev10m/{cell}.tif",
                     "published_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        save_index(idx)

    if keep:
        print(f"  kept {local} (--keep)")
        return True
    os.remove(local)
    print(f"  deleted {local} — it lives at {BASE_URL}/elev10m/{cell}.tif")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cell", help="publish one cell's archive")
    ap.add_argument("--all", action="store_true", help="publish every archive present")
    ap.add_argument("--keep", action="store_true",
                    help="do not delete the local file after a verified upload")
    a = ap.parse_args()

    if not a.cell and not a.all:
        ap.error("give --cell or --all")

    cells = []
    if a.cell:
        cells = [a.cell]
    else:
        if os.path.isdir(ARCHIVE_DIR):
            cells = sorted(f[len("elev10m_"):-len(".tif")] for f in os.listdir(ARCHIVE_DIR)
                           if f.startswith("elev10m_") and f.endswith(".tif"))
    if not cells:
        print("nothing to publish")
        return 0

    token = hf_token()
    if not token:
        _fail("no HF_TOKEN and no ~/.hf_token — a WRITE token is required")

    from huggingface_hub import HfApi, create_repo      # AFTER the Xet export
    try:
        create_repo(REPO, repo_type=REPO_TYPE, token=token, exist_ok=True)
    except Exception as ex:                                          # noqa: BLE001
        _fail(f"could not create/open {REPO}: {ex}")
    api = HfApi()

    print(f"publishing {len(cells)} elevation archive(s) to {REPO}  (Xet DISABLED)\n")
    for cell in cells:                                               # bounded (rule 2)
        publish_one(api, cell, token, a.keep)
    print("\ndone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
