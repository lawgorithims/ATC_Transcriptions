"""Prove `publish_terrain.index_lock` prevents a lost entry — run: python3 lz/tests_publish_terrain_lock.py

⚠️ THIS TEST ASSERTS THE BUG IS VISIBLE, NOT ONLY THAT THE FIX WORKS. Without the lock, four
concurrent read-modify-writes must leave FEWER than four entries; with it, exactly four. If a future
change (a faster save, a narrower window) makes the unlocked case pass by luck, the first assertion
fails rather than the suite going quietly green over a guard that no longer guards anything.

Why it is worth a test at all: the elevation raster is DELETED the moment its upload verifies, so
this index is the only local record that a cell's height data exists. A dropped entry leaves the
file in object storage with nothing pointing at it, and the repair is 45 minutes of re-streaming.
"""
import multiprocessing as mp, os, sys, json, time, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import publish_terrain as P

def writer(cell, use_lock, archive, delay):
    P.ARCHIVE_DIR = archive
    P.INDEX_PATH = os.path.join(archive, "published.json")
    def rmw():
        idx = P.load_index()
        time.sleep(delay)            # widen the window a real upload would open anyway
        idx[cell] = {"bytes": 1}
        P.save_index(idx)
    if use_lock:
        with P.index_lock():
            rmw()
    else:
        rmw()

def run(use_lock):
    d = tempfile.mkdtemp()
    ps = [mp.Process(target=writer, args=(f"cell{i}", use_lock, d, 0.4)) for i in range(4)]
    for p in ps: p.start()
    for p in ps: p.join()
    return len(json.load(open(os.path.join(d, "published.json"))))

if __name__ == "__main__":
    mp.set_start_method("spawn")
    without = run(False)
    with_lock = run(True)
    print(f"without the lock: {without}/4 entries survived")
    print(f"with    the lock: {with_lock}/4 entries survived")
    assert without < 4, "the test cannot detect the bug it is guarding — window too narrow"
    assert with_lock == 4, "THE LOCK DOES NOT WORK"
    print("PASS — the lock is load-bearing and the test proves it")
