"""Grounded LLM gap-fill (idea 3) — restore the PHRASEOLOGY `<unk>` gaps left by the A/B
merge (`grounded_label.merge_ab_unk`), while leaving the UNRECOVERABLE gaps as `<unk>`.

The merge marks every A/B disagreement `<unk>`. Two kinds live in there:
  * phraseology / proper-noun gaps ("line up and <unk>" -> "wait") — recoverable from ATC
    grammar + WORLD context. THIS module fills those.
  * digit / direction gaps ("runway 2 6 <unk>" for 26L-vs-261, "heading <unk>") — the audio
    information is gone; a text model would be GUESSING an altitude/runway/heading. HARD RULE:
    never fill a gap with a number or left/right/center. Those stay `<unk>` -> masked in training.

Reuses `llm_worldfix` (QwenBackend, WorldFrame). Backend model_id is swappable — the 0.5B is a
weak default for wiring/plumbing; a stronger local model or an API backend can drop in.
Every fill is VALIDATED before it is applied (agreed words frozen, no numeric/direction fills,
bounded length), so a hallucinating LLM cannot corrupt a label — worst case a gap stays `<unk>`.
"""
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from atc_normalize import normalize as _canon
from dataset.grounded_label import UNK

GAPFILL_SYSTEM = """You restore missing words in an air-traffic-control (ATC) radio transcript.
Words that two speech models disagreed on are marked <unk>. Replace each <unk> with the most
likely STANDARD ATC phraseology given the surrounding words and the WORLD data.

HARD RULES:
- NEVER replace <unk> with a number/digit or with left/right/center. Altitudes, headings,
  runways, frequencies and squawks are unrecoverable from text — leave those as <unk>.
- Change ONLY the <unk> tokens. Never alter, add, or remove any other word.
- If you cannot confidently restore a <unk> from standard phraseology or WORLD data, leave it
  as the literal token <unk>.
ATC command shapes: "[callsign] cleared to land", "line up and wait", "contact <facility>",
"hold short of runway", "taxi via", "traffic <clock> o'clock", "say again", "roger", "wilco".
Reply with ONLY the corrected transcript line — no quotes, no JSON, no explanation."""

GAPFILL_FEWSHOT = [
    ("WORLD: Callsigns: delta, united\nTRANSCRIPT: delta 2 9 8 1 frontier flight 3 3 9 7 <unk> tower runway 2 6 <unk> up and <unk>",
     "delta 2 9 8 1 frontier flight 3 3 9 7 contact tower runway 2 6 <unk> up and wait"),
    ("WORLD:\nTRANSCRIPT: <unk> 1 i <unk> thank you",
     "<unk> 1 i <unk> thank you"),
    ("WORLD: Callsigns: american\nTRANSCRIPT: american 5 1 2 <unk> to land runway 2 7",
     "american 5 1 2 cleared to land runway 2 7"),
]

# after canonicalization spoken numbers are digits, so "any digit char" catches 27 AND "two seven".
_DIRECTION = {"left", "right", "center"}
_MAX_FILL_TOKENS = 4


def _canon_toks(s: str) -> list:
    return _canon(s or "").split()


def _bad_fill(fill_tokens: list) -> bool:
    """A fill is rejected if empty, too long, or contains a number/direction (unrecoverable)."""
    if not fill_tokens or len(fill_tokens) > _MAX_FILL_TOKENS:
        return True
    joined = " ".join(fill_tokens)
    if any(ch.isdigit() for ch in _canon(joined)):
        return True
    if any(t in _DIRECTION for t in fill_tokens):
        return True
    if UNK in fill_tokens:
        return True
    return False


