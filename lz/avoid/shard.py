"""Split the merged national map into longitude bands the app can download one at a time.

    python3 -I lz/avoid/shard.py [--map $AVOID_WORK/out/avoid_conus.mbtiles] [--max-mb 100]

A band is a run of whole z8 tile COLUMNS with every tile below them (z8–z12), so no tile is ever
split between two files and the device never merges bands: a tile belongs to the one band whose
column range holds its z8 ancestor (x >> (z − 8)). The app's downloader cannot resume, and its
largest download before this was a 73 MB chart pack; one ~1.3 GB national file would have had to
restart from zero on any dropped connection.

Writes $AVOID_WORK/out/shards/avoid_<id>.mbtiles and shards.json (bytes, sha256, column range).
"""
import argparse
import hashlib
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common as C  # noqa: E402


def column_bytes(db):
    """Compressed bytes per z8 column, over every zoom."""
    out = {}
    for z, x, n in db.execute("SELECT zoom_level, tile_column, SUM(LENGTH(tile_data)) FROM tiles "
                              "GROUP BY zoom_level, tile_column"):     # bounded by the columns
        x8 = x >> (z - C.MIN_ZOOM)
        out[x8] = out.get(x8, 0) + n
    return out


def bands(cols, max_bytes):
    """Consecutive z8 columns, greedily, each band under max_bytes (a single heavier column stands alone)."""
    out, cur, size = [], [], 0
    for x8 in sorted(cols):                                          # bounded by the columns
        if cur and size + cols[x8] > max_bytes:
            out.append((cur[0], cur[-1], size))
            cur, size = [], 0
        cur.append(x8)
        size += cols[x8]
    if cur:
        out.append((cur[0], cur[-1], size))
    return out


def west_edge(x8):
    return -180.0 + x8 * 360.0 / (1 << C.MIN_ZOOM)


def band_id(lo, hi):
    """Named by the band's west and east edges in whole degrees west, e.g. w125-w118."""
    return f"w{int(round(-west_edge(lo)))}-w{int(round(-west_edge(hi + 1)))}"


def write_band(src, path, lo, hi, meta, bid):
    tmp = path + ".part"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    db.execute("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
    for k, v in meta.items():
        if k not in ("cells", "bounds"):
            db.execute("INSERT INTO metadata VALUES (?, ?)", (k, v))
    w, e = west_edge(lo), west_edge(hi + 1)
    s, n = C.CONUS_BBOX[1], C.CONUS_BBOX[3]
    for k, v in (("shard", bid), ("shard_x8", f"{lo},{hi}"), ("bounds", f"{w},{s},{e},{n}")):
        db.execute("INSERT INTO metadata VALUES (?, ?)", (k, v))
    n_tiles = 0
    for z in range(C.MIN_ZOOM, C.ZOOM + 1):                           # bounded: z8..z12
        k = z - C.MIN_ZOOM
        rows = src.execute("SELECT zoom_level, tile_column, tile_row, tile_data FROM tiles "
                           "WHERE zoom_level=? AND tile_column>=? AND tile_column<=?",
                           (z, lo << k, ((hi + 1) << k) - 1)).fetchall()
        db.executemany("INSERT INTO tiles VALUES (?, ?, ?, ?)", rows)
        n_tiles += len(rows)
    db.execute("CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)")
    db.commit()
    db.execute("VACUUM")
    db.close()
    os.replace(tmp, path)
    return n_tiles


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):             # bounded by the file
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", default=os.path.join(C.WORK, "out", "avoid_conus.mbtiles"))
    ap.add_argument("--max-mb", type=float, default=100.0)
    a = ap.parse_args()
    assert 10 <= a.max_mb <= 500, "band size out of range"
    src = sqlite3.connect(f"file:{a.map}?mode=ro", uri=True)
    meta = {k: v for k, v in src.execute("SELECT name, value FROM metadata")}
    assert meta.get("format") == "avoid1", "not an avoid map"
    total = src.execute("SELECT COUNT(*) FROM tiles").fetchone()[0]
    cols = column_bytes(src)
    plan = bands(cols, int(a.max_mb * 1e6))
    out_dir = os.path.join(os.path.dirname(a.map), "shards")
    os.makedirs(out_dir, exist_ok=True)
    shards, written = [], 0
    for lo, hi, _ in plan:                                           # bounded by the bands
        bid = band_id(lo, hi)
        path = os.path.join(out_dir, f"avoid_{bid}.mbtiles")
        n = write_band(src, path, lo, hi, meta, bid)
        written += n
        shards.append({"id": bid, "file": os.path.basename(path), "x8": [lo, hi], "tiles": n,
                       "bytes": os.path.getsize(path), "sha256": sha256(path)})
        print(f"{bid}: z8 columns {lo}-{hi}, {n} tiles, {shards[-1]['bytes'] / 1e6:.0f} MB", flush=True)
    assert written == total, f"bands hold {written} tiles, the map has {total}"
    for s1, s2 in zip(shards, shards[1:]):
        assert s1["x8"][1] < s2["x8"][0], "bands overlap"
    with open(os.path.join(out_dir, "shards.json"), "w") as f:
        json.dump({"built_at": meta["built_at"], "slope_threshold_deg": meta.get("slope_threshold_deg"),
                   "shards": shards}, f, indent=1)
    print(f"{len(shards)} bands, {sum(s['bytes'] for s in shards) / 1e6:.0f} MB, every tile placed once")


if __name__ == "__main__":
    main()
