#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立验证 KOA 输出序列是否符合 SP+RR（直接解析 VCD，绕开 UVM scoreboard）."""
import re
import sys
from collections import deque


def parse_vcd(path):
    id_to_name = {}
    name_to_id = {}
    vals = {}
    pending = []
    cur = 0
    last = {}
    events = []

    def flush():
        if not pending:
            return
        for _, ln in pending:
            ln = ln.strip()
            if ln.startswith("b"):
                v, i = ln[1:].split()
                vals[i] = int(v, 2) if v else 0
            else:
                i = ln[1:]
                vals[i] = 1 if ln[0] == "1" else 0
        t = pending[0][0]
        row = {}
        for nm in ("fg_vld", "fg_pri", "u_vld", "u_pri", "out_vld", "out_pri", "out_src"):
            i = name_to_id.get(nm, "")
            row[nm] = vals.get(i, -1)
        if row["fg_vld"] not in (-1, 0) and row["fg_vld"] != last.get("fg_vld", 0):
            v = row["fg_vld"]
            for p in range(4):
                if (v >> p) & 1:
                    pr = (row["fg_pri"] >> (p * 3)) & 7
                    events.append((t, "FG", p, pr))
        if row["u_vld"] == 1 and last.get("u_vld", 0) == 0:
            events.append((t, "U", 0, row["u_pri"]))
        if row["out_vld"] == 1 and last.get("out_vld", 0) == 0:
            events.append((t, "O", row["out_src"], row["out_pri"]))
        for nm in ("fg_vld", "u_vld", "out_vld"):
            last[nm] = row[nm]
        pending.clear()

    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip()
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
    events.sort(key=lambda e: e[0])
    return events


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "wave_koa.vcd"
    ev = parse_vcd(path)
    fg_in = [(t, pri) for t, k, a, pri in ev if k == "FG"]
    fg_out = [(t, pri) for t, k, a, pri in ev if k == "O" and a == 1]
    u_in = [(t, pri) for t, k, a, pri in ev if k == "U"]
    u_out = [(t, pri) for t, k, a, pri in ev if k == "O" and a == 0]
    print("FG in :", fg_in[:10])
    print("FG out:", fg_out[:10])
    print("U in :", u_in[:10])
    print("U out:", u_out[:10])
    fg_q = deque()
    u_q = deque()
    rr = 0
    bad = 0
    total_out = 0
    for t, kind, arg1, pri in ev:
        if kind == "FG":
            fg_q.append(pri)
        elif kind == "U":
            u_q.append(pri)
        else:
            total_out += 1
            if fg_q and u_q:
                if fg_q[0] < u_q[0]:
                    exp, exp_src = fg_q[0], "FG"
                elif fg_q[0] > u_q[0]:
                    exp, exp_src = u_q[0], "U"
                else:
                    exp = fg_q[0]
                    exp_src = "U" if rr else "FG"
                    rr = 1 - rr
            elif fg_q:
                exp, exp_src = fg_q[0], "FG"
            elif u_q:
                exp, exp_src = u_q[0], "U"
            else:
                print(f"@{t}: output with both queues empty")
                bad += 1
                continue
            got_src = "FG" if arg1 == 1 else "U"
            if got_src != exp_src or pri != exp:
                bad += 1
                if bad <= 8:
                    print(f"@{t}: got src={got_src} pri={pri} exp src={exp_src} pri={exp} "
                          f"fgq={list(fg_q)[:4]} uq={list(u_q)[:4]} rr={rr}")
            if exp_src == "FG":
                fg_q.popleft()
            else:
                u_q.popleft()
    print(f"total_out={total_out} mismatches={bad} leftover fg={len(fg_q)} u={len(u_q)}")


if __name__ == "__main__":
    sys.exit(main())