def validate_fill(holed: str, llm_out: str) -> tuple:
    """Apply only the safe subset of the LLM's fills. Returns (filled_label, n_filled).

    Aligns the model output to the holed label; the non-<unk> ("agreed") tokens MUST survive
    unchanged (else the model rewrote content it shouldn't have -> reject that span, keep <unk>).
    Each <unk> may be replaced only by a validated non-numeric phraseology fill.
    """
    h = holed.split()
    # canon strips the <> off the model's own "<unk>" -> "unk"; map it back so an unfilled gap
    # is recognized as UNK (matches the holed <unk>, and _bad_fill rejects it) not a bogus fill.
    o = [UNK if t == "unk" else t for t in _canon_toks(llm_out)]
    if not o:
        return holed, 0
    sm = difflib.SequenceMatcher(a=h, b=o, autojunk=False)
    out: list = []
    n_filled = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        seg_h = h[i1:i2]
        seg_o = o[j1:j2]
        if tag == "equal":
            out.extend(seg_h)
            continue
        # a changed span. Only accept it if EVERY holed token in it is <unk> (agreed words frozen).
        if seg_h and all(t == UNK for t in seg_h):
            if len(seg_h) == 1 and not _bad_fill(seg_o):
                out.extend(seg_o)
                n_filled += 1
            else:
                out.extend(seg_h)          # multi-<unk> or bad fill -> leave as-is
        else:
            out.extend(seg_h)              # model touched a non-<unk> word -> reject, keep holed
    return " ".join(out), n_filled


def _messages(world: str, transcript: str) -> list:
    msgs = [{"role": "system", "content": GAPFILL_SYSTEM}]
    for u, a in GAPFILL_FEWSHOT:
        msgs.append({"role": "user", "content": u})
        msgs.append({"role": "assistant", "content": a})
    msgs.append({"role": "user", "content": f"WORLD: {world}\nTRANSCRIPT: {transcript}"})
    return msgs


