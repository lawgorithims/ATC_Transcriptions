"""Batch-aware border sweep on one simulator.
usage: sweep.py DEVICE KIND LAYER PAIRSFILE OUTFILE [zooms...]
  KIND  _SEC | ENR_L | ENR_H     LAYER  sectional | ifrLow | ifrHigh
env: CHART_PACKS (built packs dir, default ~/CommSight/charts-build/packs),
     CHART_CYCLE (MM-DD-YYYY suffix the app expects, default 09-03-2026), PYTHON (needs Pillow).
Groups pairs into batches whose packs fit under the app's 600 MB budget, installs each batch,
relaunches the app at every border in it and probes that border against the oracle."""
import sys, os, subprocess, glob, json, time
DEV, KIND, LAYER, PAIRS, OUT = sys.argv[1:6]
ZOOMS = sys.argv[6:] or ["10", "11", "12"]
S = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.expanduser(os.environ.get("CHART_PACKS", "~/CommSight/charts-build/packs"))
CYCLE = os.environ.get("CHART_CYCLE", "09-03-2026"); PY = os.environ.get("PYTHON", sys.executable)
APP = "com.flycommsight.atctranscribe"; LIMIT = 520 * 1024 * 1024
def sh(*a, **k): return subprocess.run(a, capture_output=True, text=True, **k).stdout.strip()
size = {os.path.basename(f)[:-8]: os.path.getsize(f) for f in glob.glob(f"{SRC}/*.mbtiles")}
pairs = []
for line in open(PAIRS):
    lat, lon, a, b, *_ = line.split()
    if a in size and b in size: pairs.append((float(lat), float(lon), a, b))
    else: print("SKIP no pack", a, b, file=sys.stderr)
pairs.sort(key=lambda p: (round(p[1] / 6), p[0]))          # roughly geographic, so batches share packs
batches, cur, need = [], [], set()
for p in pairs:
    n = need | {p[2], p[3]}
    if cur and sum(size[x] for x in n) > LIMIT: batches.append((cur, need)); cur, need = [], set(); n = {p[2], p[3]}
    cur.append(p); need = n
if cur: batches.append((cur, need))
cont = sh("xcrun", "simctl", "get_app_container", DEV, APP, "data"); PK = f"{cont}/Library/Application Support/charts"
os.makedirs(PK, exist_ok=True)
# The layer goes in as a launch argument: `simctl spawn defaults write` never reaches the app sandbox.
out = open(OUT, "a")
for bi, (bp, packs) in enumerate(batches):
    sh("xcrun", "simctl", "terminate", DEV, APP)
    for f in glob.glob(f"{PK}/*.mbtiles"): os.remove(f)
    for n in packs: subprocess.run(["cp", f"{SRC}/{n}.mbtiles", f"{PK}/{n}-{CYCLE}.mbtiles"])
    for lat, lon, a, b in bp:
        sh("xcrun", "simctl", "terminate", DEV, APP)
        sh("xcrun", "simctl", "location", DEV, "set", f"{lat},{lon}")
        pid = sh("xcrun", "simctl", "launch", DEV, APP, "--chart-layer", {"sectional":"vfr","ifrLow":"ifr","ifrHigh":"ifrh"}[LAYER], "--chart-center", f"{lat},{lon}").split(":")[-1].strip()
        time.sleep(12)                                       # mount + first tile pass
        port = ""
        for line in sh("lsof", "-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN").splitlines()[1:]:
            port = line.split()[8].split(":")[-1]
        have = sorted(os.path.basename(f).split("-")[0] for f in glob.glob(f"{PK}/*.mbtiles"))
        evicted = sorted(packs - set(have))
        if not port:
            rec = {"pair": f"{a}/{b}", "error": "no tile server port (app not running?)", "pid": pid}
        else:
            r = subprocess.run([PY, "-I", f"{S}/probe.py", PK, port, KIND, "check", a, b, *ZOOMS],
                               capture_output=True, text=True)
            try: rec = json.loads(r.stdout.strip().splitlines()[-1])
            except Exception: rec = {"pair": f"{a}/{b}", "error": (r.stderr or r.stdout)[-400:]}
        rec.update(batch=bi, lat=lat, lon=lon, evicted=evicted, port=port)
        out.write(json.dumps(rec) + "\n"); out.flush()
print("done", len(pairs), "pairs in", len(batches), "batches")
