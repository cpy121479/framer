`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*;
    import ko_pkg::*;
    import poe_types_pkg::*;

    localparam int NUM_OH_PLANES = 4;
    localparam int NUM_X2X_PLANES = 8;

    logic clk = 0;
    logic rst_n = 0;

    always #0.5ns clk = ~clk; // 1 GHz

    koa_if #(.NUM_OH_PLANES(NUM_OH_PLANES), .NUM_X2X_PLANES(NUM_X2X_PLANES))
    u_if(.clk(clk), .rst_n(rst_n));

    // ---- KOA SBUF 溢出告警（段满清空，输入不反压）----
    logic ovf_vld;
    logic [39:0] ovf_seg;
    logic [2:0] ovf_sbuf, ovf_pri;

    koa #(.NUM_OH_PLANES(NUM_OH_PLANES), .NUM_X2X_PLANES(NUM_X2X_PLANES)) dut (
    .clk (clk),
    .rst_n (rst_n),
    .oh_e_vld (u_if.oh_e_vld),
    .oh_e_pri (u_if.oh_e_pri), .oh_e_cid (u_if.oh_e_cid),
    .oh_e_pos (u_if.oh_e_pos), .oh_e_rdy (u_if.oh_e_rdy),
    .oh_i_vld (u_if.oh_i_vld),
    .oh_i_pri (u_if.oh_i_pri), .oh_i_cid (u_if.oh_i_cid),
    .oh_i_pos (u_if.oh_i_pos), .oh_i_rdy (u_if.oh_i_rdy),
    .aps_e_vld(u_if.aps_e_vld),
    .aps_e_pri(u_if.aps_e_pri), .aps_e_cid(u_if.aps_e_cid),
    .aps_e_pos(u_if.aps_e_pos), .aps_e_rdy (u_if.aps_e_rdy),
    .aps_i_vld(u_if.aps_i_vld),
    .aps_i_pri(u_if.aps_i_pri), .aps_i_cid(u_if.aps_i_cid),
    .aps_i_pos(u_if.aps_i_pos), .aps_i_rdy (u_if.aps_i_rdy),
    .alm_vld (u_if.alm_vld),
    .alm_pri (u_if.alm_pri), .alm_cid (u_if.alm_cid),
    .alm_pos (u_if.alm_pos), .alm_rdy (u_if.alm_rdy),
    .u_e_vld (u_if.u_e_vld),
    .u_e_pri (u_if.u_e_pri), .u_e_rdy (u_if.u_e_rdy),
    .u_i_vld (u_if.u_i_vld),
    .u_i_pri (u_if.u_i_pri), .u_i_rdy (u_if.u_i_rdy),
    .out_vld (u_if.out_vld),
    .out_new (u_if.out_new),
    .out_rdy (u_if.ko_rdy),
    .out_pri (u_if.out_pri),
    .out_src (u_if.out_src),
    .out_stream(u_if.out_stream),
    .out_cid (u_if.out_cid),
    .out_pos (u_if.out_pos),
    .ko_pre_vld(ko_pre_vld), .ko_dma_addr(ko_dma_addr), .ko_pre_op(ko_pre_op),
    .out_pre_vld(u_if.out_pre_vld), .out_dma_addr(u_if.out_dma_addr), .out_pre_op(u_if.out_pre_op),
    .ovf_vld(ovf_vld), .ovf_seg(ovf_seg), .ovf_sbuf(ovf_sbuf), .ovf_pri(ovf_pri)
    );

    // ================= POE 链路：KOA → THM → th_sch → burst_sch → CU/EU + dma_ctrl =================
    // 线程描述旁路（模拟 I_BUF_A 内容）：ts_cnt/bs_cnt/pri + 每 ts 的 burst 模式（38bit×4）
    logic ko_rdy;
    logic [63:0] ready_mask;
    logic [191:0] ready_pri;
    logic [383:0] ready_burst_ts; // 每线程 6bit ts 编号
    logic [255:0] ready_burst_tidx; // 每线程 4bit ts 序号（done 归属）
    logic [383:0] ready_curts; // 每线程 6bit 当前 ts 编号
    logic [2431:0] ready_burst;
    logic iss_vld0, iss_vld1;
    logic [5:0] iss_tid0, iss_tid1;
    // ---- pre_read 预读接口（KOA→THM→burst_sch→dma_ctrl） ----
    logic [3:0] ko_pre_vld; // KOA 入口预读指示（tb_top 激励驱动）
    logic [79:0] ko_dma_addr;
    logic [3:0] ko_pre_op;
    logic [3:0] out_pre_vld; // KOA 出口（随报文对齐 → THM）
    logic [79:0] out_dma_addr;
    logic [3:0] out_pre_op;
    logic [3:0] pre_vld; // THM → burst_sch 预读转发
    logic [23:0] pre_tid;
    logic [79:0] pre_dma_addr;
    logic [3:0] pre_op;
    logic pre_buf_rdy; // burst_sch 预读缓存空间
    // ---- th_sch 槽池视图（q0/q1 i/v + c_task 缓存，逐槽扁平） ----
    logic [7:0] q0_vld, q0_pre, q1_vld, q1_pre;
    logic [23:0] q0_pri, q1_pri;
    logic [47:0] q0_tid, q1_tid;
    logic [47:0] q0_ts, q1_ts;
    logic [31:0] q0_tidx, q1_tidx;
    logic [303:0] q0_burst, q1_burst;
    logic [7:0] q0_ack, q1_ack;
    logic [15:0] ct_vld;
    logic [47:0] ct_pri;
    logic [95:0] ct_tid;
    logic [63:0] ct_tidx;
    logic [95:0] ct_ts;
    logic [47:0] ct_dma;
    logic [31:0] ct_tag;
    logic [15:0] ct_op;
    logic [15:0] ct_ack;
    logic [511:0] csr_dma_c;
    logic [24575:0] csr_cw;
    logic owin_bp;
    // ---- EU（2 个，各含 4 个 CU 桩）----
    logic emit_eu_vld0, eu0_ack;
    logic [5:0] emit_eu_tid0;
    logic [3:0] emit_eu_tidx0;
    logic [BURST_W-1:0] emit_eu_burst0;
    logic emit_eu_vld1, eu1_ack;
    logic [5:0] emit_eu_tid1;
    logic [3:0] emit_eu_tidx1;
    logic [BURST_W-1:0] emit_eu_burst1;
    logic eu_done_vld0, eu_done_vld1;
    logic [5:0] eu_done_tid0, eu_done_tid1;
    logic [3:0] eu_done_tidx0, eu_done_tidx1;
    // ---- c_task 发射/done（burst_sch 发射即完成；推入 dma_ctrl FIFO）----
    logic [3:0] emit_dma_vld;
    logic [23:0] emit_dma_tid;
    logic [15:0] emit_dma_tidx;
    logic [11:0] emit_dma_dma_id;
    logic [7:0] emit_dma_tag;
    logic [3:0] emit_dma_op;
    logic [3:0] dma_full;
    logic [3:0] rba_bp;
    logic [27:0] rba_cnt;
    logic [3:0] dma_done_vld;
    logic [23:0] dma_done_tid;
    logic [15:0] dma_done_tidx;

    poe_thm #(.MAX_THREADS(64)) u_thm (
    .clk(clk), .rst_n(rst_n),
    .ko_vld(u_if.out_vld),
    .ko_stream(u_if.out_stream), .ko_cid(u_if.out_cid), .ko_pos(u_if.out_pos),
    .ko_pre_vld(u_if.out_pre_vld), .ko_dma_addr(u_if.out_dma_addr), .ko_pre_op(u_if.out_pre_op),
    .ko_rdy(ko_rdy),
    .ready_mask(ready_mask),
    .ready_pri(ready_pri),
    .ready_burst_ts(ready_burst_ts),
    .ready_burst_tidx(ready_burst_tidx),
    .ready_curts(ready_curts),
    .ready_burst(ready_burst),
    .iss_vld0(iss_vld0), .iss_tid0(iss_tid0),
    .iss_vld1(iss_vld1), .iss_tid1(iss_tid1),
    .eu_done_vld0(eu_done_vld0), .eu_done_tid0(eu_done_tid0),
    .eu_done_tidx0(eu_done_tidx0),
    .eu_done_vld1(eu_done_vld1), .eu_done_tid1(eu_done_tid1),
    .eu_done_tidx1(eu_done_tidx1),
    .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid),
    .dma_done_tidx(dma_done_tidx),
    .emit_vld(1'b0), .emit_tid(6'd0),
    .pre_buf_rdy(pre_buf_rdy),
    .pre_vld(pre_vld), .pre_tid(pre_tid),
    .pre_dma_addr(pre_dma_addr), .pre_op(pre_op),
    .csr_dma_c(csr_dma_c),
    .csr_cw(csr_cw)
    );

    poe_thsch #(.MAX_THREADS(64)) u_thsch (
    .clk(clk), .rst_n(rst_n),
    .ready_mask(ready_mask),
    .ready_pri(ready_pri),
    .ready_burst_ts(ready_burst_ts),
    .ready_burst_tidx(ready_burst_tidx),
    .ready_burst(ready_burst),
    .iss_vld0(iss_vld0), .iss_tid0(iss_tid0),
    .iss_vld1(iss_vld1), .iss_tid1(iss_tid1),
    .csr_dma_c(csr_dma_c), .csr_cw(csr_cw),
    .q0_vld(q0_vld), .q0_pre(q0_pre), .q0_pri(q0_pri),
    .q0_tid(q0_tid), .q0_ts(q0_ts), .q0_tidx(q0_tidx),
    .q0_burst(q0_burst), .q0_ack(q0_ack),
    .q1_vld(q1_vld), .q1_pre(q1_pre), .q1_pri(q1_pri),
    .q1_tid(q1_tid), .q1_ts(q1_ts), .q1_tidx(q1_tidx),
    .q1_burst(q1_burst), .q1_ack(q1_ack),
    .ct_vld(ct_vld), .ct_pri(ct_pri), .ct_tid(ct_tid),
    .ct_tidx(ct_tidx), .ct_ts(ct_ts), .ct_dma(ct_dma), .ct_tag(ct_tag),
    .ct_op(ct_op), .ct_ack(ct_ack)
    );

    poe_burstsch #(.MAX_THREADS(64)) u_burstsch (
    .clk(clk), .rst_n(rst_n),
    .q0_vld(q0_vld), .q0_pre(q0_pre), .q0_pri(q0_pri),
    .q0_tid(q0_tid), .q0_ts(q0_ts), .q0_tidx(q0_tidx),
    .q0_burst(q0_burst), .q0_ack(q0_ack),
    .q1_vld(q1_vld), .q1_pre(q1_pre), .q1_pri(q1_pri),
    .q1_tid(q1_tid), .q1_ts(q1_ts), .q1_tidx(q1_tidx),
    .q1_burst(q1_burst), .q1_ack(q1_ack),
    .ct_vld(ct_vld), .ct_pri(ct_pri), .ct_tid(ct_tid),
    .ct_tidx(ct_tidx), .ct_ts(ct_ts), .ct_dma(ct_dma), .ct_tag(ct_tag),
    .ct_op(ct_op), .ct_ack(ct_ack),
    .thread_curts(ready_curts),
    .owin_bp(owin_bp),
    .emit_eu_vld0(emit_eu_vld0), .emit_eu_tid0(emit_eu_tid0),
    .emit_eu_tidx0(emit_eu_tidx0), .emit_eu_burst0(emit_eu_burst0),
    .eu0_ack(eu0_ack),
    .emit_eu_vld1(emit_eu_vld1), .emit_eu_tid1(emit_eu_tid1),
    .emit_eu_tidx1(emit_eu_tidx1), .emit_eu_burst1(emit_eu_burst1),
    .eu1_ack(eu1_ack),
    .emit_dma_vld(emit_dma_vld), .emit_dma_tid(emit_dma_tid),
    .emit_dma_tidx(emit_dma_tidx), .emit_dma_dma_id(emit_dma_dma_id),
    .emit_dma_tag(emit_dma_tag), .emit_dma_op(emit_dma_op),
    .dma_full(dma_full),
    .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid),
    .dma_done_tidx(dma_done_tidx),
    .pre_vld(pre_vld), .pre_tid(pre_tid),
    .pre_dma_addr(pre_dma_addr), .pre_op(pre_op),
    .pre_buf_rdy(pre_buf_rdy)
    );

    poe_eu_stub #(.LATENCY(1)) u_eu0 (
    .clk(clk), .rst_n(rst_n),
    .emit_eu_vld(emit_eu_vld0), .emit_eu_tid(emit_eu_tid0),
    .emit_eu_tidx(emit_eu_tidx0), .emit_eu_burst(emit_eu_burst0),
    .eu_ack(eu0_ack),
    .eu_done_vld(eu_done_vld0), .eu_done_tid(eu_done_tid0), .eu_done_tidx(eu_done_tidx0)
    );

    poe_eu_stub #(.LATENCY(1)) u_eu1 (
    .clk(clk), .rst_n(rst_n),
    .emit_eu_vld(emit_eu_vld1), .emit_eu_tid(emit_eu_tid1),
    .emit_eu_tidx(emit_eu_tidx1), .emit_eu_burst(emit_eu_burst1),
    .eu_ack(eu1_ack),
    .eu_done_vld(eu_done_vld1), .eu_done_tid(eu_done_tid1), .eu_done_tidx(eu_done_tidx1)
    );

    poe_dma_ctrl u_dma (
    .clk(clk), .rst_n(rst_n),
    .push_vld(emit_dma_vld),
    .push_tid(emit_dma_tid),
    .push_tidx(emit_dma_tidx),
    .push_dma_id(emit_dma_dma_id),
    .push_tag(emit_dma_tag),
    .push_op(emit_dma_op),
    .fifo_full(dma_full),
    .rba_bp(rba_bp),
    .rba_cnt(rba_cnt)
    );

    // O 窗反压占位：固定 0（O 窗池设计后续补充）
    assign owin_bp = 1'b0;
    // KOA 出口反压：THM 入口 ready 驱动到接口（KOA 保持输出寄存器，不丢报文）
    assign u_if.ko_rdy = ko_rdy;
    // 排空指示：线程池全 IDLE 且保序缓存空（供 base test 的 drain 等待）
    always @(posedge clk) begin
        automatic int busy = 0;
        if (!rst_n) begin
            ko_pkg::g_all_idle = 1'b0;
        end else begin
            for (int i = 0; i < 64; i++)
                if (u_thm.th_state[i] != 2'd0) busy++;
            ko_pkg::g_all_idle = (busy == 0) && (u_thm.buf_cnt == 0);
        end
    end
    // ---- 临时调试日志 ----
    integer thm_logf;
    logic [3:0] rba_bp_prev;
    integer rba_bp_cyc [4];
    integer fifo_full_cyc [4];
    integer ct_occ_peak;
    integer ct_full_ev;
    integer q0_occ_peak;
    integer q1_occ_peak;
    initial thm_logf = $fopen("thm_dbg.log", "w");
    always @(posedge clk) begin
        burst_c_t cb0, cb1;
        integer ct_occ;
        integer q0_occ, q1_occ;
        ct_occ = 0; q0_occ = 0; q1_occ = 0;
        for (int i = 0; i < 16; i++)
            if (ct_vld[i]) ct_occ++;
        for (int i = 0; i < 8; i++) begin
            if (q0_vld[i]) q0_occ++;
            if (q1_vld[i]) q1_occ++;
        end
        if (ct_occ > ct_occ_peak) ct_occ_peak = ct_occ;
        if (ct_occ == 16) ct_full_ev++;
        if (q0_occ > q0_occ_peak) q0_occ_peak = q0_occ;
        if (q1_occ > q1_occ_peak) q1_occ_peak = q1_occ;
        for (int d = 0; d < 4; d++) begin
            if (rba_bp[d]) rba_bp_cyc[d]++;
            if (dma_full[d]) fifo_full_cyc[d]++;
        end
        // RBA 反压事件（复位握手后才有意义）
        if (ovf_vld)
            $fdisplay(thm_logf, "SBUF_OVF t=%0t sbuf=%0d pri=%0d", $time, ovf_sbuf, ovf_pri);
        if (rst_n && (rba_bp !== rba_bp_prev)) begin
            $fdisplay(thm_logf, "RBA_BP t=%0t bp=%b cnt=%0d/%0d/%0d/%0d",
            $time, rba_bp, rba_cnt[6:0], rba_cnt[13:7],
            rba_cnt[20:14], rba_cnt[27:21]);
            rba_bp_prev = rba_bp;
        end
        // 槽池异常检查：vld 且非 pre 且 ts < cur_ts
        for (int i = 0; i < 8; i++) begin
            if (q0_vld[i] && !q0_pre[i] &&
                (q0_ts[i*6 +: 6] < ready_curts[q0_tid[i*6 +: 6]*6 +: 6]))
                $fdisplay(thm_logf, "OLD_BURST0 t=%0t slot=%0d q0ts=%0d curts=%0d tid=%0d",
                $time, i, q0_ts[i*6 +: 6],
                ready_curts[q0_tid[i*6 +: 6]*6 +: 6], q0_tid[i*6 +: 6]);
            if (q1_vld[i] && !q1_pre[i] &&
                (q1_ts[i*6 +: 6] < ready_curts[q1_tid[i*6 +: 6]*6 +: 6]))
                $fdisplay(thm_logf, "OLD_BURST1 t=%0t slot=%0d q1ts=%0d curts=%0d tid=%0d",
                $time, i, q1_ts[i*6 +: 6],
                ready_curts[q1_tid[i*6 +: 6]*6 +: 6], q1_tid[i*6 +: 6]);
        end
        if (emit_eu_vld0 || emit_eu_vld1) begin
            burst_iv_t eb;
            if (emit_eu_vld1) begin
                eb = emit_eu_burst1;
                $fdisplay(thm_logf, "EMIT_EU1 t=%0t tid=%0d ts=%0d st=%0d tr=%0d ts_len=%0d branch=%0d vld=%0d tsk=%0d/%0d c=%0d/%0d pc=%0d need=%0d tscnt=%0d",
                $time, emit_eu_tid1, ready_curts[emit_eu_tid1*6 +: 6],
                eb.st, eb.tr, eb.ts_len, eb.branch, eb.vld_cu,
                eb.tsk_id0, eb.tsk_id1, eb.c0, eb.c1,
                u_thm.th_bs_pc[emit_eu_tid1], u_thm.th_need[emit_eu_tid1][u_thm.th_ts_idx[emit_eu_tid1]],
                u_thm.th_ts_n[emit_eu_tid1]);
            end else begin
                eb = emit_eu_burst0;
                $fdisplay(thm_logf, "EMIT_EU t=%0t tid=%0d ts=%0d st=%0d tr=%0d ts_len=%0d branch=%0d vld=%0d tsk=%0d/%0d c=%0d/%0d pc=%0d need=%0d tscnt=%0d",
                $time, emit_eu_tid0, ready_curts[emit_eu_tid0*6 +: 6],
                eb.st, eb.tr, eb.ts_len, eb.branch, eb.vld_cu,
                eb.tsk_id0, eb.tsk_id1, eb.c0, eb.c1,
                u_thm.th_bs_pc[emit_eu_tid0], u_thm.th_need[emit_eu_tid0][u_thm.th_ts_idx[emit_eu_tid0]],
                u_thm.th_ts_n[emit_eu_tid0]);
            end
        end
        for (int d = 0; d < 4; d++)
            if (emit_dma_vld[d])
                $fdisplay(thm_logf, "EMIT_DMA t=%0t dse=%0d tid=%0d tidx=%0d dma_id=%0d tag=%0d op=%0d",
                $time, d, emit_dma_tid[d*6 +: 6], emit_dma_tidx[d*4 +: 4],
                emit_dma_dma_id[d*3 +: 3], emit_dma_tag[d*2 +: 2], emit_dma_op[d]);
        if (iss_vld0)
            $fdisplay(thm_logf, "ISS0 t=%0t tid=%0d curts=%0d burst_ts=%0d pc=%0d need=%0d tscnt=%0d st=%0d",
        $time, iss_tid0, ready_curts[iss_tid0*6 +: 6],
        ready_burst_ts[iss_tid0*6 +: 6],
        u_thm.th_bs_pc[iss_tid0], u_thm.th_need[iss_tid0][u_thm.th_ts_idx[iss_tid0]],
            u_thm.th_ts_n[iss_tid0], u_thm.th_state[iss_tid0]);
        if (iss_vld1)
            $fdisplay(thm_logf, "ISS1 t=%0t tid=%0d curts=%0d burst_ts=%0d pc=%0d need=%0d tscnt=%0d st=%0d",
        $time, iss_tid1, ready_curts[iss_tid1*6 +: 6],
        ready_burst_ts[iss_tid1*6 +: 6],
        u_thm.th_bs_pc[iss_tid1], u_thm.th_need[iss_tid1][u_thm.th_ts_idx[iss_tid1]],
            u_thm.th_ts_n[iss_tid1], u_thm.th_state[iss_tid1]);
        if (eu_done_vld0)
            $fdisplay(thm_logf, "DONE_EU0 t=%0t tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
        $time, eu_done_tid0, ready_curts[eu_done_tid0*6 +: 6],
            u_thm.csr[eu_done_tid0].cur_ts,
        u_thm.th_done_acc[eu_done_tid0][u_thm.th_ts_idx[eu_done_tid0]],
        u_thm.th_dneed[eu_done_tid0][u_thm.th_ts_idx[eu_done_tid0]],
            u_thm.th_ts_n[eu_done_tid0], u_thm.th_bs_pc[eu_done_tid0],
            u_thm.th_state[eu_done_tid0]);
        if (eu_done_vld1)
            $fdisplay(thm_logf, "DONE_EU1 t=%0t tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
        $time, eu_done_tid1, ready_curts[eu_done_tid1*6 +: 6],
            u_thm.csr[eu_done_tid1].cur_ts,
        u_thm.th_done_acc[eu_done_tid1][u_thm.th_ts_idx[eu_done_tid1]],
        u_thm.th_dneed[eu_done_tid1][u_thm.th_ts_idx[eu_done_tid1]],
            u_thm.th_ts_n[eu_done_tid1], u_thm.th_bs_pc[eu_done_tid1],
            u_thm.th_state[eu_done_tid1]);
        for (int d = 0; d < 4; d++)
            if (dma_done_vld[d]) begin
                automatic logic [5:0] dt = dma_done_tid[d*6 +: 6];
                $fdisplay(thm_logf, "DONE_DMA t=%0t dse=%0d tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
                $time, d, dt, ready_curts[dt*6 +: 6],
                    u_thm.csr[dt].cur_ts,
                u_thm.th_done_acc[dt][u_thm.th_ts_idx[dt]],
                u_thm.th_dneed[dt][u_thm.th_ts_idx[dt]],
                    u_thm.th_ts_n[dt], u_thm.th_bs_pc[dt],
                    u_thm.th_state[dt]);
            end
    end


    // ================= benchmark 仪器化 =================
    // 测量窗口：复位后第 MEAS_SKIP 拍起统计到仿真结束（跳过预热；drain 段计入，
    // 同 RUN_US 对比时口径一致）。指标：
    // - 吞吐：koa_out / 线程创建/完成 / 一级发射（i/v、c 分类）/ EU、DSE 发射与 done
    // - 利用率：一级发射槽（÷2/拍）、EU（÷2/拍）、DSE（÷4/拍）
    // - 占用（时间平均）：线程池(64)/保序缓存(8)/q0/q1(8)/ct(16)/dma FIFO(4×8)
    // - 延迟：线程创建 → T_DONE 直方图（10 拍一桶），输出 avg/p50/p99/max
    string bench_tag;
    int bench_seed;
    int meas_skip;
    longint cyc_cnt;
    longint meas_cyc;
    longint n_cre, n_thdone, n_koa_out, n_ko_in, n_ko_acc, n_ko_bp, n_sbuf_ovf;
    longint n_in_s [7]; // 分来源输入握手：0=OH_EXT 1=OH_INS 2=APS_EXT 3=APS_INS 4=ALM 5=UART_EXT 6=UART_INS
    longint n_iss, n_iss_iv, n_iss_c;
    longint n_emit_eu, n_emit_dma, n_done_eu, n_done_dma;
    longint acc_pool, acc_buf, acc_q0, acc_q1, acc_ct, acc_fifo, acc_iss, acc_eu, acc_dse;
    longint rba_min [4];
    localparam int LAT_BW = 10; // 每桶 10 拍
    localparam int NLAT = 2048; // 覆盖 0..20479 拍
    longint lat_hist [NLAT+1]; // 末桶 = 溢出
    longint lat_n, lat_sum, lat_min, lat_max;
    logic [1:0] prev_state [64];
    longint cre_time [64];

    initial begin
        bench_tag = "bench";
        void'($value$plusargs("BENCH_TAG=%s", bench_tag));
        bench_seed = -1;
        void'($value$plusargs("BENCH_SEED=%d", bench_seed));
        meas_skip = 2000;
        void'($value$plusargs("MEAS_SKIP=%d", meas_skip));
    end

    always @(posedge clk) begin
        integer pool_occ, q0o, q1o, cto, fifo_o;
        longint lat;
        if (!rst_n) begin
            cyc_cnt = 0;
            meas_cyc = 0;
            n_cre = 0; n_thdone = 0; n_koa_out = 0; n_ko_in = 0; n_ko_acc = 0;
            n_ko_bp = 0; n_sbuf_ovf = 0;
            for (int f = 0; f < 7; f++) n_in_s[f] = 0;
            n_iss = 0; n_iss_iv = 0; n_iss_c = 0;
            n_emit_eu = 0; n_emit_dma = 0; n_done_eu = 0; n_done_dma = 0;
            acc_pool = 0; acc_buf = 0; acc_q0 = 0; acc_q1 = 0; acc_ct = 0;
            acc_fifo = 0; acc_iss = 0; acc_eu = 0; acc_dse = 0;
            for (int d = 0; d < 4; d++) rba_min[d] = 64;
            for (int b = 0; b <= NLAT; b++) lat_hist[b] = 0;
            lat_n = 0; lat_sum = 0; lat_min = '1; lat_max = 0;
            for (int i = 0; i < 64; i++) begin
                prev_state[i] = 2'd0;
                cre_time[i] = 0;
            end
        end else begin
            cyc_cnt = cyc_cnt + 1;
            // 线程状态沿检测（创建 / 完成，均比 THM 内部晚 1 拍采样，误差相消）
            for (int i = 0; i < 64; i++) begin
                if (prev_state[i] == 2'd0 && u_thm.th_state[i] == 2'd1) begin
                    cre_time[i] = cyc_cnt;
                    if (cyc_cnt >= meas_skip) n_cre++;
                end
                if (prev_state[i] != 2'd3 && u_thm.th_state[i] == 2'd3) begin
                    if (cyc_cnt >= meas_skip) begin
                        n_thdone++;
                        lat = cyc_cnt - cre_time[i];
                        lat_n++;
                        lat_sum += lat;
                        if (lat < lat_min) lat_min = lat;
                        if (lat > lat_max) lat_max = lat;
                        if (lat / LAT_BW <= NLAT) lat_hist[lat / LAT_BW]++;
                        else lat_hist[NLAT]++;
                    end
                end
                prev_state[i] = u_thm.th_state[i];
            end
            if (cyc_cnt >= meas_skip) begin
                meas_cyc++;
                // 吞吐
                // KOA 输入握手（各业务源 vld&&rdy 求和，分来源累计）
                for (int p = 0; p < NUM_OH_PLANES; p++) begin
                    if (u_if.oh_e_vld[p] && u_if.oh_e_rdy[p]) begin n_ko_in++; n_in_s[0]++; end
                    if (u_if.oh_i_vld[p] && u_if.oh_i_rdy[p]) begin n_ko_in++; n_in_s[1]++; end
                end
                for (int p = 0; p < NUM_X2X_PLANES; p++) begin
                    if (u_if.aps_e_vld[p] && u_if.aps_e_rdy[p]) begin n_ko_in++; n_in_s[2]++; end
                    if (u_if.aps_i_vld[p] && u_if.aps_i_rdy[p]) begin n_ko_in++; n_in_s[3]++; end
                    if (u_if.alm_vld[p] && u_if.alm_rdy[p]) begin n_ko_in++; n_in_s[4]++; end
                end
                if (u_if.u_e_vld && u_if.u_e_rdy) begin n_ko_in++; n_in_s[5]++; end
                if (u_if.u_i_vld && u_if.u_i_rdy) begin n_ko_in++; n_in_s[6]++; end
                // KOA 出口：出队（koaout=实际出队条数；ko_acc=被 THM 收下拍，
                // ko_bp=被反压保持拍数——出口握手后无丢弃，koaout≈ko_acc）
                if (u_if.out_new) n_koa_out++;
                if (u_if.out_vld && ko_rdy) n_ko_acc++;
                if (u_if.out_vld && !ko_rdy) n_ko_bp++;
                // SBUF 段溢出清空（输入不反压，段满丢弃段内全部并告警）
                if (ovf_vld)
                    for (int sg = 0; sg < 40; sg++)
                        if (ovf_seg[sg]) n_sbuf_ovf++;
                if (iss_vld0) begin
                    n_iss++;
                    if (ready_burst[iss_tid0*BURST_W + 25]) n_iss_c++;
                    else n_iss_iv++;
                end
                if (iss_vld1) begin
                    n_iss++;
                    if (ready_burst[iss_tid1*BURST_W + 25]) n_iss_c++;
                    else n_iss_iv++;
                end
                n_emit_eu += emit_eu_vld0 + emit_eu_vld1;
                n_done_eu += eu_done_vld0 + eu_done_vld1;
                for (int d = 0; d < 4; d++) begin
                    if (emit_dma_vld[d]) n_emit_dma++;
                    if (dma_done_vld[d]) n_done_dma++;
                end
                // 占用累计（时间平均用）
                pool_occ = 0;
                for (int i = 0; i < 64; i++)
                    if (u_thm.th_state[i] != 2'd0) pool_occ++;
                acc_pool += pool_occ;
                acc_buf += u_thm.buf_cnt;
                q0o = 0; q1o = 0; cto = 0;
                for (int i = 0; i < 8; i++) begin
                    if (q0_vld[i]) q0o++;
                    if (q1_vld[i]) q1o++;
                end
                for (int i = 0; i < 16; i++)
                    if (ct_vld[i]) cto++;
                acc_q0 += q0o; acc_q1 += q1o; acc_ct += cto;
                fifo_o = 0;
                for (int d = 0; d < 4; d++) begin
                    fifo_o += u_dma.f_cnt[d];
                    if (rba_cnt[d*7 +: 7] < rba_min[d])
                        rba_min[d] = rba_cnt[d*7 +: 7];
                end
                acc_fifo += fifo_o;
                acc_iss += iss_vld0 + iss_vld1;
                acc_eu += emit_eu_vld0 + emit_eu_vld1;
                for (int d = 0; d < 4; d++)
                    if (emit_dma_vld[d]) acc_dse++;
            end
        end
    end

    // benchmark 结果：stdout 一行 key=value（BENCH_CSV 前缀，便于收集）+ 日志文件
    final begin
        automatic real iss_util = (meas_cyc > 0) ? 1.0 * acc_iss / (2.0 * meas_cyc) : 0.0;
        automatic real eu_util = (meas_cyc > 0) ? 1.0 * acc_eu / (2.0 * meas_cyc) : 0.0;
        automatic real dse_util = (meas_cyc > 0) ? 1.0 * acc_dse / (4.0 * meas_cyc) : 0.0;
        automatic longint cum = 0;
        automatic longint tgt;
        automatic int p50 = -1;
        automatic int p99 = -1;
        automatic longint rba_bp_sum = 0;
        automatic longint ff_sum = 0;
        for (int d = 0; d < 4; d++) begin
            rba_bp_sum += rba_bp_cyc[d];
            ff_sum += fifo_full_cyc[d];
        end
        if (lat_n > 0) begin
            tgt = (lat_n * 50) / 100;
            for (int b = 0; b <= NLAT; b++) begin
                cum += lat_hist[b];
                if (cum >= tgt) begin p50 = b * LAT_BW; break; end
            end
            cum = 0;
            tgt = (lat_n * 99) / 100;
            for (int b = 0; b <= NLAT; b++) begin
                cum += lat_hist[b];
                if (cum >= tgt) begin p99 = b * LAT_BW; break; end
            end
        end
        $display("BENCH_CSV tag=%0s seed=%0d cyc=%0d cre=%0d thdone=%0d ko_in=%0d koaout=%0d ko_acc=%0d ko_bp=%0d sbuf_ovf=%0d iss=%0d iss_iv=%0d iss_c=%0d emiteu=%0d emitdma=%0d doneeu=%0d donedma=%0d iss_util=%.3f eu_util=%.3f dse_util=%.3f pool_avg=%.2f buf_avg=%.2f q0_avg=%.2f q1_avg=%.2f ct_avg=%.2f fifo_avg=%.2f rba_min=%0d/%0d/%0d/%0d rba_bp_cyc=%0d fifo_full_cyc=%0d lat_avg=%.1f lat_p50=%0d lat_p99=%0d lat_max=%0d lat_n=%0d",
                 bench_tag, bench_seed, meas_cyc, n_cre, n_thdone, n_ko_in,
                 n_koa_out, n_ko_acc, n_ko_bp, n_sbuf_ovf,
                 n_iss, n_iss_iv, n_iss_c, n_emit_eu, n_emit_dma, n_done_eu, n_done_dma,
                 iss_util, eu_util, dse_util,
                 (meas_cyc > 0) ? 1.0 * acc_pool / meas_cyc : 0.0,
                 (meas_cyc > 0) ? 1.0 * acc_buf / meas_cyc : 0.0,
                 (meas_cyc > 0) ? 1.0 * acc_q0 / meas_cyc : 0.0,
                 (meas_cyc > 0) ? 1.0 * acc_q1 / meas_cyc : 0.0,
                 (meas_cyc > 0) ? 1.0 * acc_ct / meas_cyc : 0.0,
                 (meas_cyc > 0) ? 1.0 * acc_fifo / meas_cyc : 0.0,
                 rba_min[0], rba_min[1], rba_min[2], rba_min[3],
                 rba_bp_sum, ff_sum,
                 (lat_n > 0) ? 1.0 * lat_sum / lat_n : 0.0,
                 p50, p99, lat_max, lat_n);
        $fdisplay(thm_logf, "BENCH lat_hist(10beat桶): min=%0d max=%0d", lat_min, lat_max);
        $display("BENCH_SRC oh_e=%0d oh_i=%0d aps_e=%0d aps_i=%0d alm=%0d u_e=%0d u_i=%0d total=%0d",
                 n_in_s[0], n_in_s[1], n_in_s[2], n_in_s[3], n_in_s[4],
                 n_in_s[5], n_in_s[6], n_ko_in);
    end

    // 预读入口激励：每拍随机 0..4 组预读（每组约 1/16 概率，模拟业务流预读请求）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ko_pre_vld <= 4'd0;
            ko_dma_addr <= '0;
            ko_pre_op <= 4'd0;
        end else begin
            ko_pre_vld <= {($urandom % 16) == 0,
                           ($urandom % 16) == 0,
                           ($urandom % 16) == 0,
                           ($urandom % 16) == 0};
            ko_dma_addr <= {$urandom, $urandom, $urandom}; // 80bit（96bit 截断取低）
            ko_pre_op <= {$urandom % 2, $urandom % 2, $urandom % 2, $urandom % 2};
        end
    end

    // 复位握手：复位完成后置位包级 g_reset_done
    initial begin
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        ko_pkg::g_reset_done = 1;
    end

    initial begin
        string wf;
        if ($value$plusargs("WAVE_FILE=%s", wf))
            $dumpfile(wf);
        else
            $dumpfile("wave.vcd");
        $dumpvars(0, tb_top);
    end

    initial begin
        ko_pkg::g_tb_cfg.vif = u_if;
        // 显式引用测试类，防止 Verilator 当作死代码优化掉
        void'(koa_smoke_test::type_id::get());
        run_test();
    end

    final begin
        integer i;
        int idle;
        int n_ready, n_issued, n_done;
        idle = 0;
        n_ready = 0; n_issued = 0; n_done = 0;
        for (i = 0; i < 64; i++) begin
            if (u_thm.th_state[i] == 2'd0) idle++;
            else if (u_thm.th_state[i] == 2'd1) n_ready++;
            else if (u_thm.th_state[i] == 2'd2) n_issued++;
            else n_done++;
        end
        // 校验：所有线程应回到 IDLE（C 窗为纯数据存储，无 loc/free 占用状态）
        // （$display 同步打 stdout：benchmark 解析器从运行日志取校验结果）
        $display("FINAL idle=%0d ready=%0d issued=%0d done=%0d",
                 idle, n_ready, n_issued, n_done);
        $fdisplay(thm_logf, "FINAL idle=%0d ready=%0d issued=%0d done=%0d",
                  idle, n_ready, n_issued, n_done);
        $fdisplay(thm_logf, "BP RBA_cyc=%0d/%0d/%0d/%0d FIFO_full_cyc=%0d/%0d/%0d/%0d",
                  rba_bp_cyc[0], rba_bp_cyc[1], rba_bp_cyc[2], rba_bp_cyc[3],
                  fifo_full_cyc[0], fifo_full_cyc[1], fifo_full_cyc[2], fifo_full_cyc[3]);
        $fdisplay(thm_logf, "BP ct_peak=%0d ct_full_ev=%0d q0_peak=%0d q1_peak=%0d",
                  ct_occ_peak, ct_full_ev, q0_occ_peak, q1_occ_peak);
        for (i = 0; i < 64; i++)
            if (u_thm.th_state[i] != 2'd0)
                $fdisplay(thm_logf, "NONIDLE tid=%0d st=%0d curts=%0d pc=%0d",
                          i, u_thm.th_state[i], u_thm.th_cur_ts[i], u_thm.th_bs_pc[i]);
        // 槽池残留转储（定位无法发射的 burst）
        for (i = 0; i < 8; i++) begin
            if (q0_vld[i])
                $fdisplay(thm_logf, "POOL0 slot=%0d tid=%0d ts=%0d tidx=%0d curts=%0d pri=%0d",
                          i, q0_tid[i*6 +: 6], q0_ts[i*6 +: 6], q0_tidx[i*4 +: 4],
                          ready_curts[q0_tid[i*6 +: 6]*6 +: 6], q0_pri[i*3 +: 3]);
            if (q1_vld[i])
                $fdisplay(thm_logf, "POOL1 slot=%0d tid=%0d ts=%0d tidx=%0d curts=%0d pri=%0d",
                          i, q1_tid[i*6 +: 6], q1_ts[i*6 +: 6], q1_tidx[i*4 +: 4],
                          ready_curts[q1_tid[i*6 +: 6]*6 +: 6], q1_pri[i*3 +: 3]);
        end
    end
endmodule
