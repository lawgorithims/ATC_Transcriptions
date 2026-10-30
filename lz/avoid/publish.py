"""Publish the national avoid map to Hugging Face, then prove the app can fetch it.

    ~/chartenv/bin/python -I lz/avoid/publish.py --publish     # upload + verify
    ~/chartenv/bin/python -I lz/avoid/publish.py --verify      # verify only (anonymous, like the app)

Dataset: SingularityUS/commsight-avoid —  map/avoid_conus.mbtiles, index.json, README.md.

⚠️ HF_HUB_DISABLE_XET is FORCED before huggingface_hub is imported (it chooses its backend at import):
a Xet-backed object answers the app's plain anonymous GET with 403, which once shipped silently and
cost a re-host of every chart pack. index.json goes up LAST, so the app can never see a catalog
pointing at a file that is not there yet.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

os.environ["HF_HUB_DISABLE_XET"] = "1"

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C  # noqa: E402

REPO = "SingularityUS/commsight-avoid"
BASE = f"https://huggingface.co/datasets/{REPO}/resolve/main"
MAP_PATH = "map/avoid_conus.mbtiles"


def index_for(report, meta):
    return {"schema": 1,
            "map": {"path": MAP_PATH, "bytes": report["bytes"], "sha256": report["sha256"],
                    "built_at": meta["built_at"], "slope_threshold_deg": meta["slope_threshold_deg"]},
            "license": "ODbL-1.0", "attribution": meta["attribution"], "caveat": meta["caveat"]}


def readme(report, meta):
    return f"""---
license: odbl
pretty_name: CommSight where-not-to-go map (contiguous US)
---
# Where not to go — contiguous US

One byte per ~30 m pixel (Web Mercator z8–z12), each bit a reason NOT to put an aeroplane down:
power lines and utility poles, towers/turbines/obstacles, solar farms, orchards/vineyards/hop poles,
ground steeper than {meta['slope_threshold_deg']}° at 30 m, and optionally water, built-up areas and trees.

**It never shows where to land.** Distribution and farm wires, fences, ditches, crops, livestock and
surface condition are not mapped anywhere public: unshaded ground is not safe ground. Advisory only —
not for navigation.

- Built {meta['built_at']} from {len(meta['cells'])} one-degree cells; {report['bytes'] / 1e6:.0f} MB.
- Sources: {meta['attribution']}
- Tiles: MBTiles, format `avoid1`; each tile is `AVD1` + raw DEFLATE of 256×256 bytes.
- Licence: ODbL 1.0 (the transmission-line source includes OpenStreetMap-derived features).
"""


def publish(out):
    from huggingface_hub import HfApi, create_repo                  # after the Xet export
    with open(out + ".json") as f:
        report = json.load(f)
    import sqlite3
    db = sqlite3.connect(f"file:{out}?mode=ro", uri=True)
    meta = {k: v for k, v in db.execute("SELECT name, value FROM metadata")}
    meta["cells"] = json.loads(meta.get("cells", "[]"))
    db.close()
    api = HfApi()
    create_repo(REPO, repo_type="dataset", exist_ok=True)
    api.upload_file(path_or_fileobj=out, path_in_repo=MAP_PATH, repo_id=REPO, repo_type="dataset",
                    commit_message=f"avoid map built {meta['built_at']}")
    api.upload_file(path_or_fileobj=readme(report, meta).encode(), path_in_repo="README.md",
                    repo_id=REPO, repo_type="dataset", commit_message="README")
    api.upload_file(path_or_fileobj=json.dumps(index_for(report, meta), indent=1).encode(),
                    path_in_repo="index.json", repo_id=REPO, repo_type="dataset", commit_message="index")
    print(f"uploaded {report['bytes'] / 1e6:.0f} MB to {REPO}")


def verify():
    """Anonymous, plain HTTP, no HF client: exactly the app's request."""
    with urllib.request.urlopen(f"{BASE}/index.json", timeout=60) as r:
        idx = json.load(r)
    assert idx.get("schema") == 1, "index.json has the wrong schema"
    req = urllib.request.Request(f"{BASE}/{idx['map']['path']}", headers={"Range": "bytes=0-99"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            code, body = r.status, r.read()
    except urllib.error.HTTPError as ex:
        sys.exit(f"FAIL: HTTP {ex.code}" + ("  <-- XET: re-upload with HF_HUB_DISABLE_XET=1" if ex.code == 403 else ""))
    assert code == 206 and body.startswith(b"SQLite format 3"), f"FAIL: {code} {body[:16]!r}"
    print(f"verified: index.json schema 1, map {idx['map']['bytes'] / 1e6:.0f} MB answers a ranged GET (206, SQLite)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--publish", action="store_true")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--out", default=os.path.join(C.WORK, "out", "avoid_conus.mbtiles"))
    a = ap.parse_args()
    if a.publish:
        publish(a.out)
    if a.publish or a.verify:
        verify()


if __name__ == "__main__":
    main()
