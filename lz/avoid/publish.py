"""Publish the national avoid map to Hugging Face as longitude bands, then prove the app can fetch them.

    ~/chartenv/bin/python -I lz/avoid/publish.py --publish     # upload + verify
    ~/chartenv/bin/python -I lz/avoid/publish.py --verify      # verify only (anonymous, like the app)

Dataset: SingularityUS/commsight-avoid — map/avoid_<band>.mbtiles (from lz/avoid/shard.py), README.md,
index.json (schema 2: the bands, their sizes and sha256).

⚠️ HF_HUB_DISABLE_XET is FORCED before huggingface_hub is imported (it chooses its backend at import):
a Xet-backed object answers the app's plain anonymous GET with 403, which once shipped silently and
cost a re-host of every chart pack. All bands go up in ONE commit, and index.json goes up LAST, so the
app can never see a catalog pointing at a file that is not there yet.
"""
import argparse
import hashlib
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request

os.environ["HF_HUB_DISABLE_XET"] = "1"

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common as C  # noqa: E402

REPO = "SingularityUS/commsight-avoid"
BASE = f"https://huggingface.co/datasets/{REPO}/resolve/main"
SCHEMA = 2


def load(out):
    shards_dir = os.path.join(os.path.dirname(out), "shards")
    with open(os.path.join(shards_dir, "shards.json")) as f:
        plan = json.load(f)
    db = sqlite3.connect(f"file:{out}?mode=ro", uri=True)
    meta = {k: v for k, v in db.execute("SELECT name, value FROM metadata")}
    db.close()
    meta["cells"] = json.loads(meta.get("cells", "[]"))
    assert plan["built_at"] == meta["built_at"], "the bands are not from this map"
    for sh in plan["shards"]:                                        # bounded by the bands
        b = sqlite3.connect(f"file:{os.path.join(shards_dir, sh['file'])}?mode=ro", uri=True)
        m = {k: v for k, v in b.execute("SELECT name, value FROM metadata")}
        b.close()
        assert m.get("shard") == sh["id"] and m.get("built_at") == meta["built_at"], f"band {sh['id']} metadata"
    return shards_dir, plan, meta


def index_for(plan, meta):
    return {"schema": SCHEMA, "built_at": meta["built_at"], "slope_threshold_deg": meta["slope_threshold_deg"],
            "shards": [{"id": s["id"], "path": f"map/{s['file']}", "bytes": s["bytes"], "sha256": s["sha256"]}
                       for s in plan["shards"]],
            "license": "ODbL-1.0", "attribution": meta["attribution"], "caveat": meta["caveat"]}


def readme(plan, meta):
    total = sum(s["bytes"] for s in plan["shards"])
    return f"""---
license: odbl
pretty_name: Obelisk where-not-to-go map (contiguous US)
---
# Where not to go — contiguous US

One byte per ~30 m pixel (Web Mercator z8–z12), each bit a reason NOT to put an aeroplane down:
power lines and utility poles, towers/turbines/obstacles, solar farms, orchards/vineyards/hop poles,
ground steeper than {meta['slope_threshold_deg']}° at 30 m, and optionally water, built-up areas and trees.

**It never shows where to land.** Distribution and farm wires, fences, ditches, crops, livestock and
surface condition are not mapped anywhere public: unshaded ground is not safe ground. Advisory only —
not for navigation.

- Built {meta['built_at']} from {len(meta['cells'])} one-degree cells; {total / 1e9:.2f} GB in
  {len(plan['shards'])} longitude bands (`map/`), listed with sha256 in `index.json`.
- Each band holds whole z8 tile columns and every tile below them: a tile is in exactly one band.
- Sources: {meta['attribution']}
- Tiles: MBTiles, format `avoid1`; each tile is `AVD1` + raw DEFLATE of 256×256 bytes.
- Licence: ODbL 1.0 (the transmission-line source includes OpenStreetMap-derived features).
"""


def hf_token():
    """HF_TOKEN, else ~/.hf_token (mode 600) — the same rule as lz/publish.py. A WRITE token."""
    tok = os.environ.get("HF_TOKEN")
    if tok:
        return tok.strip()
    path = os.path.expanduser("~/.hf_token")
    if os.path.exists(path):
        with open(path) as fh:
            return fh.read().strip()
    return None


def publish(out):
    from huggingface_hub import HfApi, create_repo                  # after the Xet export
    shards_dir, plan, meta = load(out)
    token = hf_token()
    if not token:
        sys.exit("FAIL: no HF_TOKEN and no ~/.hf_token — a WRITE token is required")
    api = HfApi(token=token)
    create_repo(REPO, repo_type="dataset", exist_ok=True, token=token)
    api.upload_folder(folder_path=shards_dir, path_in_repo="map", repo_id=REPO, repo_type="dataset",
                      allow_patterns=["avoid_*.mbtiles"],
                      commit_message=f"avoid map built {meta['built_at']}: {len(plan['shards'])} bands")
    api.upload_file(path_or_fileobj=readme(plan, meta).encode(), path_in_repo="README.md",
                    repo_id=REPO, repo_type="dataset", commit_message="README")
    api.upload_file(path_or_fileobj=json.dumps(index_for(plan, meta), indent=1).encode(),
                    path_in_repo="index.json", repo_id=REPO, repo_type="dataset", commit_message="index")
    print(f"uploaded {len(plan['shards'])} bands, {sum(s['bytes'] for s in plan['shards']) / 1e9:.2f} GB, to {REPO}")


def verify():
    """Anonymous, plain HTTP, no HF client: exactly the app's requests. Every band answers a ranged
    GET as SQLite, and the smallest is fetched whole and checked against its sha256."""
    with urllib.request.urlopen(f"{BASE}/index.json", timeout=60) as r:
        idx = json.load(r)
    assert idx.get("schema") == SCHEMA, "index.json has the wrong schema"
    assert idx["shards"], "index.json lists no bands"
    for sh in idx["shards"]:                                         # bounded by the bands
        req = urllib.request.Request(f"{BASE}/{sh['path']}", headers={"Range": "bytes=0-99"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                code, body = r.status, r.read()
        except urllib.error.HTTPError as ex:
            sys.exit(f"FAIL {sh['id']}: HTTP {ex.code}"
                     + ("  <-- XET: re-upload with HF_HUB_DISABLE_XET=1" if ex.code == 403 else ""))
        assert code == 206 and body.startswith(b"SQLite format 3"), f"FAIL {sh['id']}: {code} {body[:16]!r}"
    small = min(idx["shards"], key=lambda s: s["bytes"])
    h = hashlib.sha256()
    with urllib.request.urlopen(f"{BASE}/{small['path']}", timeout=600) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):             # bounded by the file
            h.update(chunk)
    assert h.hexdigest() == small["sha256"], f"FAIL {small['id']}: sha256 mismatch"
    print(f"verified: index.json schema {SCHEMA}, {len(idx['shards'])} bands answer ranged GETs (206, SQLite); "
          f"{small['id']} fetched whole matches its sha256")


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
