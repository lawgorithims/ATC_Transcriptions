#!/usr/bin/env python3
"""atc_speaker_cluster.py — Tier-2 acoustic speaker clustering (offline pass).

Embed accepted ATC segments with ECAPA-TDNN, group them into per-(airport,feed) GAP-BASED
sessions (~one controller per session), cluster within each session, and emit an anonymous,
session-scoped ``speaker_id`` per segment plus a ``speaker_role_affinity`` (the cluster's
dominant Tier-1 content role). Writes ``us_pseudo/speaker_clusters.jsonl`` — it does NOT
mutate manifest.jsonl (a later promotion step folds these into the LabelDecision carrier).

Design note (from the P0 spike): clustering MUST be at tight session granularity. Per-UTC-day
dilutes across controller shift changes and collapses to noise (ctrl-ctrl vs ctrl-pilot cosine
margin ~+0.02); within a single ~10-min window it separates (~+0.10). So we sessionize on
inter-transmission gaps, and even then the signal is WEAK — treat speaker_id as a soft hint,
strongest for the recurring controller voice, near-useless for one-shot pilots.

Requires an embedding stack (speechbrain + torch + soundfile); run under the spike venv, not
the live collector's venv:
    ~/CommSight/spike-venv/bin/python -m dataset.atc_speaker_cluster --feeds KJFK/sector_9s
"""
import argparse
import json
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone

import numpy as np

_BLOCK_RE = re.compile(r"(\d{8}T\d{4})Z")  # block stamp is minute-resolution: YYYYMMDDTHHMM


def block_time(src_block):
    """UTC datetime of a block start from its id (e.g. 'sector_9s-20260709T1809Z')."""
    m = _BLOCK_RE.search(src_block or "")
    if not m:
        return None
    return datetime.strptime(m.group(1), "%Y%m%dT%H%M").replace(tzinfo=timezone.utc)


def abs_time(row):
    """Absolute wall-clock start of a transmission = block start + offset_s."""
    bt = block_time(row.get("src_block"))
    return (bt.timestamp() + float(row.get("offset_s") or 0.0)) if bt else 0.0


def clip_path(seg_root, row):
    """Reconstruct the clip path from PROVENANCE (stored audio_path has a stale host prefix)."""
    idx = row["id"].rsplit("__", 1)[1]
    return os.path.join(seg_root, row["airport"], row["feed"], row["src_block"], f"{idx}.wav")


def load_embedder(device="cpu"):
    import torch
    import soundfile as sf
    try:
        from speechbrain.inference.speaker import EncoderClassifier
    except Exception:  # older speechbrain
        from speechbrain.pretrained import EncoderClassifier
    clf = EncoderClassifier.from_hparams(
        source="speechbrain/spkrec-ecapa-voxceleb",
        savedir=os.path.expanduser("~/CommSight/spike-venv/ecapa"),
        run_opts={"device": device},
    )

    def embed(path):
        wav, _ = sf.read(path, dtype="float32")  # load via soundfile, NOT torchaudio
        if wav.ndim > 1:
            wav = wav.mean(1)
        with torch.no_grad():
            e = clf.encode_batch(torch.tensor(wav).unsqueeze(0)).squeeze().cpu().numpy()
        return e / (np.linalg.norm(e) + 1e-9)

    return embed


def sessionize(rows, gap_min):
    """Split one feed's rows (sorted by absolute time) into sessions on gaps > gap_min."""
    rows = sorted(rows, key=abs_time)
    sessions, cur, last = [], [], None
    for r in rows:
        t = abs_time(r)
        if last is not None and (t - last) > gap_min * 60.0:
            sessions.append(cur)
            cur = []
        cur.append(r)
        last = t
    if cur:
        sessions.append(cur)
    return sessions


def cluster(embs, threshold):
    from sklearn.cluster import AgglomerativeClustering
    if len(embs) < 2:
        return [0] * len(embs)
    return AgglomerativeClustering(
        metric="cosine", linkage="average",
        distance_threshold=threshold, n_clusters=None,
    ).fit(embs).labels_.tolist()


