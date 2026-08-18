# -*- coding: utf-8 -*-
"""KOA 5xSBUF 逐拍重放参考模型：直接解析 wave_koa.vcd，
在每个 posedge 用"沿前值"重建 DUT 的写入接受/SP+RR 出队，
与 DUT 的 rdy/out 信号逐拍比对，打印第一个分歧点。
"""
import re
import sys

VCD = r"C:\Users\92541\Documents\ChatGPT\framer\uvm_poe\sim\wave_koa.vcd"
N_SBUF = 5
N_PRI = 8
DEPTH = 320

# 各输入流：name -> (sbuf, planes, stream_id, kind)
STREAMS = [
    dict(name="oh_e",  sbuf=0, planes=4, sid=0, kind="oh"),
    dict(name="oh_i",  sbuf=1, planes=4, sid=1, kind="oh"),
    dict(name="aps_e", sbuf=0, planes=8, sid=2, kind="aps"),
    dict(name="aps_i", sbuf=1, planes=8, sid=3, kind="aps"),
    dict(name="alm",   sbuf=2, planes=8, sid=4, kind="aps"),
    dict(name="u_e",   sbuf=3, planes=1, sid=5, kind="uart"),
    dict(name="u_i",   sbuf=4, planes=1, sid=6, kind="uart"),
]


class Model:
    def __init__(self):
        self.cnt = [[0] * N_PRI for _ in range(N_SBUF)]
        self.head = [[0] * N_PRI for _ in range(N_SBUF)]
        self.tail = [[0] * N_PRI for _ in range(N_SBUF)]
        # data[s][g] 为 320 长列表，元素 None 或 (stream_id, cid, pos, data)
        self.data = [[[None] * DEPTH for _ in range(N_PRI)] for _ in range(N_SBUF)]

    def reset(self):
        self.__init__()

    def push(self, s, g, pkg):
        self.data[s][g][self.tail[s][g]] = pkg
        self.tail[s][g] = (self.tail[s][g] + 1) % DEPTH
        self.cnt[s][g] += 1

    def pop(self, s, g):
        pkg = self.data[s][g][self.head[s][g]]
        self.head[s][g] = (self.head[s][g] + 1) % DEPTH
        self.cnt[s][g] -= 1
        return pkg

    def read_select(self, rr):
        sel_g = None
        for g in range(N_PRI):
            for s in range(N_SBUF):
                if self.cnt[s][g] > 0:
                    sel_g = g
                    break
            if sel_g is not None:
                break
        if sel_g is None:
            return None
        for k in range(N_SBUF):
            s = (rr + k) % N_SBUF
            if self.cnt[s][sel_g] > 0:
                return (s, sel_g)
        return None


