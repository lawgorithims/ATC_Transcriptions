"""Offline mirror of the iOS world-model LLM correction tier, for gold-set benchmarking.

Mirrors `ios/ATCTranscribe/Core/ATCCorrectionPrompt.swift` (system role, few-shots,
WorldFrame slot order) and the `CorrectionValidator` guardrails closely enough to measure
the tier's correction-quality effect on the gold set. UPDATE TOGETHER with the Swift file.

Backend: HF transformers Qwen2.5-0.5B-Instruct on CPU (same weights the app runs as a
q4_k_m GGUF — this harness is therefore slightly OPTIMISTIC vs on-device quantized).
"""

from __future__ import annotations

import difflib
import json
import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from atc_normalize import normalize as _canon
from slot_snap import RUNWAY_RX

SYSTEM = """You correct speech-model transcription errors in air-traffic-control (ATC) radio transcripts. Each request carries a WORLD block of live, deterministic data; use it.

ATC speech is a constrained protocol. Nearly every transmission fits these command shapes:
- [callsign] climb / descend and maintain <altitude>; maintain flight level <D D D>
- [callsign] turn left/right heading <D D D>; fly heading <D D D>
- [callsign] contact|monitor <facility> <frequency>
- [callsign] squawk <D D D D> (each digit 0-7) ; ident
- [callsign] cleared to land / cleared for takeoff / line up and wait runway <RR L|C|R>
- [callsign] hold short of runway <RR>; cross runway <RR>; taxi via <taxiways>
- [callsign] reduce/increase speed to <D D D>; maintain <D D D> knots
- wind <D D D> at <D D>; altimeter <D D D D>; traffic <clock position> <distance> miles
A pilot transmission is usually a READBACK: the instruction's values echoed back, usually ending with the callsign. Spoken digits use niner/tree/fife; runways are two digits plus optional left/right/center.

Rules, in priority order:
1. WORLD lines marked "Verified" are ground truth from live data — NEVER alter them.
2. Snap a garbled word to the term its grammar slot expects, when WORLD data (runways, fixes, facility names, aircraft on frequency) makes the intent clear — e.g. a mangled word directly before a frequency is the facility name; a mangled word after "cleared to land runway" is a runway from the WORLD list.
3. If "Expected readback" is present and this transmission echoes it, prefer wording consistent with that instruction — but NEVER copy its digits over the transcript's digits: if the values disagree, leave the transcript's digits exactly as heard.
4. Preserve every digit exactly (headings, altitudes, frequencies, squawks, callsign numbers). Never invent content. Make the MINIMUM edits. Items marked "unverified" may be fixed only with strong WORLD evidence; when unsure, leave text unchanged.
Reply with ONLY a JSON object: {"edits": [{"from": "<original>", "to": "<fixed>", "reason": "<one or two words>"}]}. Every "from" must appear verbatim in the transcript. If nothing needs fixing, reply {"edits": []}."""

FEW_SHOT = [
    ("WORLD:\nCallsigns: Delta\nTRANSCRIPT: delta eight ninety runway runway three four left",
     '{"edits": [{"from": "runway runway", "to": "runway", "reason": "repeat"}]}'),
    ("WORLD:\nRunways: 27, 9\nTRANSCRIPT: united five twelve cleared to land runway two seven then left henning two niner zero",
     '{"edits": [{"from": "henning", "to": "heading", "reason": "grammar"}]}'),
    ("WORLD:\nFacility names: Kennedy\nVerified against live data (do NOT alter): frequency 132.4.\nTRANSCRIPT: skywest fifty six seventy contact kenedy departure one three two point four",
     '{"edits": [{"from": "kenedy", "to": "kennedy", "reason": "facility"}]}'),
    ('WORLD:\nExpected readback — prior transmission for this aircraft: "delta two thirty two descend and maintain one one thousand"\nTRANSCRIPT: down two one one thousand delta two thirty two',
     '{"edits": [{"from": "down two", "to": "down to", "reason": "readback"}]}'),
    ("WORLD:\nRunways: 17C, 35C\nVerified against live data (do NOT alter): callsign american 1 2 3 4; runway 17 center.\nTRANSCRIPT: american twelve thirty four cleared to land runway one seven center",
     '{"edits": []}'),
]


