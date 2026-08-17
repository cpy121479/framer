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
    row = {nm: vals.get(name_to_id.get(nm, ""), -1) for nm in
           ("u_e_vld", "u_e_pri", "u_i_vld", "u_i_pri", "out_vld", "out_pri", "out_src")}
    if row["u_e_vld"] == 1 and last.get("u_e_vld", 0) == 0:
        events.append((t, "U_E_IN", row["u_e_pri"]))
    if row["u_i_vld"] == 1 and last.get("u_i_vld", 0) == 0:
        events.append((t, "U_I_IN", row["u_i_pri"]))
    if row["out_vld"] == 1 and last.get("out_vld", 0) == 0 and row["out_src"] == 3:
        events.append((t, "U_E_OUT", row["out_pri"]))
    for nm in ("u_e_vld", "u_i_vld", "out_vld"):
        last[nm] = row[nm]
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

ue_in = [e for e in events if e[1] == "U_E_IN"]
ue_out = [e for e in events if e[1] == "U_E_OUT"]
ui_in = [e for e in events if e[1] == "U_I_IN"]
print("U_E_IN count:", len(ue_in), "first:", ue_in[:5], "last:", ue_in[-3:])
print("U_E_OUT count:", len(ue_out), "first:", ue_out[:5], "last:", ue_out[-3:])
print("U_I_IN count:", len(ui_in))
# 检查 u_e 输入是否有非 7
non7 = [e for e in ue_in if e[2] != 7]
print("U_E_IN pri!=7 count:", len(non7), "sample:", non7[:5])
# 检查输出 pri!=7
out_non7 = [e for e in ue_out if e[2] != 7]
print("U_E_OUT pri!=7 count:", len(out_non7), "sample:", out_non7[:5])
from collections import Counter
print("U_E_OUT pri dist:", Counter(e[2] for e in ue_out))
print("U_I_IN pri dist:", Counter(e[2] for e in ui_in))
# 22.85us 附近
print("around 22.85us U_E_IN:", [e for e in ue_in if 22800000 < e[0] < 22950000])
print("around 22.85us U_E_OUT:", [e for e in ue_out if 22800000 < e[0] < 22950000])
