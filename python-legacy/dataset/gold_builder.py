"""Gold-set batch builder: turn fresh collector segments into a human-verification
package, and verified corrections back into gold rows.

Fixes gold v0's two documented gaps:
  * CONSENSUS BIAS — candidates are sampled from ALL scored segments (accepted
    and rejected alike), so the gold set represents real speech, not just what
    the models already agree on.
  * MISSING TAGS — every candidate carries prefilled ROLE (controller/pilot)
    and CALLSIGN fields (from atc_diarize on the teacher draft), editable in
    the review page; verified tags feed CSA and the Phase-5 role metrics.

Blocks used for gold are appended to {storage_root}/excluded_blocks_gold.txt —
`emit_metadata.to_train_metadata` skips them so gold can never leak into
training data.

Usage (run on the collector box):
    python -m dataset.gold_builder build --storage-root ~/atc-data \
        --out ~/gold_v1_batch1 --n 150 [--per-feed-cap 40] [--seed 7]
    # ...user verifies out/review.html, exports corrections_v1.json...
    python -m dataset.gold_builder ingest --corrections corrections_v1.json \
        --candidates <out>/candidates.json --out gold_testset_v1.jsonl \
        [--merge <gold_testset_v0.jsonl>]
"""

from __future__ import annotations

import argparse
import html
import json
import random
import shutil
import sys
from pathlib import Path
from typing import List, Optional

_HERE = Path(__file__).resolve().parent.parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from atc_diarize import classify_turn
from dataset import normalize


def _find_clip(storage: Path, seg_id: str, src_block: str) -> Optional[Path]:
    """id 'tower_east-20260627T2235Z__0019' -> segments/*/tower_east/<block>/0019.wav."""
    if "__" not in seg_id:
        return None
    seg_no = seg_id.rsplit("__", 1)[1]
    hits = list(storage.glob(f"segments/*/*/{src_block}/{seg_no}.wav"))
    return hits[0] if hits else None


def build(args) -> int:
    storage = Path(args.storage_root).expanduser()
    out = Path(args.out).expanduser()
    (out / "clips").mkdir(parents=True, exist_ok=True)

    rows = [json.loads(l) for l in (storage / "us_pseudo" / "scores.jsonl")
            .read_text(encoding="utf-8").splitlines() if l.strip()]
    pool = [r for r in rows if (r.get("text_a") or "").strip()
            and r.get("reason") not in ("likely_no_speech", "duration_out_of_range")]

    rng = random.Random(args.seed)
    rng.shuffle(pool)
    by_feed: dict = {}
    picked: List[dict] = []
    for r in pool:
        feed = (r.get("src_block") or "?").rsplit("-", 1)[0]
        if by_feed.get(feed, 0) >= args.per_feed_cap:
            continue
        clip = _find_clip(storage, r["id"], r["src_block"])
        if clip is None:
            continue
        by_feed[feed] = by_feed.get(feed, 0) + 1
        picked.append({"row": r, "clip": clip})
        if len(picked) >= args.n:
            break

    candidates, blocks = [], set()
    for i, p in enumerate(picked, 1):
        r = p["row"]
        dest = out / "clips" / f"{i:03d}.wav"
        shutil.copyfile(p["clip"], dest)
        draft = normalize.normalize_transcript(r["text_a"])
        turn = classify_turn(draft)
        airport = p["clip"].relative_to(storage / "segments").parts[0]
        candidates.append({
            "n": i, "id": r["id"], "airport": airport,
            "feed": (r.get("src_block") or "?").rsplit("-", 1)[0],
            "clip": f"clips/{i:03d}.wav",
            "draft": draft,
            "accept_state": r.get("reason", "?"),
            "role_prefill": {"controller": "ctl", "pilot": "acft"}.get(turn.role, "unk"),
            "callsign_prefill": turn.callsign or "",
        })
        blocks.add(r["src_block"])

    (out / "candidates.json").write_text(json.dumps(candidates, indent=1), encoding="utf-8")
    excl = storage / "excluded_blocks_gold.txt"
    known = set(excl.read_text(encoding="utf-8").splitlines()) if excl.exists() else set()
    excl.write_text("\n".join(sorted(known | blocks)) + "\n", encoding="utf-8")
    (out / "review.html").write_text(_render_review(candidates), encoding="utf-8")

    feeds = ", ".join(f"{k}:{v}" for k, v in sorted(by_feed.items()))
    print(f"{len(candidates)} candidates -> {out} ({feeds})")
    print(f"{len(blocks)} source blocks appended to {excl} (training-excluded)")
    return 0


