#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Parse wave.vcd and plot KO positions (service layer / fgOTN, global monotonic)."""
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def parse_vcd(path):
    """Return list of (time_us, sf_row, sf_col, sf_frame, fg_row, fg_col, fg_frame)."""
    id_to_name = {}
    name_to_id = {}
    vals = {}
    events = []
    cur_time = 0
    timescale_ps = 1
    last_vld = 0
    pending = []

    def flush():
        nonlocal last_vld
        for _, ln in pending:
            ln = ln.strip()
            if ln.startswith("b"):
                val, idc = ln[1:].split()
                vals[idc] = int(val, 2) if val else 0
            else:
                val, idc = ln[0], ln[1:]
                vals[idc] = 1 if val == "1" else 0
        if name_to_id.get("vld") in vals:
            now = vals[name_to_id["vld"]]
            if now == 1 and last_vld == 0:
                events.append((
                    pending[0][0],
                    vals.get(name_to_id.get("sf_row", ""), 0),
                    vals.get(name_to_id.get("sf_col", ""), 0),
                    vals.get(name_to_id.get("sf_frame_idx", ""), 0),
                    vals.get(name_to_id.get("fg_row", ""), 0),
                    vals.get(name_to_id.get("fg_col", ""), 0),
                    vals.get(name_to_id.get("fg_frame_idx", ""), 0),
                ))
            last_vld = now
        pending.clear()

    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("$timescale"):
                m = re.match(r"\$timescale\s+(\d+)(ps|ns|us|ms|s)\s+\$end", line)
                if m:
                    mult = {"ps": 1, "ns": 1e3, "us": 1e6, "ms": 1e9, "s": 1e12}
                    timescale_ps = int(m.group(1)) * mult[m.group(2)]
                continue
            m = re.match(
                r"\$var wire\s+\d+\s+(\S+)\s+(\S+)(?:\s+\[\d+:\d+\])?\s+\$end", line
            )
            if m:
                id_to_name[m.group(1)] = m.group(2)
                name_to_id[m.group(2)] = m.group(1)
                continue
            if line.startswith("#"):
                flush()
                cur_time = int(line[1:])
                continue
            if line.startswith("$") or not line:
                continue
            pending.append((cur_time, line))
        flush()
    for i, e in enumerate(events):
        events[i] = (e[0] * timescale_ps / 1e6,) + e[1:]
    return events


def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else "wave.vcd"
    out = sys.argv[2] if len(sys.argv) > 2 else "ko_stim_positions.png"
    ev = parse_vcd(vcd)
    if not ev:
        print("no KO events found")
        return 1
    t_us = [e[0] for e in ev]
    sf_row = [e[1] for e in ev]
    sf_col = [e[2] for e in ev]
    sf_frame = [e[3] for e in ev]
    fg_row = [e[4] for e in ev]
    fg_col = [e[5] for e in ev]
    fg_frame = [e[6] for e in ev]
    # 全局字节偏移（行主序，含帧号）：服务层 4×4080，fgOTN 4×3824
    sf_glob = [f * 16320 + (r - 1) * 4080 + (c - 1) for f, r, c in zip(sf_frame, sf_row, sf_col)]
    fg_glob = [f * 15296 + (r - 1) * 3824 + (c - 1) for f, r, c in zip(fg_frame, fg_row, fg_col)]

    fig, axes = plt.subplots(4, 1, figsize=(11, 12))

    ax = axes[0]
    ax.stem(t_us, [1] * len(t_us), linefmt="C0-", markerfmt="C0o", basefmt=" ")
    ax.set_ylim(0, 1.4)
    ax.set_yticks([])
    ax.set_ylabel("KO vld")
    ax.set_xlabel("time (us)")
    ax.set_title("KO vld pulses (OTU2, p=119, oh_pos=16, byte-order GMP)")
    ax.grid(alpha=0.3)

    ax = axes[1]
    ax.plot(range(len(sf_glob)), sf_glob, ".-", ms=3, lw=0.6)
    ax.set_xlabel("KO sequence index")
    ax.set_ylabel("service-layer global byte offset")
    ax.set_title("Service-layer position (frame x16320 + row-major offset) - strictly increasing")
    ax.grid(alpha=0.3)

    ax = axes[2]
    ax.plot(range(len(fg_glob)), fg_glob, ".-", ms=3, lw=0.6)
    ax.set_xlabel("KO sequence index")
    ax.set_ylabel("fgOTN global byte offset")
    ax.set_title("fgOTN position (frame x15296 + row-major offset) - strictly increasing")
    ax.grid(alpha=0.3)

    ax = axes[3]
    for r in range(1, 5):
        ax.axhline(r, color="gray", lw=0.5, alpha=0.6)
    ax.scatter(sf_col, sf_row, s=12, c="C1")
    ax.set_ylim(0.5, 4.5)
    ax.set_yticks([1, 2, 3, 4])
    ax.set_xlabel("service-layer column (payload 17..3824)")
    ax.set_ylabel("service-layer row")
    ax.set_title("KO distribution inside 4x4080 service-layer frame (payload cols 17..3824)")
    ax.grid(alpha=0.3)

    fig.tight_layout()
    fig.savefig(out, dpi=150)
    print(f"saved {out}: {len(ev)} KO events, t=[{t_us[0]:.2f}..{t_us[-1]:.2f}] us")
    for i in range(min(6, len(ev))):
        e = ev[i]
        print(
            f"  #{i}: t={e[0]:.3f}us sf帧{e[3]} (r{e[1]},c{e[2]}) global={sf_glob[i]} "
            f"| fg帧{e[6]} (r{e[4]},c{e[5]}) global={fg_glob[i]}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
