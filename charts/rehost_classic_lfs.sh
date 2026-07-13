#!/usr/bin/env bash
# rehost_classic_lfs.sh — convert every chart pack in the HF dataset from Xet-backed storage back to
# classic Git-LFS, so the app's plain anonymous `GET /resolve/main/<path>` works again. HF migrated the
# repo to Xet, which only serves large files via a chunk-reconstruction protocol the app can't speak
# (plain GET → 403). Xet dedups by content hash, so simply re-uploading identical bytes with Xet
# disabled re-links to the existing Xet object; we therefore add a harmless `rehost` metadata row to each
# MBTiles (SQLite) to change its hash, delete the Xet copy, and re-upload as classic LFS. The extra
# metadata row is ignored by the app (it reads bounds/format/tiles only). Resumable via done.txt.
set -uo pipefail
export HF_HUB_DISABLE_XET=1          # MUST be set before huggingface_hub imports its Xet integration
export HF_TOKEN="${HF_TOKEN:-$(cat "$HOME/.hf_token" 2>/dev/null)}"
PY=~/chartenv/bin/python3
"$PY" - <<'PY'
import os, sqlite3, json, urllib.request
from huggingface_hub import hf_hub_download, upload_file, delete_file

REPO = "SingularityUS/faa-charts"
BASE = f"https://huggingface.co/datasets/{REPO}/resolve/main"
WORK = "/tmp/charts/rehost"; HIGH = "/tmp/charts/packs"
os.makedirs(WORK, exist_ok=True)
done_path = os.path.join(WORK, "done.txt")
done = set(open(done_path).read().split()) if os.path.exists(done_path) else set()

idx = json.load(urllib.request.urlopen(f"{BASE}/index.json"))
paths = [e["path"] for e in idx.get("sectional", []) + idx.get("ifrLow", []) + idx.get("ifrHigh", [])]
print(f"packs to rehost: {len(paths)}  (already done: {len(done)})", flush=True)

def local_copy(path):
    base = os.path.basename(path)
    hp = os.path.join(HIGH, base)                    # IFR-high built locally this session
    if path.startswith("ifrhigh/") and os.path.exists(hp): return hp
    return hf_hub_download(REPO, filename=path, repo_type="dataset", local_dir=WORK)  # else pull from HF (Xet client)

for i, path in enumerate(paths, 1):
    if path in done:
        continue
    try:
        lp = local_copy(path)
        c = sqlite3.connect(lp)
        c.execute("INSERT OR REPLACE INTO metadata(name,value) VALUES('rehost','classic-lfs-05-14-2026')")
        c.commit(); c.close()
        try: delete_file(path_in_repo=path, repo_id=REPO, repo_type="dataset")
        except Exception: pass
        upload_file(path_or_fileobj=lp, path_in_repo=path, repo_id=REPO, repo_type="dataset")
        done.add(path); open(done_path, "w").write("\n".join(sorted(done)))
        print(f"[{i}/{len(paths)}] rehosted {path} ({os.path.getsize(lp)}B)", flush=True)
    except Exception as e:
        print(f"[{i}/{len(paths)}] !! FAILED {path}: {e}", flush=True)

# Regenerate index.json bytes from the local copies (the metadata row can nudge the size), keep bounds.
def size_of(path):
    base = os.path.basename(path)
    for p in (os.path.join(HIGH, base), os.path.join(WORK, path)):
        if os.path.exists(p): return os.path.getsize(p)
    return None
changed = 0
for k in ("sectional", "ifrLow", "ifrHigh"):
    for e in idx.get(k, []):
        s = size_of(e["path"])
        if s and s != e.get("bytes"): e["bytes"] = s; changed += 1
tmp = os.path.join(WORK, "index.json")
json.dump(idx, open(tmp, "w"), separators=(",", ":"))
upload_file(path_or_fileobj=tmp, path_in_repo="index.json", repo_id=REPO, repo_type="dataset")
print(f"index.json re-uploaded ({changed} byte-sizes updated)  DONE {len(done)}/{len(paths)}", flush=True)
PY