def run(data_root, gap_min, threshold, device, feeds, out_path, verbose=True):
    man = os.path.join(data_root, "us_pseudo", "manifest.jsonl")
    seg_root = os.path.join(data_root, "segments")
    rows = [json.loads(l) for l in open(man) if l.strip()]

    by_feed = defaultdict(list)
    for r in rows:
        key = f"{r.get('airport')}/{r.get('feed')}"
        if feeds and key not in feeds:
            continue
        by_feed[key].append(r)

    # P1: prefer embeddings computed at harvest (us_pseudo/embeddings.jsonl) to avoid
    # re-reading audio; only load the model / read clips for segments not covered.
    emb_path = os.path.join(data_root, "us_pseudo", "embeddings.jsonl")
    precomputed = {}
    if os.path.exists(emb_path):
        for _l in open(emb_path):
            if _l.strip():
                _e = json.loads(_l)
                precomputed[_e["id"]] = np.asarray(_e["emb"], dtype="float32")
    if verbose and precomputed:
        print(f"reusing {len(precomputed)} harvest-time embeddings from embeddings.jsonl")

    embed = None  # lazy — only load ECAPA if some clip isn't already embedded
    out_rows = []
    for key, frows in sorted(by_feed.items()):
        emb = {}
        for r in frows:
            if r["id"] in precomputed:
                emb[r["id"]] = precomputed[r["id"]]
                continue
            p = clip_path(seg_root, r)
            if os.path.exists(p):
                if embed is None:
                    embed = load_embedder(device)
                try:
                    emb[r["id"]] = embed(p)
                except Exception:
                    pass
        frows = [r for r in frows if r["id"] in emb]
        if not frows:
            continue
        sessions = sessionize(frows, gap_min)
        n_clusters = 0
        ctrl_clusters = 0
        for si, sess in enumerate(sessions):
            E = np.array([emb[r["id"]] for r in sess])
            labs = cluster(E, threshold)
            members = defaultdict(list)
            for r, l in zip(sess, labs):
                members[l].append(r)
            n_clusters += len(members)
            scope = f"{key}#sess{si}"
            for l, mem in members.items():
                roles = Counter(r.get("role") for r in mem)
                affinity = roles.most_common(1)[0][0]
                # a controller cluster = dominant role controller AND >=3 members
                if affinity == "controller" and len(mem) >= 3:
                    ctrl_clusters += 1
                for r in mem:
                    out_rows.append({
                        "id": r["id"],
                        "speaker_id": f"{scope}#spk{l}",
                        "speaker_cluster_scope": scope,
                        "speaker_role_affinity": affinity,
                        "speaker_cluster_size": len(mem),
                        "role": r.get("role"),
                        "callsign": r.get("callsign"),
                    })
        if verbose:
            print(f"{key}: {len(frows)} clips -> {len(sessions)} sessions, "
                  f"{n_clusters} clusters, {ctrl_clusters} controller-voice cluster(s)")

    if out_path:
        with open(out_path, "w") as f:
            for r in out_rows:
                f.write(json.dumps(r) + "\n")
        if verbose:
            print(f"wrote {len(out_rows)} speaker labels -> {out_path}")
    return out_rows


def main(argv=None):
    ap = argparse.ArgumentParser(description="Tier-2 acoustic speaker clustering (offline)")
    ap.add_argument("--data-root", default=os.path.expanduser("~/CommSight/atc-data"))
    ap.add_argument("--gap-min", type=float, default=20.0,
                    help="split a feed into sessions on inter-transmission gaps > this (minutes)")
    ap.add_argument("--threshold", type=float, default=0.5,
                    help="agglomerative cosine distance threshold (calibrate per receiver)")
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--feeds", nargs="*",
                    help="limit to specific airport/feed keys, e.g. KJFK/sector_9s")
    ap.add_argument("--out", default=None,
                    help="output jsonl (default: <data-root>/us_pseudo/speaker_clusters.jsonl)")
    args = ap.parse_args(argv)
    out = args.out or os.path.join(args.data_root, "us_pseudo", "speaker_clusters.jsonl")
    run(args.data_root, args.gap_min, args.threshold, args.device, args.feeds, out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