import re as _re

_UNCLEAR_SPAN = _re.compile(r"\[unclear\](.*?)\[/unclear\]", _re.S)
_UNCLEAR_TOKEN = _re.compile(r"\[unclear\]")


def _strip_unclear(text: str) -> tuple:
    """Replace [unclear]...[/unclear] spans and bare [unclear] tokens with <unk>.

    Returns (ref_text, had_unclear). The original words stay in the corrections
    file for future use; the gold ref carries <unk> so scorers can exclude or
    special-case these rows (scoreboard skips them from corpus WER by default —
    models should not be graded against audio a human could not resolve).
    """
    had = bool(_UNCLEAR_SPAN.search(text) or _UNCLEAR_TOKEN.search(text))
    text = _UNCLEAR_SPAN.sub(" <unk> ", text)
    text = _UNCLEAR_TOKEN.sub(" <unk> ", text)
    return " ".join(text.split()), had


def ingest(args) -> int:
    cands = {c["id"]: c for c in json.loads(Path(args.candidates).read_text(encoding="utf-8"))}
    corrections = json.loads(Path(args.corrections).read_text(encoding="utf-8"))
    rows, skipped, n_unclear, n_multiturn = [], 0, 0, 0
    for c in corrections:
        if c.get("status") != "good":
            skipped += 1
            continue
        cand = cands.get(c["id"], {})
        # v1.1 export carries per-speaker turns; legacy exports carry `corrected`.
        raw_turns = c.get("turns") or [{
            "text": c.get("corrected", ""),
            "role": c.get("role", "unk"),
            "callsign": c.get("callsign", ""),
        }]
        turns, parts, had_any = [], [], False
        for t in raw_turns:
            stripped, had = _strip_unclear(t.get("text", ""))
            had_any = had_any or had
            ref_part = normalize.normalize_transcript(stripped.replace("<unk>", " UNKTOKEN "))
            ref_part = ref_part.replace("unktoken", "<unk>")
            if not ref_part:
                continue
            parts.append(ref_part)
            turns.append({"text": ref_part, "role": t.get("role", "unk"),
                          "callsign": (t.get("callsign") or "").strip() or None})
        if not parts:
            skipped += 1
            continue
        if len(turns) > 1:
            n_multiturn += 1
        if had_any:
            n_unclear += 1
        rows.append({
            "clip": cand.get("clip"), "id": c["id"], "airport": c.get("airport"),
            "feed": c.get("feed"), "ref": " ".join(parts),
            "turns": turns, "unclear": had_any,
            # first-turn convenience fields (back-compat with v0-shaped consumers)
            "role": turns[0]["role"], "callsign": turns[0]["callsign"],
        })
    merged = []
    if args.merge:
        merged = [json.loads(l) for l in Path(args.merge).read_text(encoding="utf-8").splitlines() if l.strip()]
    out = Path(args.out)
    with out.open("w", encoding="utf-8") as f:
        for r in merged + rows:
            f.write(json.dumps(r) + "\n")
    print(f"gold rows: {len(rows)} new verified ({n_multiturn} multi-speaker, "
          f"{n_unclear} with unclear spans) + {len(merged)} merged "
          f"({skipped} bad/empty skipped) -> {out}")
    return 0


def _render_review(candidates: List[dict]) -> str:
    data = json.dumps(candidates).replace("</", "<\\/")
    return _TEMPLATE.replace("__DATA__", data)


