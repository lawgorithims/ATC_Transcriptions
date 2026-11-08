"""Publish the national avoid map to Hugging Face as longitude bands, then prove the app can fetch them.

    ~/chartenv/bin/python -I lz/avoid/publish.py --publish     # upload + verify
    ~/chartenv/bin/python -I lz/avoid/publish.py --verify      # verify only (anonymous, like the app)

Dataset: SingularityUS/commsight-avoid — map/avoid_<band>.mbtiles (from lz/avoid/shard.py), README.md,
index-v3.json (catalog schema 3: the bands, their sizes and sha256), and the older catalogs.

EACH CATALOG SCHEMA HAS ITS OWN ADDRESS. Catalog 3 lists avoid_schema 2 bands (land cover stored to z11
only); an app that reads catalog 2 would read their z12 tiles as complete, so it must never see them,
and it cannot: it reads index.json. That catalog (2, the 2026-10-30 build) stays published with its
bands for every app build made before catalog 3, and a band is deleted only when NO catalog lists it.

⚠️ HF_HUB_DISABLE_XET is FORCED before huggingface_hub is imported (it chooses its backend at import):
a Xet-backed object answers the app's plain anonymous GET with 403, which once shipped silently and
cost a re-host of every chart pack. All bands go up in ONE commit, and the index goes up LAST, so the
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
SCHEMA = 3                                     # the app's AvoidMapLibrary.catalogSchema
INDEX = f"index-v{SCHEMA}.json"                # the app's AvoidMapLibrary.catalogPath


def is_catalog(path):
    return path.startswith("index") and path.endswith(".json") and "/" not in path


def fetch_json(path):
    """A dataset file read the way the app reads it: anonymous plain HTTP. Raises on any failure — a
    catalog that could not be read must never count as one that lists nothing."""
    with urllib.request.urlopen(f"{BASE}/{path}", timeout=60) as r:
        return json.load(r)


def stale_bands(remote, catalogs):
    """Band files that no published catalog lists. A band an older catalog still lists is not stale:
    the app builds that read that catalog download it."""
    listed = {s["path"] for c in catalogs.values() for s in c["shards"]}
    return sorted(p for p in remote if p.startswith("map/avoid_") and p.endswith(".mbtiles") and p not in listed)


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
        assert m.get("avoid_schema") == C.MAP_SCHEMA, f"band {sh['id']} is avoid_schema {m.get('avoid_schema')}"
    return shards_dir, plan, meta


def index_for(plan, meta):
    return {"schema": SCHEMA, "built_at": meta["built_at"], "slope_threshold_deg": meta["slope_threshold_deg"],
            "shards": [{"id": s["id"], "path": f"map/{s['file']}", "bytes": s["bytes"], "sha256": s["sha256"]}
                       for s in plan["shards"]],
            "license": "ODbL-1.0", "attribution": meta["attribution"], "caveat": meta["caveat"]}


def readme(plan, meta, older):
    total = sum(s["bytes"] for s in plan["shards"])
    kept = "".join(f"\n- `{p}`: catalog schema {c['schema']}, built {c['built_at']}, {len(c['shards'])} bands "
                   f"({sum(s['bytes'] for s in c['shards']) / 1e9:.2f} GB), for the app builds that read it."
                   for p, c in sorted(older.items()))
    return f"""---
license: odbl
pretty_name: Obelisk where-not-to-go map (contiguous US)
---
# Where not to go — contiguous US

One byte per ~30 m pixel (Web Mercator z8–z12), each bit a reason NOT to put an aeroplane down:
power lines and utility poles, towers/turbines/obstacles, solar farms, orchards/vineyards/hop poles,
ground steeper than {meta['slope_threshold_deg']}° at 30 m, and optionally water, built-up areas and trees
(stored to z11, ~60 m: a z12 pixel's land cover is its z11 parent pixel's).

**It never shows where to land.** Distribution and farm wires, fences, ditches, crops, livestock and
surface condition are not mapped anywhere public: unshaded ground is not safe ground. Advisory only —
not for navigation.

- Built {meta['built_at']} from {len(meta['cells'])} one-degree cells; {total / 1e9:.2f} GB in
  {len(plan['shards'])} longitude bands (`map/`), listed with sha256 in `{INDEX}` (catalog schema {SCHEMA}).
- Each band holds whole z8 tile columns and every tile below them: a tile is in exactly one band.
- Sources: {meta['attribution']}
- Tiles: MBTiles, format `avoid1`, `avoid_schema` {C.MAP_SCHEMA}; each tile is `AVD1` + raw DEFLATE of
  256×256 bytes. z12 tiles hold no land cover (bits {C.LAND_COVER}); read it from z{C.LAND_COVER_ZOOM}.
- Licence: ODbL 1.0 (the transmission-line source includes OpenStreetMap-derived features).
""" + (f"""
## Older catalogs, kept with their bands