def main():
    ident = {}          # (scope,name) -> id
    vals = {}           # id -> int value
    scope = ""
    model = Model()
    prev_expected = None     # (vld, data, pri, src) 上一拍期望输出
    prev_cycle_t = None
    n_rdy_mm = 0
    n_out_mm = 0
    first_rdy_mm = None
    first_out_mm = None
    cycles = 0
    posedge_t = None
    trace = []          # (T, is_out_event, detail)
    trace_on = True

    def get(path, name):
        i = ident.get((path, name))
        if i is None:
            return 0
        return vals.get(i, 0)

    def slicev(v, hi, lo):
        return (v >> lo) & ((1 << (hi - lo + 1)) - 1)

    def report_out_mm(T, exp, act, detail):
        nonlocal n_out_mm, first_out_mm
        n_out_mm += 1
        if first_out_mm is None:
            first_out_mm = (T, exp, act, detail)

    def report_rdy_mm(T, detail):
        nonlocal n_rdy_mm, first_rdy_mm
        n_rdy_mm += 1
        if first_rdy_mm is None:
            first_rdy_mm = (T, detail)

    def process_cycle(T):
        nonlocal prev_expected, prev_cycle_t, cycles, trace_on
        cycles += 1
        rst = get("tb_top", "rst_n")
        rr = get("dut", "rr_ptr")
        # 上一拍输出比对：DUT 在 [T-1000,T) 的 out 信号即当前 vals 里的值
        if prev_expected is not None and rst:
            act_vld = get("dut", "out_vld")
            act_data = get("dut", "out_data")
            act_pri = get("dut", "out_pri")
            act_src = get("dut", "out_src")
            ev, ed, ep, es = prev_expected
            if act_vld != ev or (ev == 1 and (act_data != ed or act_pri != ep or act_src != es)):
                report_out_mm(prev_cycle_t, prev_expected,
                              (act_vld, act_data, act_pri, act_src),
                              "rr=%d" % rr)
                if trace_on:
                    trace_on = False
                    print("=== 首个输出分歧 @%dps（本拍输出期 [%dps,%dps)）===" %
                          (prev_cycle_t, prev_cycle_t, prev_cycle_t + 1000))
                    print("model exp: vld=%d data=%d pri=%d src=%d" % prev_expected)
                    print("dut  act: vld=%d data=%d pri=%d src=%d" %
                          (act_vld, act_data, act_pri, act_src))
                    print("model cnt 矩阵（g0..7 per sbuf）：")
                    for s in range(N_SBUF):
                        print("  SBUF%d: %s" % (s, " ".join("%3d" % model.cnt[s][g] for g in range(N_PRI))))
                    print("近 6 拍模型/DUT 活动：")
                    for tr in trace[-6:]:
                        print("  " + tr)
        if not rst:
            model.reset()
            prev_expected = None
            prev_cycle_t = None
            return

        # ---- 读侧先算（沿前状态，写入对同拍读不可见）----
        sel = model.read_select(rr)
        dut_rd = get("dut", "rd_valid")
        dut_sel_g = get("dut", "sel_grp")
        dut_sel_s = get("dut", "sel_sbuf")
        if sel is None:
            prev_expected = (0, 0, 0, 0)
            trace.append("t=%dps READ none (dut rd=%d sel_g=%d sel_s=%d rr=%d)" %
                         (T, dut_rd, dut_sel_g, dut_sel_s, rr))
            if dut_rd != 0:
                report_out_mm(T, (0, 0, 0, 0),
                              (1, get("dut", "out_data"), get("dut", "out_pri"), get("dut", "out_src")),
                              "model empty but DUT rd_valid=1")
        else:
            s, g = sel
            pkg = model.data[s][g][model.head[s][g]]
            prev_expected = (1, pkg[3], g, g)
            trace.append("t=%dps READ model=(s%d,g%d) dut=(s%d,g%d) rr=%d" %
                         (T, s, g, dut_sel_s, dut_sel_g, rr))
            if dut_rd != 1 or dut_sel_g != g or dut_sel_s != s:
                report_out_mm(T, (1, pkg[3], g, g),
                              (dut_rd, get("dut", "out_data"), dut_sel_g, dut_sel_s),
                              "read select mismatch model=(s%d,g%d) dut=(s%d,g%d) rr=%d" %
                              (s, g, dut_sel_s, dut_sel_g, rr))

        # ---- 写入接受（与 KOA 合并向量写一致）：APS 类固定靠前，OH 类后写 ----
        acc = {}          # stream name -> list of bool per plane
        pris = {}         # stream name -> list of pri per plane
        for st in STREAMS:
            nm = st["name"]
            npl = st["planes"]
            acc[nm] = [False] * npl
            pris[nm] = []
            for p in range(npl):
                pris[nm].append(get("dut", nm + "_pri") and slicev(get("dut", nm + "_pri"), p*3+2, p*3))
        n_acc = [[0] * N_PRI for _ in range(N_SBUF)]   # 段内本拍已排入条数

        def vld_of(nm, p):
            if STREAMS[[s["name"] for s in STREAMS].index(nm)]["planes"] == 1:
                return get("dut", nm + "_vld")
            return slicev(get("dut", nm + "_vld"), p, p)

        def data_of(nm, p, st):
            if st["planes"] > 1:
                return slicev(get("dut", nm + "_data"), p*384+383, p*384)
            return get("dut", nm + "_data")

        def cidpos_of(nm, p, st):
            if st["kind"] == "uart":
                return (0, 0)
            return (slicev(get("dut", nm + "_cid"), p*17+16, p*17),
                    slicev(get("dut", nm + "_pos"), p*3+2, p*3))

        def try_wr(nm, p, sbuf):
            """按 DUT 顺序尝试入队：vld 有效且段剩余空间足够才接受。"""
            st = STREAMS[[s["name"] for s in STREAMS].index(nm)]
            if not vld_of(nm, p):
                return
            g = pris[nm][p]
            if model.cnt[sbuf][g] + n_acc[sbuf][g] >= DEPTH:
                return
            acc[nm][p] = True
            n_acc[sbuf][g] += 1
            cid, pos = cidpos_of(nm, p, st)
            model.push(sbuf, g, (st["sid"], cid, pos, data_of(nm, p, st)))
            trace.append("t=%dps WRITE %s[%d] -> (s%d,g%d)" % (T, nm, p, sbuf, g))

        # APS 类固定靠前（编小优先）
        for nm in ("aps_e", "aps_i", "alm"):
            st = STREAMS[[s["name"] for s in STREAMS].index(nm)]
            for p in range(st["planes"]):
                try_wr(nm, p, st["sbuf"])
        # OH 类排在 APS 之后（编小优先）
        for nm in ("oh_e", "oh_i"):
            st = STREAMS[[s["name"] for s in STREAMS].index(nm)]
            for p in range(st["planes"]):
                try_wr(nm, p, st["sbuf"])
        # UART
        for nm in ("u_e", "u_i"):
            st = STREAMS[[s["name"] for s in STREAMS].index(nm)]
            try_wr(nm, 0, st["sbuf"])

        # 与 DUT rdy 比对（写侧）
        for st in STREAMS:
            nm = st["name"]
            dut_rdy = get("dut", nm + "_rdy")
            for p in range(st["planes"]):
                rdy_bit = slicev(dut_rdy, p, p) if st["planes"] > 1 else dut_rdy
                if rdy_bit != (1 if acc[nm][p] else 0):
                    report_rdy_mm(T, "%s[%d] model_acc=%d dut_rdy=%d pri=%d" %
                                  (nm, p, 1 if acc[nm][p] else 0, rdy_bit, pris[nm][p]))

        # ---- 应用：先入队（写），再出队（读），同段写读净 0 ----
        if sel is not None:
            model.pop(sel[0], sel[1])
        if len(trace) > 40:
            trace.pop(0)
        prev_cycle_t = T

    # ---- VCD 解析 ----
    with open(VCD, "r", errors="replace") as f:
        body = False
        pending = []
        cur = 0
        for raw in f:
            line = raw.strip()
            if not body:
                m = re.match(r"\$scope module (\S+)", line)
                if m:
                    scope = m.group(1)
                if line.startswith("$upscope"):
                    scope = ""
                m = re.match(r"\$var wire (\d+) (\S+) (\S+)", line)
                if m:
                    ident[(scope, m.group(3))] = m.group(2)
                if line.startswith("$enddefinitions"):
                    body = True
                continue
            if line.startswith("#"):
                # 处理本时间戳的变更：先判断 posedge，再用沿前值处理一拍
                new_clk = None
                for _, ln in pending:
                    ln = ln.strip()
                    if ln.startswith("b"):
                        v, i = ln[1:].split()
                        if i == ident.get(("tb_top", "clk")):
                            new_clk = int(v, 2) if v else 0
                    else:
                        i = ln[1:]
                        if i == ident.get(("tb_top", "clk")):
                            new_clk = 1 if ln[0] == "1" else 0
                old_clk = vals.get(ident.get(("tb_top", "clk")), 0)
                if old_clk == 0 and new_clk == 1:
                    process_cycle(cur)
                for _, ln in pending:
                    ln = ln.strip()
                    if ln.startswith("b"):
                        v, i = ln[1:].split()
                        vals[i] = int(v, 2) if v else 0
                    else:
                        i = ln[1:]
                        vals[i] = 1 if ln[0] == "1" else 0
                cur = int(line[1:])
                pending = []
                continue
            if line.startswith("$") or not line:
                continue
            pending.append((cur, line))

    print("cycles=%d  rdy_mismatch=%d  out_mismatch=%d" % (cycles, n_rdy_mm, n_out_mm))
    if first_rdy_mm:
        print("first rdy mismatch @%dps: %s" % (first_rdy_mm[0], first_rdy_mm[1]))
    if first_out_mm:
        print("first out mismatch @%dps: exp=%s act=%s detail=%s" %
              (first_out_mm[0], first_out_mm[1], first_out_mm[2], first_out_mm[3]))
    sys.exit(0 if (n_rdy_mm == 0 and n_out_mm == 0) else 1)


if __name__ == "__main__":
    main()