@dataclass
class WorldFrame:
    knowledge: str = ""
    grounding_block: str = ""       # pre-rendered SnapGrounding.promptBlock equivalent
    expected_readback: Optional[str] = None
    history: List[str] = field(default_factory=list)
    transcript: str = ""

    def rendered(self) -> str:
        lines = ["WORLD:"]
        if self.knowledge:
            lines.append(self.knowledge)
        if self.grounding_block:
            lines.append(self.grounding_block)
        if self.expected_readback:
            lines.append("Expected readback — prior transmission for this aircraft: "
                         f"\"{self.expected_readback}\"")
        if self.history:
            lines.append("Recent transmissions: " + " ".join(self.history))
        lines.append("TRANSCRIPT: " + self.transcript)
        return "\n".join(lines)


def chat_messages(frame: WorldFrame) -> List[dict]:
    msgs = [{"role": "system", "content": SYSTEM}]
    for user, assistant in FEW_SHOT:
        msgs.append({"role": "user", "content": user})
        msgs.append({"role": "assistant", "content": assistant})
    msgs.append({"role": "user", "content": frame.rendered()})
    return msgs


# ---------------------------------------------------------------------------
# validator mirror (CorrectionValidator's core guards)
# ---------------------------------------------------------------------------

def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", "", s.lower())).strip()


def _digits(s: str) -> str:
    return "".join(c for c in s if c.isdigit())


def _runway_keys(text: str) -> set:
    out = set()
    for m in RUNWAY_RX.finditer(_canon(text)):
        num = m.group(1).replace(" ", "").lstrip("0") or "0"
        word = (m.group(2) or "").strip()
        out.add(num + "|" + {"left": "L", "right": "R", "center": "C"}.get(word, ""))
    return out


def apply_validated(raw: str, edits: List[dict], allowed: set,
                    grounded_runways: Optional[set], max_edits: int = 8) -> tuple:
    """Apply the safe subset of edits to raw; returns (text, applied_edits)."""
    if not edits or len(edits) > max_edits:
        return raw, []
    tokens = raw.split()
    applied = []
    for e in edits:
        frm, to = (e.get("from") or "").strip(), (e.get("to") or "").strip()
        if not frm or not to or _norm(frm) == _norm(to):
            continue
        if _digits(frm) != _digits(to):                       # numbers preserved
            continue
        to_key = _norm(to).replace(" ", "")
        near = difflib.SequenceMatcher(None, _norm(frm), _norm(to)).ratio() >= 0.55
        words_known = all(_norm(w).replace(" ", "") in allowed
                          for w in to.split()) if to.split() else False
        if not (to_key in allowed or words_known or near):    # anti-hallucination
            continue
        if grounded_runways is not None:                       # runway veto
            introduced = _runway_keys(to) - _runway_keys(frm)
            if introduced and not introduced <= grounded_runways:
                continue
        # applicable: token-aligned first occurrence
        ftoks = [_norm(w) for w in frm.split()]
        ntoks = [_norm(w) for w in tokens]
        pos = next((i for i in range(len(tokens) - len(ftoks) + 1)
                    if ntoks[i:i + len(ftoks)] == ftoks), None)
        if pos is None:
            continue
        tokens = tokens[:pos] + to.split() + tokens[pos + len(ftoks):]
        applied.append({"from": frm, "to": to, "reason": e.get("reason", "llm")})
    return " ".join(tokens), applied


def parse_edits(raw_out: str) -> List[dict]:
    start = raw_out.find("{")
    if start < 0:
        return []
    depth = 0
    for i, ch in enumerate(raw_out[start:], start):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(raw_out[start:i + 1]).get("edits") or []
                except Exception:
                    return []
    return []


# ---------------------------------------------------------------------------
# backend
# ---------------------------------------------------------------------------

class QwenBackend:
    def __init__(self, model_id: str = "Qwen/Qwen2.5-0.5B-Instruct"):
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self.tok = AutoTokenizer.from_pretrained(model_id)
        self.model = AutoModelForCausalLM.from_pretrained(
            model_id, torch_dtype=torch.float32).eval()
        self.torch = torch

    def generate(self, frame: WorldFrame, max_new_tokens: int = 96) -> str:
        text = self.tok.apply_chat_template(chat_messages(frame), tokenize=False,
                                            add_generation_prompt=True)
        inputs = self.tok(text, return_tensors="pt")
        with self.torch.inference_mode():
            out = self.model.generate(**inputs, max_new_tokens=max_new_tokens,
                                      do_sample=False,
                                      pad_token_id=self.tok.eos_token_id)
        return self.tok.decode(out[0][inputs["input_ids"].shape[1]:],
                               skip_special_tokens=True)
