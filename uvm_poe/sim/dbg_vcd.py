import re

p = r"C:\Users\92541\Documents\ChatGPT\framer\uvm_poe\sim\wave_koa.vcd"
id_to_name = {}
name_to_id = {}
vals = {}
cur = 0
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
    for name in ("fg_vld", "fg_rdy", "u_vld", "u_rdy", "out_vld", "out_src", "out_pri"):
        i = name_to_id.get(name, "")
        v = vals.get(i, -1)
        if name in last and v != -1 and v != last[name]:
            events.append((t, name, last[name], v))
        if v != -1:
            last[name] = v
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

for name in ("fg_vld", "fg_rdy", "u_vld", "u_rdy", "out_vld"):
    se = [e for e in events if e[1] == name]
    print(name, "transitions:", len(se), "first:", se[:3], "last:", se[-2:])

out = [e for e in events if e[1] == "out_vld" and e[3] == 1]
print("out_vld rising edges:", len(out), "first:", out[:3])
