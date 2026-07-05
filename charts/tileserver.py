#!/usr/bin/env python3
"""tileserver.py — tiny zero-dependency XYZ tile server for the FAA chart MBTiles.

Serves every `*.mbtiles` in a directory as a layer named after the file stem:

    GET /                       -> HTML index of layers
    GET /health                 -> JSON {ok, layers}
    GET /<layer>.json           -> TileJSON (bounds/minzoom/maxzoom/tiles URL)
    GET /<layer>/<z>/<x>/<y>    -> the tile (png/webp/jpg per the mbtiles format)

MBTiles store rows in TMS (y from the bottom); this flips incoming XYZ y (as used by MapKit's
MKTileOverlay and Leaflet) to TMS on the way in. Read-only, threaded, CORS-open. stdlib only, so
it runs anywhere Python 3 does — no venv needed to *serve* (only to *build*).

    MBTILES_DIR=~/charts/mbtiles PORT=8088 python3 tileserver.py
"""
import http.server, json, os, socketserver, sqlite3, threading, glob, re

MBTILES_DIR = os.path.expanduser(os.environ.get("MBTILES_DIR", "/tmp/charts/mbtiles"))
PORT = int(os.environ.get("PORT", "8088"))
PUBLIC_BASE = os.environ.get("PUBLIC_BASE", "")  # e.g. https://charts.example.com ; else request host

_CT = {"png": "image/png", "webp": "image/webp", "jpg": "image/jpeg", "jpeg": "image/jpeg"}
_TILE = re.compile(r"^/([A-Za-z0-9_\-]+)/(\d+)/(\d+)/(\d+)(?:\.\w+)?$")


class Store:
    """Thread-safe pool of read-only MBTiles connections, one per layer."""
    def __init__(self, d):
        self.layers = {}       # name -> {path, fmt, meta}
        self._local = threading.local()
        self.dir = d
        self.scan()

    def scan(self):
        self.layers.clear()
        for p in sorted(glob.glob(os.path.join(self.dir, "*.mbtiles"))):
            name = os.path.splitext(os.path.basename(p))[0]
            try:
                c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
                meta = dict(c.execute("select name,value from metadata").fetchall())
                c.close()
            except Exception:
                meta = {}
            self.layers[name] = {"path": p, "fmt": (meta.get("format") or "png").lower(), "meta": meta}
        return self.layers

    def _conn(self, path):
        cache = getattr(self._local, "conns", None)
        if cache is None:
            cache = self._local.conns = {}
        if path not in cache:
            cache[path] = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=False)
        return cache[path]

    def tile(self, layer, z, x, y):
        lyr = self.layers.get(layer)
        if not lyr:
            return None, None
        flip = (1 << z) - 1 - y                          # XYZ (top) -> TMS (bottom)
        row = self._conn(lyr["path"]).execute(
            "select tile_data from tiles where zoom_level=? and tile_column=? and tile_row=?",
            (z, x, flip)).fetchone()
        return (row[0] if row else None), lyr["fmt"]


STORE = Store(MBTILES_DIR)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body=b"", ctype="application/octet-stream", cache=True):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        if cache and code == 200:
            self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self): self.do_GET()

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            rows = "".join(
                f"<li><a href='/{n}.json'>{n}</a> — z{l['meta'].get('minzoom','?')}-"
                f"{l['meta'].get('maxzoom','?')}</li>" for n, l in STORE.layers.items())
            return self._send(200, f"<h1>FAA chart tiles</h1><ul>{rows or '<i>no layers</i>'}</ul>"
                              .encode(), "text/html", cache=False)
        if path == "/health":
            return self._send(200, json.dumps({"ok": True, "layers": list(STORE.layers)}).encode(),
                              "application/json", cache=False)
        if path == "/reload":
            return self._send(200, json.dumps({"layers": list(STORE.scan())}).encode(),
                              "application/json", cache=False)
        if path.endswith(".json"):
            name = path[1:-5]
            lyr = STORE.layers.get(name)
            if not lyr:
                return self._send(404, b"no such layer", "text/plain", cache=False)
            base = PUBLIC_BASE or f"http://{self.headers.get('Host', 'localhost')}"
            m = lyr["meta"]
            tj = {"tilejson": "2.2.0", "name": name, "format": lyr["fmt"],
                  "tiles": [f"{base}/{name}/{{z}}/{{x}}/{{y}}"],
                  "minzoom": int(m.get("minzoom", 0)), "maxzoom": int(m.get("maxzoom", 14))}
            if m.get("bounds"):
                tj["bounds"] = [float(v) for v in m["bounds"].split(",")]
            return self._send(200, json.dumps(tj).encode(), "application/json", cache=False)
        mt = _TILE.match(path)
        if mt:
            layer, z, x, y = mt.group(1), int(mt.group(2)), int(mt.group(3)), int(mt.group(4))
            data, fmt = STORE.tile(layer, z, x, y)
            if data is None:
                return self._send(404, b"", "text/plain")   # empty/absent tile
            return self._send(200, data, _CT.get(fmt, "application/octet-stream"))
        return self._send(404, b"not found", "text/plain", cache=False)

    def log_message(self, *a):  # quiet
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"FAA tile server :{PORT}  dir={MBTILES_DIR}  layers={list(STORE.layers) or '(none yet)'}")
    Server(("0.0.0.0", PORT), Handler).serve_forever()
