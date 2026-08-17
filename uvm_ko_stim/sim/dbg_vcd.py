import re

p = r"C:\Users\92541\Documents\ChatGPT\framer\uvm_ko_stim\sim\wave.vcd"
sig = {}
cur = 0
last = 0
cnt = 0
edges = []
var_lines = 0
with open(p, "r", errors="replace") as f:
    for line in f:
        line = line.strip()
        m = re.match(r"\$var wire\s+\d+\s+(\S+)\s+(\S+)\s+\$end", line)
        if m:
            sig[m.group(2)] = m.group(1)
            if len(sig) <= 15:
                print("MATCH:", m.group(2), "->", m.group(1))
            continue
        if line.startswith("$var"):
            var_lines += 1
            if var_lines <= 5:
                print("RAW:", repr(line))
        if line.startswith("#"):
            cur = int(line[1:])
            continue
        if line.startswith("$") or not line:
            continue
        if line.startswith("b"):
            val, idc = line[1:].split()
        else:
            val, idc = line[0], line[1:]
        vn = sig.get(idc, idc)
        if vn == "vld":
            now = 1 if val == "1" else 0
            cnt += 1
            if now == 1 and last == 0:
                edges.append(cur)
            last = now
print("vld id:", sig.get("B"))
print("sf_vld id:", sig.get("D"), "fg_vld id:", sig.get("G"))
want = ("vld", "sf_vld", "fg_vld", "sf_row", "sf_col", "fg_row", "fg_col")
print("mapped:", {k: v for k, v in sig.items() if v in want})
print("total $var matched:", len(sig))
print("vld change lines:", cnt, "posedge count:", len(edges), "first:", edges[:5])
print("unmatched $var lines:", var_lines)
