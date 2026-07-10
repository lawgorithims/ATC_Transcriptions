#!/usr/bin/env python3
"""eval_speaker_clusters.py — Tier-2 speaker-clustering validation (Tier-A PROXY).

No acoustic speaker ground truth exists (the gold sets carry only text-derived role tags),
so this is a PROXY gate: it scores the acoustic clusters against the content-derived role
(controller/pilot) — a 2-class sanity check, NOT an open-set clustering-purity number.

Reports: cluster count/size structure, size-weighted role-purity, controller-voice-cluster
quality (callsign diversity = a controller talks to many aircraft), singleton rate, and the
Tier-A role-agreement proxy. Honest ceiling: this validates "does a coherent controller voice
emerge per session", not per-pilot identity. The real number needs the ~300-clip annotated
Tier-B set (extend gold_builder's review.html span-painter with a speaker index).
"""
import argparse
import json
import os
import statistics as st
from collections import Counter, defaultdict


def load(path):
    return [json.loads(l) for l in open(path) if l.strip()]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--clusters",
                    default=os.path.expanduser("~/CommSight/atc-data/us_pseudo/speaker_clusters.jsonl"))
    a = ap.parse_args(argv)
    rows = load(a.clusters)
    by_cluster = defaultdict(list)
    for r in rows:
        by_cluster[r["speaker_id"]].append(r)
    sessions = {r["speaker_cluster_scope"] for r in rows}
    feeds = {s.split("#")[0] for s in sessions}

    print(f"segments labeled : {len(rows)}")
    print(f"feeds / sessions / clusters : {len(feeds)} / {len(sessions)} / {len(by_cluster)}")

    sizes = [len(v) for v in by_cluster.values()]
    singl = sum(1 for s in sizes if s == 1)
    print(f"cluster sizes    : singletons={singl} ({singl/len(by_cluster):.0%})  "
          f"n>=3={sum(1 for s in sizes if s >= 3)}  max={max(sizes)}")

    tot = correct = 0
    for v in by_cluster.values():
        tot += len(v)
        correct += Counter(r["role"] for r in v).most_common(1)[0][1]
    print(f"role-purity      : {correct/tot:.0%}  (size-weighted; how single-role clusters are)")

    ctrl = [v for v in by_cluster.values()
            if v[0]["speaker_role_affinity"] == "controller" and len(v) >= 3]
    if ctrl:
        purs = [sum(1 for r in v if r["role"] == "controller") / len(v) for v in ctrl]
        divs = [len({r["callsign"] for r in v if r["callsign"]}) for v in ctrl]
        print(f"controller voices: {len(ctrl)} clusters (n>=3)  mean purity={st.mean(purs):.0%}  "
              f"mean callsigns addressed={st.mean(divs):.1f}")

    n = agree = 0
    for r in rows:
        if r["role"] in ("controller", "pilot"):
            n += 1
            agree += (r["speaker_role_affinity"] == r["role"])
    if n:
        print(f"Tier-A proxy     : cluster-affinity == content-role (ctrl/pilot only) "
              f"= {agree}/{n} = {agree/n:.0%}")
    print("\nNOTE: proxy only — validates controller/pilot separation, NOT per-voice purity.\n"
          "      A defensible open-set number needs the ~300-clip annotated Tier-B set.")


if __name__ == "__main__":
    main()