_TEMPLATE = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Gold v1 verification</title>
<style>
 body{font-family:-apple-system,Segoe UI,sans-serif;max-width:900px;margin:24px auto;padding:0 16px;background:#F5F7F8;color:#1A2530}
 h1{font-size:20px} .sub{color:#5B6B78;font-size:13px}
 .card{background:#fff;border:1px solid #DCE3E8;border-radius:6px;padding:14px 16px;margin:14px 0}
 .card.done{border-left:4px solid #2E7D4F} .card.bad{border-left:4px solid #B3403A;opacity:.75}
 .hdr{display:flex;gap:12px;align-items:baseline;font-size:12px;color:#5B6B78;font-family:monospace}
 textarea{width:100%;box-sizing:border-box;font-family:monospace;font-size:14px;min-height:52px;margin-top:8px;
          border:1px solid #DCE3E8;border-radius:4px;padding:8px}
 .row{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-top:8px;font-size:13px}
 input[type=text]{font-family:monospace;border:1px solid #DCE3E8;border-radius:4px;padding:4px 8px;width:220px}
 button{cursor:pointer;border:1px solid #DCE3E8;border-radius:4px;padding:5px 12px;background:#fff;font-size:13px}
 button.primary{background:#1D5B8C;color:#fff;border-color:#1D5B8C}
 button.good{background:#2E7D4F;color:#fff;border-color:#2E7D4F}
 button.bad{background:#B3403A;color:#fff;border-color:#B3403A}
 .bar{position:sticky;top:0;background:#F5F7F8;padding:10px 0;display:flex;gap:12px;align-items:center;z-index:2;border-bottom:1px solid #DCE3E8}
 audio{width:100%;margin-top:6px;height:34px}
 label{user-select:none}
 .turn{border-left:3px solid #DCE3E8;padding-left:10px;margin-top:10px}
 .turn:only-of-type{border-left:none;padding-left:0}
 .tn{font-family:monospace;font-size:11px;color:#5B6B78}
</style></head><body>
<h1>Gold v1 verification</h1>
<p class="sub">Listen, fix the transcript to exactly what was said (numbers as digits, runways like "22r"),
set the speaker role + callsign (as spoken, e.g. "delta 232"), then Good / Unusable.
<b>Multiple speakers in one clip?</b> Place the cursor where the next speaker starts and press
<b>Split turn</b> — each turn gets its own role and callsign.
<b>Can't make words out?</b> Select them and press <b>Mark unclear</b> (or press it with nothing
selected to insert an [unclear] token) — never guess. Progress autosaves locally;
Export when done and send the file back.</p>
<div class="bar"><span id="progress"></span><button class="primary" onclick="exportJson()">Export corrections</button></div>
<div id="cards"></div>
<script>
const DATA = __DATA__;
const KEY = "goldv1." + DATA.length;
let state = JSON.parse(localStorage.getItem(KEY) || "{}");
// migrate v1.0 entries ({corrected, role, callsign}) to the turns shape — earlier
// review progress survives the UI upgrade.
for (const id in state) {
  const s = state[id];
  if (!s.turns) {
    s.turns = [{ text: s.corrected ?? null, role: s.role ?? null, callsign: s.callsign ?? null }];
    delete s.corrected; delete s.role; delete s.callsign;
  }
}
function save(){ localStorage.setItem(KEY, JSON.stringify(state)); renderProgress(); }
function get(c){
  if (!state[c.id]) state[c.id] = { turns: [{ text: c.draft, role: c.role_prefill, callsign: c.callsign_prefill }] };
  const s = state[c.id];
  s.turns = s.turns.map(t => ({ text: t.text ?? c.draft, role: t.role ?? c.role_prefill,
                                callsign: t.callsign ?? c.callsign_prefill }));
  return s;
}
function renderProgress(){
  const done = DATA.filter(c => (state[c.id]||{}).status).length;
  document.getElementById("progress").textContent = done + " / " + DATA.length + " reviewed";
}
function esc(x){ const d = document.createElement("div"); d.textContent = x ?? ""; return d.innerHTML; }
function turnRow(c, s, ti){
  const t = s.turns[ti];
  return `
  <div class="turn">
    <textarea data-ti="${ti}">${esc(t.text)}</textarea>
    <div class="row">
      <span class="tn">turn ${ti+1}/${s.turns.length}</span>
      role:
      <label><input type="radio" name="role-${c.n}-${ti}" value="ctl" ${t.role==="ctl"?"checked":""}> controller</label>
      <label><input type="radio" name="role-${c.n}-${ti}" value="acft" ${t.role==="acft"?"checked":""}> aircraft</label>
      <label><input type="radio" name="role-${c.n}-${ti}" value="unk" ${t.role==="unk"?"checked":""}> unclear</label>
      callsign: <input type="text" data-cs="${ti}" value="${esc(t.callsign)}">
      <button data-act="split" data-ti="${ti}" title="cursor marks where the next speaker starts">Split turn</button>
      <button data-act="unclear" data-ti="${ti}" title="wrap selection; empty selection inserts a token">Mark unclear</button>
      ${s.turns.length > 1 ? `<button data-act="del" data-ti="${ti}" title="remove this turn">&#10005;</button>` : ""}
    </div>
  </div>`;
}
function card(c){
  const s = get(c);
  const div = document.createElement("div");
  div.className = "card" + (s.status === "good" ? " done" : s.status === "bad" ? " bad" : "");
  div.innerHTML = `
    <div class="hdr"><b>#${c.n}</b><span>${c.airport} · ${c.feed}</span><span>${c.id}</span><span>[${c.accept_state}]</span></div>
    <audio controls preload="none" src="${c.clip}"></audio>
    ${s.turns.map((_, ti) => turnRow(c, s, ti)).join("")}
    <div class="row">
      <button class="good" data-act="good">Good</button>
      <button class="bad" data-act="bad">Unusable</button>
    </div>`;
  div.querySelectorAll("textarea").forEach(ta => ta.addEventListener("input", e => {
    s.turns[+e.target.dataset.ti].text = e.target.value; save();
  }));
  div.querySelectorAll("input[data-cs]").forEach(inp => inp.addEventListener("input", e => {
    s.turns[+e.target.dataset.cs].callsign = e.target.value; save();
  }));
  div.querySelectorAll('input[type=radio]').forEach(r => r.addEventListener("change", e => {
    const ti = +e.target.name.split("-")[2];
    s.turns[ti].role = e.target.value; save();
  }));
  div.addEventListener("click", e => {
    const act = e.target.dataset && e.target.dataset.act;
    if (!act) return;
    if (act === "good" || act === "bad") { s.status = act; save(); refresh(c, div); return; }
    const ti = +e.target.dataset.ti;
    const ta = div.querySelector(`textarea[data-ti="${ti}"]`);
    if (act === "split") {
      const pos = ta.selectionStart ?? 0;
      const before = ta.value.slice(0, pos).trim(), after = ta.value.slice(pos).trim();
      if (!after) return;   // nothing after the cursor — nothing to split off
      s.turns[ti].text = before;
      // new turn defaults to the OTHER side of the exchange (turn-taking prior)
      s.turns.splice(ti + 1, 0, { text: after,
        role: s.turns[ti].role === "ctl" ? "acft" : "ctl", callsign: "" });
      save(); refresh(c, div);
    } else if (act === "del") {
      s.turns.splice(ti, 1); save(); refresh(c, div);
    } else if (act === "unclear") {
      const a = ta.selectionStart ?? 0, b = ta.selectionEnd ?? 0;
      ta.value = b > a
        ? ta.value.slice(0, a) + "[unclear]" + ta.value.slice(a, b) + "[/unclear]" + ta.value.slice(b)
        : ta.value.slice(0, a) + " [unclear] " + ta.value.slice(a);
      s.turns[ti].text = ta.value; save();
    }
  });
  return div;
}
function refresh(c, oldDiv){ oldDiv.replaceWith(card(c)); renderProgress(); }
function exportJson(){
  const out = DATA.map(c => { const s = get(c); return {
    n: c.n, id: c.id, airport: c.airport, feed: c.feed, draft: c.draft,
    turns: s.turns,
    corrected: s.turns.map(t => t.text).join(" "),
    status: s.status ?? "unreviewed" };});
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([JSON.stringify(out, null, 1)], {type: "application/json"}));
  a.download = "corrections_v1.json"; a.click();
}
function renderAll(){
  const root = document.getElementById("cards"); root.innerHTML = "";
  DATA.forEach(c => root.appendChild(card(c)));
  renderProgress();
}
renderAll();
</script></body></html>
"""


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--storage-root", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--n", type=int, default=150)
    b.add_argument("--per-feed-cap", type=int, default=40)
    b.add_argument("--seed", type=int, default=7)
    b.set_defaults(fn=build)
    i = sub.add_parser("ingest")
    i.add_argument("--corrections", required=True)
    i.add_argument("--candidates", required=True)
    i.add_argument("--out", required=True)
    i.add_argument("--merge", default=None)
    i.set_defaults(fn=ingest)
    r = sub.add_parser("render", help="re-render review.html from existing candidates.json")
    r.add_argument("--candidates", required=True)
    r.add_argument("--out", required=True)
    r.set_defaults(fn=lambda a: (Path(a.out).write_text(
        _render_review(json.loads(Path(a.candidates).read_text(encoding="utf-8"))),
        encoding="utf-8"), print(f"rendered {a.out}"))[-1] or 0)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
