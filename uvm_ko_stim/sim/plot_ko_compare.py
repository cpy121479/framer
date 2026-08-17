#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Compare KO vld pulse patterns: single p=119 vs 119x p=1 (skewed/centered)."""
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def vld_times(path):
    id_to_name = {}
    name_to_id = {}
    vals = {}
    times = []
    cur = 0
    ts = 1
    last = 0
    pending = []

    def flush():
        nonlocal last
        for _, ln in pending:
            ln = ln.strip()
            if ln.startswith("b"):
                v, i = ln[1:].split()
                vals[i] = int(v, 2) if v else 0
            else:
                i = ln[1:]
                vals[i] = 1 if ln[0] == "1" else 0
        if name_to_id.get("vld") in vals:
            now = vals[name_to_id["vld"]]
            if now == 1 and last == 0:
                times.append(pending[0][0])
            last = now
        pending.clear()

    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            m = re.match(r"\$timescale\s+(\d+)(ps|ns|us|ms|s)\s+\$end", line)
            if m:
                mult = {"ps": 1, "ns": 1e3, "us": 1e6, "ms": 1e9, "s": 1e12}
                ts = int(m.group(1)) * mult[m.group(2)]
                continue
            m = re.match(r"\$var wire\s+\d+\s+(\S+)\s+(\S+)(?:\s+\[\d+:\d+\])?\s+\$end", line)
            if m:
                id_to_name[m.group(1)] = m.group(2)
                name_to_id[m.group(2)] = m.group(1)
                continue
            if line.startswith("#"):
                flush()
                cur = int(line[1:])
                continue
            if line.startswith("$") or not line:
                continue
            pending.append((cur, line))
        flush()
    return [t * ts / 1e6 for t in times]


def main():
    f1 = sys.argv[1] if len(sys.argv) > 1 else "wave_sc1.vcd"
    f2 = sys.argv[2] if len(sys.argv) > 2 else "wave_sc2.vcd"
    f3 = sys.argv[3] if len(sys.argv) > 3 else "wave_sc3.vcd"
    out = sys.argv[4] if len(sys.argv) > 4 else "compare_vld.png"
    t1 = vld_times(f1)
    t2 = vld_times(f2)
    t3 = vld_times(f3)
    fig, axes = plt.subplots(3, 1, figsize=(12, 9), sharex=True)
    axes[0].stem(t1, [1] * len(t1), linefmt="C0-", markerfmt="C0o", basefmt=" ")
    axes[0].set_title(f"Scenario 1: single fgOTN(119) on ODU2 - {len(t1)} KOs (8 bursts per 98.8us)")
    axes[0].set_ylim(0, 1.4)
    axes[0].set_yticks([])
    axes[1].stem(t2, [1] * len(t2), linefmt="C1-", markerfmt="C1o", basefmt=" ")
    axes[1].set_title(f"Scenario 2: 119x fgOTN(1) phase-SKEWED on ODU2 - {len(t2)} KOs")
    axes[1].set_ylim(0, 1.4)
    axes[1].set_yticks([])
    axes[2].stem(t3, [1] * len(t3), linefmt="C2-", markerfmt="C2o", basefmt=" ")
    axes[2].set_title(f"Scenario 3: 119x fgOTN(1) phase-CENTERED on ODU2 - {len(t3)} KOs (119-deep bursts)")
    axes[2].set_ylim(0, 1.4)
    axes[2].set_yticks([])
    axes[2].set_xlabel("time (us)")
    for ax in axes:
        ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    print(f"saved {out}: sc1={len(t1)} KOs, sc2={len(t2)} KOs, sc3={len(t3)} KOs "
          f"({t3[-1]:.2f}us)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
