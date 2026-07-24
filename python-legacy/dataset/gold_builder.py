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
    rows, skipped, n_unclear, n_multiturn, n_corrected = [], 0, 0, 0, 0
    for c in corrections:
        # "good" = draft was right; "corrected" = good after the verifier's edits.
        # Both are usable gold; the distinction is kept (verified field) because
        # the corrected share measures the draft/teacher error rate on real speech.
        if c.get("status") not in ("good", "corrected"):
            skipped += 1
            continue
        if c["status"] == "corrected":
            n_corrected += 1
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
            # the highlighter UI carries no callsign field — extract it from the
            # turn's own words (the role-highlighted span contains the spoken callsign)
            callsign = (t.get("callsign") or "").strip() or None
            if callsign is None:
                from atc_diarize import extract_callsign
                callsign = extract_callsign(ref_part.replace("<unk>", " "))
            turns.append({"text": ref_part, "role": t.get("role", "unk"),
                          "callsign": callsign})
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
            "turns": turns, "unclear": had_any, "verified": c["status"],
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
    print(f"gold rows: {len(rows)} new verified ({n_corrected} corrected, "
          f"{n_multiturn} multi-speaker, {n_unclear} with unclear spans) "
          f"+ {len(merged)} merged ({skipped} bad/empty skipped) -> {out}")
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
 .card.fixed{border-left:4px solid #B07C1F}
 button.fixedbtn{background:#B07C1F;color:#fff;border-color:#B07C1F}
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
 .ta{border:1px solid #DCE3E8;border-radius:4px;padding:10px;margin-top:8px;font-family:monospace;
     font-size:14.5px;line-height:1.9;min-height:44px;background:#fff;white-space:pre-wrap}
 .ta:focus{outline:2px solid #1D5B8C33}
 .hl-ctl{background:#CFE3F4;border-radius:2px;box-shadow:0 0 0 1px #CFE3F4}
 .hl-acft{background:#D6EBD9;border-radius:2px;box-shadow:0 0 0 1px #D6EBD9}
 .hl-unclear{text-decoration:underline wavy #B07C1F;background-color:#F6E8B8}
 .hl-ctl.hl-unclear{background:linear-gradient(#F6E8B8,#F6E8B8) 0 100%/100% 6px no-repeat,#CFE3F4}
 .hl-acft.hl-unclear{background:linear-gradient(#F6E8B8,#F6E8B8) 0 100%/100% 6px no-repeat,#D6EBD9}
 .speeds{display:flex;gap:4px;align-items:center;margin-top:4px;font-size:11px;color:#5B6B78}
 .speeds button{padding:1px 8px;font-size:11.5px;font-family:monospace}
 .speeds button.on{background:#1A2530;color:#fff;border-color:#1A2530}
 .tools{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
 .tool{border:1px solid #DCE3E8}
 .tool.active{outline:2.5px solid #1A2530;outline-offset:1px;font-weight:700}
 .tool.t-ctl{background:#CFE3F4} .tool.t-acft{background:#D6EBD9} .tool.t-unclear{background:#F6E8B8}
 .legend{font-size:12px;color:#5B6B78}
 kbd{font-family:monospace;background:#E8EDF0;border-radius:3px;padding:0 4px;font-size:11px}
</style></head><body>
<h1>Gold v1 verification</h1>
<p class="sub">Listen, fix the transcript to exactly what was said (numbers as digits, runways like "22r").
<b>Assign speakers by highlighting:</b> pick a highlighter below, then sweep it across the words each
speaker said (selections snap to whole words; multiple aircraft = paint each one's words with
Aircraft — callsigns are read from the highlighted text automatically).
<b>Unclear speech:</b> paint transcribed-but-doubtful words with the Unclear highlighter, or press
<b>⟨insert [unclear]⟩</b> at the cursor for audible speech you can't transcribe at all — never guess.
Eraser removes highlights. Verdict: <b>Good</b> (draft was right), <b>Corrected</b> (good after your
edits), <b>Unusable</b>. <b>One-shot labeling (macOS-friendly):</b> select the words a speaker said, then just press
<kbd>1</kbd>/<kbd>C</kbd> controller &middot; <kbd>2</kbd>/<kbd>A</kbd> aircraft &middot;
<kbd>3</kbd>/<kbd>U</kbd> unclear &middot; <kbd>4</kbd>/<kbd>E</kbd> erase — no modifier needed
(<kbd>&#8997;</kbd> or <kbd>&#8963;</kbd>+digit also work).
Autosaves locally; Export when done.</p>
<div class="bar">
  <div class="tools">
    <button class="tool" data-tool="edit" title="normal text editing"><kbd>0</kbd> edit</button>
    <button class="tool t-ctl" data-tool="ctl"><kbd>1</kbd> controller</button>
    <button class="tool t-acft" data-tool="acft"><kbd>2</kbd> aircraft</button>
    <button class="tool t-unclear" data-tool="unclear"><kbd>3</kbd> unclear</button>
    <button class="tool" data-tool="erase"><kbd>4</kbd> eraser</button>
    <button class="tool" data-tool="token" title="insert an [unclear] token at the cursor">⟨insert [unclear]⟩</button>
  </div>
  <span id="progress"></span>
  <button class="primary" onclick="exportJson()">Export corrections</button>
</div>
<p class="legend">Unpainted text is fine when only one speaker is present — it exports as
role&nbsp;"unclear/unknown"; paint it if you know who spoke. Wavy underline = unclear words.</p>
<div id="cards"></div>
<script>
const DATA = __DATA__;
const KEY = "goldv1." + DATA.length;
let state = JSON.parse(localStorage.getItem(KEY) || "{}");
let tool = "edit";

// ---- migrate earlier formats so review progress survives UI upgrades ----
// v1.2 shape: { status, text, runs: [{s, e, role|null, unclear:bool}] }
for (const id in state) {
  const s = state[id];
  if (s.runs) continue;
  if (s.turns) {                          // v1.1 split-turns shape
    let text = "", runs = [];
    s.turns.forEach(t => {
      if (text) text += " ";
      const start = text.length;
      text += (t.text ?? "");
      if (t.role === "ctl" || t.role === "acft")
        runs.push({ s: start, e: text.length, role: t.role, unclear: false });
    });
    state[id] = { status: s.status, text, runs };
  } else if ("corrected" in s || "status" in s) {   // v1.0 shape
    state[id] = { status: s.status, text: s.corrected ?? null, runs: [] };
  }
}

function save(){ localStorage.setItem(KEY, JSON.stringify(state)); renderProgress(); }
function get(c){
  if (!state[c.id]) state[c.id] = { text: null, runs: [] };
  const s = state[c.id];
  if (s.text == null) s.text = c.draft;
  return s;
}
function renderProgress(){
  const done = DATA.filter(c => (state[c.id]||{}).status).length;
  document.getElementById("progress").textContent = done + " / " + DATA.length + " reviewed";
}
function esc(x){ const d = document.createElement("div"); d.textContent = x ?? ""; return d.innerHTML; }

// ---- runs <-> DOM ----
// render text + runs as flat spans (one span per run; classes carry role + unclear)
function runHTML(s){
  const bounds = new Set([0, s.text.length]);
  s.runs.forEach(r => { bounds.add(r.s); bounds.add(r.e); });
  const cuts = [...bounds].sort((a, b) => a - b);
  let html = "";
  for (let i = 0; i + 1 < cuts.length; i++) {
    const a = cuts[i], b = cuts[i + 1];
    if (a >= b) continue;
    const seg = s.text.slice(a, b);
    const role = s.runs.find(r => r.s <= a && r.e >= b && r.role)?.role;
    const unclear = s.runs.some(r => r.s <= a && r.e >= b && r.unclear);
    const cls = (role ? "hl-" + role : "") + (unclear ? " hl-unclear" : "");
    html += cls.trim() ? `<span class="${cls.trim()}">${esc(seg)}</span>` : esc(seg);
  }
  return html || esc(s.text);
}
// serialize the (possibly user-edited) DOM back to {text, runs}
function domToRuns(div){
  let text = "";
  const runs = [];
  (function walk(node, role, unclear){
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) { text += child.textContent; continue; }
      let r = role, u = unclear;
      if (child.classList) {
        if (child.classList.contains("hl-ctl")) r = "ctl";
        if (child.classList.contains("hl-acft")) r = "acft";
        if (child.classList.contains("hl-unclear")) u = true;
      }
      const start = text.length;
      walk(child, r, u);
      if ((r || u) && text.length > start) runs.push({ s: start, e: text.length, role: r, unclear: u });
    }
  })(div, null, false);
  return { text, runs: mergeRuns(runs, text.length) };
}
function mergeRuns(runs, n){
  // flatten to char props, rebuild minimal run list (handles any overlap/nesting)
  const role = new Array(n).fill(null), unc = new Array(n).fill(false);
  runs.forEach(r => { for (let i = Math.max(0, r.s); i < Math.min(n, r.e); i++) {
    if (r.role) role[i] = r.role;
    if (r.unclear) unc[i] = true;
  }});
  const out = [];
  let i = 0;
  while (i < n) {
    if (!role[i] && !unc[i]) { i++; continue; }
    let j = i;
    while (j < n && role[j] === role[i] && unc[j] === unc[i]) j++;
    out.push({ s: i, e: j, role: role[i], unclear: unc[i] });
    i = j;
  }
  return out;
}
// selection -> [start, end) offsets in the div's text, snapped to word boundaries
function selectionOffsets(div){
  const sel = window.getSelection();
  if (!sel.rangeCount) return null;
  const range = sel.getRangeAt(0);
  if (!div.contains(range.startContainer) || !div.contains(range.endContainer)) return null;
  function offsetOf(container, offset){
    const walker = document.createTreeWalker(div, NodeFilter.SHOW_TEXT);
    let total = 0, node;
    while ((node = walker.nextNode())) {
      if (node === container) return total + offset;
      total += node.textContent.length;
    }
    return total;   // container is the div itself / element node: clamp to end
  }
  let a = offsetOf(range.startContainer, range.startOffset);
  let b = offsetOf(range.endContainer, range.endOffset);
  if (a > b) [a, b] = [b, a];
  const text = div.textContent;
  while (a > 0 && /\S/.test(text[a - 1]) && /\S/.test(text[a])) a--;          // snap left
  while (b < text.length && b > 0 && /\S/.test(text[b - 1]) && /\S/.test(text[b])) b++;  // snap right
  return a === b ? { caret: a } : { a, b };
}
function applyTool(c, div){
  const s = get(c);
  const off = selectionOffsets(div);
  if (!off) return;
  const cur = domToRuns(div);         // trust the DOM (it may hold fresh text edits)
  s.text = cur.text; s.runs = cur.runs;
  let caretAfter = null;
  if (tool === "token") {
    const at = off.caret ?? off.a;
    const ins = (at > 0 && s.text[at-1] !== " " ? " " : "") + "[unclear]" + (s.text[at] !== " " ? " " : "");
    // shift runs past the insertion point
    s.runs.forEach(r => { if (r.s >= at) r.s += ins.length; if (r.e > at) r.e += ins.length; });
    s.text = s.text.slice(0, at) + ins + s.text.slice(at);
    caretAfter = at + ins.length;
  } else if (off.caret == null) {
    const patch = tool === "erase" ? { role: null, unclear: false }
               : tool === "unclear" ? { unclear: true }
               : { role: tool };
    const add = [];
    if ("role" in patch) add.push({ s: off.a, e: off.b, role: patch.role, unclear: false, roleOnly: true });
    // char-level apply via mergeRuns: expand current runs, overlay the patch
    const n = Math.max(s.text.length, off.b);
    const role = new Array(n).fill(null), unc = new Array(n).fill(false);
    s.runs.forEach(r => { for (let i = r.s; i < Math.min(n, r.e); i++) { if (r.role) role[i] = r.role; if (r.unclear) unc[i] = true; }});
    for (let i = off.a; i < off.b; i++) {
      if (tool === "erase") { role[i] = null; unc[i] = false; }
      else if (tool === "unclear") unc[i] = true;
      else role[i] = tool;
    }
    s.runs = mergeRuns([{s:0,e:0}].concat(
      Array.from({length: n}, (_, i) => ({ s: i, e: i + 1, role: role[i], unclear: unc[i] }))
        .filter(r => r.role || r.unclear)), n);
    caretAfter = off.b;
  } else return;   // highlight tools need a selection
  div.innerHTML = runHTML(s);
  if (caretAfter != null) setCaret(div, Math.min(caretAfter, s.text.length));
  save();
}
// one-shot: apply a tool to the current selection without changing the sticky tool
function applyToolOnce(t){
  const sel = window.getSelection();
  const anchor = sel.anchorNode && (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement);
  const ta = anchor && anchor.closest && anchor.closest(".ta");
  if (!ta) return false;
  const idx = cardIndex(ta);
  if (idx < 0) return false;
  const prev = tool; tool = t;
  applyTool(DATA[idx], ta);
  tool = prev;
  return true;
}

function statusClass(st){
  return st === "good" ? " done" : st === "corrected" ? " fixed" : st === "bad" ? " bad" : "";
}
function card(c){
  const s = get(c);
  const div = document.createElement("div");
  div.className = "card" + statusClass(s.status);
  div.innerHTML = `
    <div class="hdr"><b>#${c.n}</b><span>${c.airport} · ${c.feed}</span><span>${c.id}</span><span>[${c.accept_state}]</span></div>
    <audio controls preload="none" src="${c.clip}"></audio>
    <div class="speeds">speed:
      <button data-sp="0.5">0.5×</button><button data-sp="0.75">0.75×</button><button data-sp="1" class="on">1×</button><button data-sp="1.5">1.5×</button>
    </div>
    <div class="ta" contenteditable="true" spellcheck="false"></div>
    <div class="row">
      <button class="good" data-act="good">Good</button>
      <button class="fixedbtn" data-act="corrected">Corrected</button>
      <button class="bad" data-act="bad">Unusable</button>
    </div>`;
  // slow-motion playback: per-card speed chips; the chosen speed becomes the
  // default for every card played afterwards (pitch is preserved by the browser)
  const audio = div.querySelector("audio");
  let mySpeed = null;
  function applySpeed(sp){
    audio.preservesPitch = true;
    audio.playbackRate = sp;
    div.querySelectorAll(".speeds button").forEach(b =>
      b.classList.toggle("on", +b.dataset.sp === sp));
  }
  div.querySelectorAll(".speeds button").forEach(b => b.addEventListener("click", () => {
    mySpeed = +b.dataset.sp;
    window.lastSpeed = mySpeed;
    applySpeed(mySpeed);
  }));
  audio.addEventListener("play", () => applySpeed(mySpeed ?? window.lastSpeed ?? 1));

  const ta = div.querySelector(".ta");
  ta.innerHTML = runHTML(s);
  ta.addEventListener("input", () => {
    const cur = domToRuns(ta);
    s.text = cur.text; s.runs = cur.runs; save();
  });
  ta.addEventListener("mouseup", () => { if (tool !== "edit") applyTool(c, ta); });
  div.addEventListener("click", e => {
    const act = e.target.dataset && e.target.dataset.act;
    if (act === "good" || act === "corrected" || act === "bad") {
      const cur = domToRuns(ta);
      s.text = cur.text; s.runs = cur.runs; s.status = act;
      save();
      div.className = "card" + statusClass(act);
    }
  });
  return div;
}
// place the caret at a text offset inside a .ta (used to restore the cursor after
// a paint/token operation rewrites innerHTML — otherwise it falls back to the start)
function setCaret(div, pos){
  const walker = document.createTreeWalker(div, NodeFilter.SHOW_TEXT);
  let total = 0, node;
  while ((node = walker.nextNode())) {
    const len = node.textContent.length;
    if (total + len >= pos) {
      const r = document.createRange();
      r.setStart(node, Math.max(0, pos - total)); r.collapse(true);
      const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
      div.focus();
      return;
    }
    total += len;
  }
}

// ---- export: turns derived from role runs; unclear runs wrap as [unclear]...[/unclear] ----
function exportRow(c){
  const s = get(c);
  const n = s.text.length;
  const role = new Array(n).fill(null), unc = new Array(n).fill(false);
  s.runs.forEach(r => { for (let i = r.s; i < Math.min(n, r.e); i++) { if (r.role) role[i] = r.role; if (r.unclear) unc[i] = true; }});
  const turns = [];
  let i = 0;
  while (i < n) {
    let j = i;
    while (j < n && role[j] === role[i]) j++;
    let seg = "";
    let k = i;
    while (k < j) {
      if (unc[k]) { let m = k; while (m < j && unc[m]) m++; seg += "[unclear]" + s.text.slice(k, m) + "[/unclear]"; k = m; }
      else { let m = k; while (m < j && !unc[m]) m++; seg += s.text.slice(k, m); k = m; }
    }
    seg = seg.trim();
    if (seg) turns.push({ text: seg, role: role[i] ?? "unk", callsign: "" });
    i = j;
  }
  return { n: c.n, id: c.id, airport: c.airport, feed: c.feed, draft: c.draft,
           turns, corrected: turns.map(t => t.text).join(" "),
           status: s.status ?? "unreviewed" };
}
function exportJson(){
  const out = DATA.map(exportRow);
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([JSON.stringify(out, null, 1)], {type: "application/json"}));
  a.download = "corrections_v1.json"; a.click();
}

// ---- toolbar + hotkeys ----
function setTool(t){
  tool = t;
  document.querySelectorAll(".tool").forEach(b =>
    b.classList.toggle("active", b.dataset.tool === t));
}
document.querySelectorAll(".tool").forEach(b => b.addEventListener("click", () => {
  if (b.dataset.tool === "token") {
    // one-shot action on the current selection's card
    const sel = window.getSelection();
    const ta = sel.anchorNode && (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement)?.closest(".ta");
    if (ta) { const prev = tool; tool = "token"; applyTool(DATA[cardIndex(ta)], ta); tool = prev; }
    return;
  }
  setTool(b.dataset.tool);
}));
function cardIndex(ta){
  const cards = [...document.querySelectorAll(".card")];
  return cards.findIndex(cd => cd.contains(ta));
}
document.addEventListener("keydown", e => {
  // Role hotkeys match the PHYSICAL key (e.code), so macOS Option+digit — which would type
  // the special chars ¡™£¢ — still labels correctly, and we always preventDefault so nothing leaks.
  const roleByDigit = { "1": "ctl", "2": "acft", "3": "unclear", "4": "erase" };
  const roleByLetter = { "KeyC": "ctl", "KeyA": "acft", "KeyU": "unclear", "KeyE": "erase" };
  const digit = (e.code || "").startsWith("Digit") ? e.code.slice(5) : null;

  // Is there a live (non-empty) word selection inside a transcript?
  const sel = window.getSelection();
  const anchorEl = sel && sel.anchorNode
    ? (sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement) : null;
  const hasSel = sel && !sel.isCollapsed && sel.toString().trim() && anchorEl && anchorEl.closest(".ta");

  // (A) Option/Control + digit — one-shot label (macOS-safe via e.code; never leaks a special char).
  if ((e.altKey || e.ctrlKey) && !e.metaKey && roleByDigit[digit]) {
    e.preventDefault(); applyToolOnce(roleByDigit[digit]); return;
  }
  // (B) NO modifier: with words selected, 1/2/3/4 or C/A/U/E labels them. The Mac-native path.
  if (hasSel && !e.altKey && !e.ctrlKey && !e.metaKey) {
    const role = roleByDigit[digit] || roleByLetter[e.code];
    if (role) { e.preventDefault(); applyToolOnce(role); return; }
  }
  // (C) mid-correction typing — never hijack the keystroke
  if (anchorEl && anchorEl.closest(".ta") && tool === "edit") {
    if (e.key === "Escape") setTool("edit");
    return;
  }
  // (D) no selection, not typing: a bare digit arms the paint tool
  const map = { "0": "edit", "1": "ctl", "2": "acft", "3": "unclear", "4": "erase", "Escape": "edit" };
  if (map[e.key]) setTool(map[e.key]);
});
function renderAll(){
  const root = document.getElementById("cards"); root.innerHTML = "";
  DATA.forEach(c => root.appendChild(card(c)));
  renderProgress();
}
setTool("edit");
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