Each catalog schema has its own address, so an app build keeps the map it can read.{kept}
""" if older else "")


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
    older = {p: fetch_json(p) for p in api.list_repo_files(REPO, repo_type="dataset") if is_catalog(p) and p != INDEX}
    assert all(c.get("schema") != SCHEMA for c in older.values()), f"another catalog claims schema {SCHEMA}"
    api.upload_folder(folder_path=shards_dir, path_in_repo="map", repo_id=REPO, repo_type="dataset",
                      allow_patterns=["avoid_*.mbtiles"],
                      commit_message=f"avoid map built {meta['built_at']}: {len(plan['shards'])} bands")
    api.upload_file(path_or_fileobj=readme(plan, meta, older).encode(), path_in_repo="README.md",
                    repo_id=REPO, repo_type="dataset", commit_message="README")
    api.upload_file(path_or_fileobj=json.dumps(index_for(plan, meta), indent=1).encode(),
                    path_in_repo=INDEX, repo_id=REPO, repo_type="dataset", commit_message=f"index (catalog {SCHEMA})")
    print(f"uploaded {len(plan['shards'])} bands, {sum(s['bytes'] for s in plan['shards']) / 1e9:.2f} GB, to {REPO}; "
          f"older catalogs kept: {', '.join(sorted(older)) or 'none'}")
    drop_stale_bands(api, plan, meta)


def drop_stale_bands(api, plan, meta):
    """Delete the band files that no catalog lists any more (a band that kept its name was
    overwritten). After the new index, never before, and never one an older catalog still lists."""
    from huggingface_hub import CommitOperationDelete
    remote = api.list_repo_files(REPO, repo_type="dataset")
    listed = {f"map/{s['file']}" for s in plan["shards"]}
    assert listed <= set(remote) and INDEX in remote, f"not up after the upload: {sorted(listed - set(remote))}"
    catalogs = {p: fetch_json(p) for p in remote if is_catalog(p) and p != INDEX}
    catalogs[INDEX] = index_for(plan, meta)                          # what was just written, not a cached read
    stale = stale_bands(remote, catalogs)
    if stale:
        api.create_commit(REPO, repo_type="dataset", operations=[CommitOperationDelete(path_in_repo=p) for p in stale],
                          commit_message=f"remove {len(stale)} bands no catalog lists")
    print(f"removed {len(stale)} stale bands: {', '.join(p[4:] for p in stale) or 'none'}")


def check_bands(name, idx):
    """Every band a catalog lists answers a ranged GET as SQLite (an Xet-backed file answers 403)."""
    for sh in idx["shards"]:                                         # bounded by the bands
        req = urllib.request.Request(f"{BASE}/{sh['path']}", headers={"Range": "bytes=0-99"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                code, body = r.status, r.read()
        except urllib.error.HTTPError as ex:
            sys.exit(f"FAIL {name} {sh['id']}: HTTP {ex.code}"
                     + ("  <-- XET: re-upload with HF_HUB_DISABLE_XET=1" if ex.code == 403 else ""))
        assert code == 206 and body.startswith(b"SQLite format 3"), f"FAIL {name} {sh['id']}: {code} {body[:16]!r}"


def verify():
    """Anonymous, plain HTTP, no HF client: exactly the app's requests. Every band of EVERY catalog
    answers a ranged GET as SQLite (older builds still read the older ones), and the current catalog's
    smallest band is fetched whole and checked against its sha256."""
    with urllib.request.urlopen(f"https://huggingface.co/api/datasets/{REPO}/tree/main", timeout=60) as r:
        root = [e["path"] for e in json.load(r)]
    assert INDEX in root, f"{INDEX} is not published"
    idx = fetch_json(INDEX)
    assert idx.get("schema") == SCHEMA and idx["shards"], f"{INDEX}: schema {idx.get('schema')}, or no bands"
    check_bands(INDEX, idx)
    older = {p: fetch_json(p) for p in root if is_catalog(p) and p != INDEX}
    for p, c in sorted(older.items()):                              # bounded by the catalogs
        check_bands(p, c)
    small = min(idx["shards"], key=lambda s: s["bytes"])
    h = hashlib.sha256()
    with urllib.request.urlopen(f"{BASE}/{small['path']}", timeout=600) as r:
        for chunk in iter(lambda: r.read(1 << 20), b""):             # bounded by the file
            h.update(chunk)
    assert h.hexdigest() == small["sha256"], f"FAIL {small['id']}: sha256 mismatch"
    print(f"verified: {INDEX} schema {SCHEMA}, {len(idx['shards'])} bands answer ranged GETs (206, SQLite); "
          f"{small['id']} fetched whole matches its sha256; older catalogs still served: "
          + (", ".join(f"{p} (schema {c['schema']}, {len(c['shards'])} bands)" for p, c in sorted(older.items()))
             or "none"))


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