class GapFiller:
    """LLM gap-filler with a swappable backend.

    backend='mlx'  -> mlx-lm on the Apple GPU (default). The teacher is OFFLINE, so on a 64 GB
                      M1 Max we run a big model (Qwen2.5-32B-4bit ~18 GB) — no on-device size limit.
    backend='hf'   -> transformers/torch (the 0.5B on-device mirror), for parity checks only.
    """
    def __init__(self, model_id: str = "mlx-community/Qwen2.5-32B-Instruct-4bit",
                 backend: str = "mlx"):
        self.kind = backend
        self.model_id = model_id
        if backend == "mlx":
            from mlx_lm import load
            self._model, self._tok = load(model_id)
        else:
            from llm_worldfix import QwenBackend
            self._hf = QwenBackend(model_id=model_id)

    def _generate(self, world: str, transcript: str, max_new_tokens: int = 64) -> str:
        msgs = _messages(world, transcript)
        if self.kind == "mlx":
            from mlx_lm import generate
            prompt = self._tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
            return generate(self._model, self._tok, prompt=prompt,
                            max_tokens=max_new_tokens, verbose=False).strip()
        b = self._hf
        text = b.tok.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
        inputs = b.tok(text, return_tensors="pt")
        with b.torch.inference_mode():
            out = b.model.generate(**inputs, max_new_tokens=max_new_tokens, do_sample=False,
                                   pad_token_id=b.tok.eos_token_id)
        return b.tok.decode(out[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True).strip()

    def fill(self, holed_label: str, world: str = "") -> tuple:
        """Return (filled_label, n_filled). No-op (0 fills) if the label has no <unk>."""
        if UNK not in holed_label.split():
            return holed_label, 0
        try:
            raw = self._generate(world, holed_label)
        except Exception:
            return holed_label, 0
        raw = raw.splitlines()[0] if raw else ""
        return validate_fill(holed_label, raw)


# ---------------------------------------------------------------------------
# full run: gap-fill the whole us_grounded set -> manifest_filled.jsonl (resumable)
# ---------------------------------------------------------------------------

GROUNDED_MAN = "/Users/bsusl/CommSight/atc-data/us_grounded/manifest.jsonl"
FILLED_MAN = "/Users/bsusl/CommSight/atc-data/us_grounded/manifest_filled.jsonl"
EXCLUDED = "/Users/bsusl/CommSight/atc-data/excluded_blocks_gold.txt"


def _load_excluded() -> set:
    try:
        return {ln.strip() for ln in open(EXCLUDED) if ln.strip()}
    except Exception:
        return set()


def _world_for(src_block: str, traffic: dict) -> str:
    from dataset.grounded_label import _airlines_from_spoken
    airlines = _airlines_from_spoken(traffic.get(src_block) or [])
    return "Callsigns: " + ", ".join(airlines[:20]) if airlines else ""


def run_full(model_id: str, gold_safe: bool = True, limit: int = 0, max_unk: int = 6) -> dict:
    """Gap-fill every gold-safe us_grounded clip; append to manifest_filled.jsonl. Resumable:
    already-filled ids are skipped, so re-launching continues where it left off."""
    import json
    import time
    from dataset.grounded_relabel import load_traffic_index

    excluded = _load_excluded() if gold_safe else set()
    traffic = load_traffic_index()
    rows = [json.loads(ln) for ln in open(GROUNDED_MAN) if ln.strip()]
    done = set()
    try:
        done = {json.loads(ln)["id"] for ln in open(FILLED_MAN) if ln.strip()}
    except Exception:
        pass
    print(f"loading {model_id} ...", flush=True)
    gf = GapFiller(model_id=model_id)
    print(f"model ready [{gf.kind}]; {len(rows)} grounded clips, {len(done)} already filled", flush=True)
    out = open(FILLED_MAN, "a")
    st = dict(seen=0, skipped_gold=0, skipped_done=0, gaps=0, gaps_filled=0, clean_out=0, processed=0)
    t0 = time.time()
    for r in rows:
        st["seen"] += 1
        if r["id"] in done:
            st["skipped_done"] += 1
            continue
        if gold_safe and r.get("src_block") in excluded:
            st["skipped_gold"] += 1
            continue
        n_unk = int(r.get("unk", 0) or 0)
        text = r["text"]
        if n_unk == 0 or n_unk > max_unk:
            filled, nf = text, 0        # clean already, or too holed to trust a fill
        else:
            filled, nf = gf.fill(text, world=_world_for(r.get("src_block"), traffic))
        residual = filled.split().count(UNK)
        rec = dict(r); rec["text"] = filled; rec["residual_unk"] = residual; rec["gaps_filled"] = nf
        out.write(json.dumps(rec) + "\n"); out.flush()
        st["processed"] += 1; st["gaps"] += n_unk; st["gaps_filled"] += nf
        if residual == 0:
            st["clean_out"] += 1
        if st["processed"] % 250 == 0:
            el = time.time() - t0
            rate = st["processed"] / max(1, el)
            print(f"  {st['processed']} done · {st['gaps_filled']} gaps filled · {st['clean_out']} clean "
                  f"· {rate:.2f}/s · {el:.0f}s", flush=True)
        if limit and st["processed"] >= limit:
            break
    out.close()
    return st


if __name__ == "__main__":
    import argparse
    import json
    import random

    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true", help="gap-fill the whole gold-safe us_grounded set")
    ap.add_argument("--model", default="mlx-community/Qwen2.5-14B-Instruct-4bit")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()

    if a.full:
        s = run_full(a.model, gold_safe=True, limit=a.limit)
        print("\n=== FULL GAP-FILL DONE ===")
        print(f"  processed {s['processed']} · filled {s['gaps_filled']}/{s['gaps']} gaps · "
              f"{s['clean_out']} clean-out clips · skipped {s['skipped_gold']} gold / {s['skipped_done']} done")
        print(f"  -> {FILLED_MAN}")
    else:
        rows = [json.loads(ln) for ln in open(GROUNDED_MAN) if ln.strip()]
        holed = [r for r in rows if r.get("unk", 0) >= 1 and r["agreement"] >= 0.7]
        random.seed(3)
        sample = random.sample(holed, 12)
        print(f"loading {a.model} ... {len(holed)} <unk> clips in us_grounded", flush=True)
        gf = GapFiller(model_id=a.model)
        tot_gaps = tot_filled = 0
        for r in sample:
            after, n = gf.fill(r["text"], world="")
            tot_gaps += r["text"].split().count(UNK); tot_filled += n
            if n:
                print(f"\n[{r['id']}] filled {n}\n  before: {r['text'][:100]}\n  after : {after[:100]}")
        print(f"\n=== filled {tot_filled}/{tot_gaps} gaps across {len(sample)} clips [{gf.model_id}] ===")
