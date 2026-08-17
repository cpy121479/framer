import re

p = r"C:\Users\92541\Documents\ChatGPT\framer\uvm_poe\sim\wave_koa.vcd"
name2id = {}
with open(p, "r", errors="replace") as f:
    for line in f:
        s = line.strip()
        m = re.match(r"\$var wire\s+(\d+)\s+(\S+)\s+(\S+)(?:\s+\[[\d:]+\])?\s+\$end", s)
        if m:
            name2id[m.group(3)] = m.group(2)

print("q0/emit 相关变量:", [v for v in name2id if "q0" in v or "q1" in v or "emit" in v][:30])
for nm in ("emit_vld", "q0_vld", "q1_vld", "q0_ts", "cu_done_vld", "iss_vld0"):
    if nm not in name2id:
        print(nm, "NOT IN VCD")
        continue
    i = name2id[nm]
    last = 0
    rises = 0
    with open(p, "r", errors="replace") as f:
        for line in f:
            s = line.strip()
            if s.startswith("b"):
                v, id_ = s[1:].split()
            elif re.match(r"^[01xXzZ]", s):
                v, id_ = s[0], s[1:]
            else:
                continue
            if id_ == i:
                val = 1 if v == "1" else 0
                if val == 1 and last == 0:
                    rises += 1
                last = val
    print(nm, "上升", rises)
