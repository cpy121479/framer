#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Schematic of the byte-order GMP mapping: fgOTN frame -> service-layer OTN frame."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

# 与 ko_tb_config 默认一致的参数
FG_COLS = 3824
FG_ROWS = 4
FG_BYTES = FG_COLS * FG_ROWS          # 15296
SF_COLS = 3824                        # ODU 帧 4×3824
SF_ROWS = 4
SF_BYTES = SF_COLS * SF_ROWS          # 15296
N_SLOTS = 119
FG_RATE_PER_SLOT = 10.409203e6
ODU_RATE = 10.037273924e9             # ODU2
OH_POS = 8

T_FG = FG_BYTES * 8 / (N_SLOTS * FG_RATE_PER_SLOT)   # s
T_SF = SF_BYTES * 8 / ODU_RATE                       # s
W = FG_BYTES * T_SF / T_FG                           # fgOTN bytes per server frame


def oh_offsets(n):
    """前 n 个开销区域的帧内偏移（每行左区偏移 0、右区偏移 1904）."""
    offs = []
    for k in range(n):
        r = k // 2
        offs.append(r * FG_COLS + (0 if k % 2 == 0 else 1904))
    return offs[:n]


def sf_rc(frac):
    rowf = frac * 4.0
    row = int(rowf) + 1
    col = 17 + int((rowf - (row - 1)) * 3808.0)
    return min(row, 4), min(col, 3824)


def draw_frame(ax, ncols, nrows, title, oh_ranges, oh_color, base_y, height):
    """Draw a frame as nrows horizontal bands with overhead regions shaded."""
    ax.set_xlim(0, ncols)
    ax.set_ylim(base_y, base_y + nrows * height)
    for r in range(nrows):
        y0 = base_y + r * height
        ax.add_patch(mpatches.Rectangle((0, y0), ncols, height, facecolor="white",
                                        edgecolor="black", lw=1))
        for lo, hi in oh_ranges:
            ax.add_patch(mpatches.Rectangle((lo, y0), hi - lo, height,
                                            facecolor=oh_color, edgecolor="none"))
    ax.set_yticks([base_y + r * height + height / 2 for r in range(nrows)])
    ax.set_yticklabels([f"row {r+1}" for r in range(nrows)])
    ax.set_xlabel("column")
    ax.set_title(title)


def main():
    out = "fgotn_gmp_mapping.png"
    fig = plt.figure(figsize=(13, 11))
    gs = fig.add_gridspec(3, 1, height_ratios=[1, 1, 0.9], hspace=0.45)

    # ---- panel 1: fgOTN 帧布局 + KO 位置 ----
    ax1 = fig.add_subplot(gs[0])
    h = 0.8
    draw_frame(ax1, FG_COLS, FG_ROWS, "fgOTN frame (4 x 3824): 8 KO regions (row L/R overhead)",
               [(0, 16), (1904, 1920)], "#f4b183", 0.0, h)
    offs = oh_offsets(OH_POS)
    for off in offs:
        row = off // FG_COLS
        col = off % FG_COLS
        ax1.plot(col, row * h + h / 2, "o", ms=5, color="C3", zorder=5)
    ax1.annotate(f"KO positions 0..{OH_POS-1}: rows 1..4 x cols 1 / 1905",
                 xy=(8, h / 2), xytext=(400, 2.6), arrowprops=dict(arrowstyle="->", lw=0.8),
                 fontsize=9)

    # ---- panel 2: 服务层帧布局 + 第一个 fgOTN 帧 KO 的落点 ----
    ax2 = fig.add_subplot(gs[1])
    draw_frame(ax2, SF_COLS, SF_ROWS,
               "Service-layer ODU frame (4 x 3824), OH cols 1..16, payload 17..3824",
               [(0, 16)], "#d9d9d9", 0.0, h)
    for off in offs:
        g = off                       # 第 0 个 fgOTN 帧
        frac = (g / W) % 1.0
        row, col = sf_rc(frac)
        ax2.plot(col, (row - 1) * h + h / 2, "o", ms=5, color="C3", zorder=5)
    ax2.annotate("8 KO bytes land here, spread across ~8 server frames (GMP)",
                 xy=(60, h / 2), xytext=(900, 2.6), arrowprops=dict(arrowstyle="->", lw=0.8),
                 fontsize=9)

    # ---- panel 3: fgOTN 帧在服务层帧内的位置漂移（GMP 相位） ----
    ax3 = fig.add_subplot(gs[2])
    ns = range(0, 16)
    fracs = [(n * FG_BYTES / W) % 1.0 for n in ns]
    ax3.plot(list(ns), fracs, "o-", ms=4, lw=0.8, color="C2")
    ax3.axhline(1.0, color="gray", lw=0.5)
    ax3.set_xlabel("fgOTN frame index N")
    ax3.set_ylabel("frac inside server frame")
    ax3.set_ylim(-0.05, 1.1)
    ax3.set_title("Drift: each fgOTN frame start advances ~8.10 server frames (frac sawtooth)")
    ax3.grid(alpha=0.3)

    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"saved {out}: T_fg={T_FG*1e6:.2f}us T_sf={T_SF*1e6:.3f}us W={W:.1f}B/sf")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
