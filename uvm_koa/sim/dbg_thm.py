import re

p = r"C:\Users\92541\Documents\ChatGPT\framer\uvm_koa\sim\wave_koa.vcd"
id_to_name = {}
name_to_id = {}
vals = {}
last = {}
pending = []
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
    for nm in ("ko_vld", "ko_rdy", "iss_vld0", "iss_vld1", "cu_done_vld", "ready_mask"):
        i = name_to_id.get(nm, "")
        v = vals.get(i, -1)
        if v != -1 and nm in last and v != last[nm]:
            events.append((t, nm, last[nm], v))
        if v != -1:
            last[nm] = v
    pending.clear()


with open(p, "r", errors="replace") as f:
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

for nm in ("ko_vld", "ko_rdy", "iss_vld0", "iss_vld1", "cu_done_vld"):
    se = [e for e in events if e[1] == nm]
    rises = [e for e in se if e[2] == 0 and e[3] == 1]
    print(f"{nm}: 变化 {len(se)} 次，上升 {len(rises)} 次，首次 {rises[:2]}")

# th_wait（branch 预取等待计数）活动
wait_events = [e for e in events if "th_wait" in e[1]]
print(f"th_wait 相关信号变化 {len(wait_events)} 次（branch 预取等待活动）")
bs_events = [e for e in events if "th_branch_seq" in e[1] or "th_br_r" in e[1]]
print(f"th_branch_seq/th_br_r 变化 {len(bs_events)} 次")
st_events = [e for e in events if "th_state" in e[1]]
print(f"th_state 变化 {len(st_events)} 次")
names = [v for v in name_to_id if "th_" in v or "thm" in v.lower() or "branch" in v or "wait" in v]
print("VCD 中相关变量:", names[:40])
for nm in ("th_ts_cnt", "th_bs_cnt", "th_pri", "th_branch_seq"):
    se = [e for e in events if e[1] == nm]
    print(f"{nm}: 变化 {len(se)} 次")
rm = [e for e in events if e[1] == "ready_mask"]
print(f"ready_mask 变化 {len(rm)} 次，示例 {rm[:3]}")
# 统计 ready_mask 各值的 popcount
pc = {}
maxpc = 0
cur_rm = 0
for t, nm, old, new in sorted(events):
    if nm == "ready_mask":
        cur_rm = new
        c = bin(new).count("1")
        maxpc = max(maxpc, c)
        pc[c] = pc.get(c, 0) + 1
print(f"ready_mask popcount 峰值={maxpc}，分布={dict(sorted(pc.items()))}")
