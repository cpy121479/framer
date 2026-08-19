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

    koa #(.NUM_OH_PLANES(NUM_OH_PLANES), .NUM_X2X_PLANES(NUM_X2X_PLANES)) dut (
    .clk (clk),
    .rst_n (rst_n),
    .oh_e_vld (u_if.oh_e_vld), .oh_e_data (u_if.oh_e_data),
    .oh_e_pri (u_if.oh_e_pri), .oh_e_cid (u_if.oh_e_cid),
    .oh_e_pos (u_if.oh_e_pos), .oh_e_rdy (u_if.oh_e_rdy),
    .oh_i_vld (u_if.oh_i_vld), .oh_i_data (u_if.oh_i_data),
    .oh_i_pri (u_if.oh_i_pri), .oh_i_cid (u_if.oh_i_cid),
    .oh_i_pos (u_if.oh_i_pos), .oh_i_rdy (u_if.oh_i_rdy),
    .aps_e_vld(u_if.aps_e_vld), .aps_e_data(u_if.aps_e_data),
    .aps_e_pri(u_if.aps_e_pri), .aps_e_cid(u_if.aps_e_cid),
    .aps_e_pos(u_if.aps_e_pos), .aps_e_rdy (u_if.aps_e_rdy),
    .aps_i_vld(u_if.aps_i_vld), .aps_i_data(u_if.aps_i_data),
    .aps_i_pri(u_if.aps_i_pri), .aps_i_cid(u_if.aps_i_cid),
    .aps_i_pos(u_if.aps_i_pos), .aps_i_rdy (u_if.aps_i_rdy),
    .alm_vld (u_if.alm_vld), .alm_data (u_if.alm_data),
    .alm_pri (u_if.alm_pri), .alm_cid (u_if.alm_cid),
    .alm_pos (u_if.alm_pos), .alm_rdy (u_if.alm_rdy),
    .u_e_vld (u_if.u_e_vld), .u_e_data (u_if.u_e_data),
    .u_e_pri (u_if.u_e_pri), .u_e_rdy (u_if.u_e_rdy),
    .u_i_vld (u_if.u_i_vld), .u_i_data (u_if.u_i_data),
    .u_i_pri (u_if.u_i_pri), .u_i_rdy (u_if.u_i_rdy),
    .out_vld (u_if.out_vld),
    .out_data(u_if.out_data),
    .out_pri (u_if.out_pri),
    .out_src (u_if.out_src),
    .out_stream(u_if.out_stream),
    .out_cid (u_if.out_cid),
    .out_pos (u_if.out_pos),
    .ko_pre_vld(ko_pre_vld), .ko_dma_addr(ko_dma_addr), .ko_pre_op(ko_pre_op),
    .out_pre_vld(u_if.out_pre_vld), .out_dma_addr(u_if.out_dma_addr), .out_pre_op(u_if.out_pre_op)
    );

    // ================= POE 链路：KOA → THM → th_sch → burst_sch → CU/EU + dma_ctrl =================
    // 线程描述旁路（模拟 I_BUF_A 内容）：ts_cnt/bs_cnt/pri + 每 ts 的 burst 模式（32bit×4）
    logic [4:0] th_ts_cnt; // 1..16 个 ts
    logic [47:0] th_bs_cnt; // 每 ts burst 数（16×3bit，ts0 固定 1）
    logic [95:0] th_ts_id; // 每 ts 编号（16×6bit，递增可跳转）
    logic [2:0] th_pri;
    logic [2047:0] th_burst_seq; // 16 ts × 4 burst × 32bit（每 ts 独立随机）
    logic [7:0] th_vtsk_c_seq; // CSR vtsk_c
    logic [7:0] th_dma_c_seq; // CSR dma_c
    logic [383:0] th_cw_seq; // CSR cw（8×6B）
    logic ko_rdy;
    logic [63:0] ready_mask;
    logic [191:0] ready_pri;
    logic [383:0] ready_burst_ts; // 每线程 6bit ts 编号
    logic [383:0] ready_curts; // 每线程 6bit 当前 ts 编号
    logic [2047:0] ready_burst;
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
    logic [3:0] pre_op_vld; // burst_sch → dma_ctrl 预读发射
    logic [23:0] pre_op_tid;
    logic [79:0] pre_op_addr;
    logic [3:0] pre_op_type;
    logic pre_op_ack;
    logic q0_vld, q1_vld;
    logic [5:0] q0_tid, q1_tid;
    logic [5:0] q0_ts, q1_ts;
    logic [31:0] q0_burst, q1_burst;
    logic q0_pre, q1_pre;
    logic q0_ack, q1_ack;
    logic [511:0] csr_dma_c;
    logic [24575:0] csr_cw;
    logic [7:0] pre_dma_c;
    logic [255:0] pre_cw;
    logic th_rel_vld;
    logic [5:0] th_rel_tid;
    logic [9:0] cw_fifo_cnt;
    logic [127:0] th_res_n;
    logic owin_bp;
    logic emit_cu_vld0, cu0_ack;
    logic [5:0] emit_cu_tid0;
    logic [31:0] emit_cu_burst0;
    logic emit_cu_vld1, cu1_ack;
    logic [5:0] emit_cu_tid1;
    logic [31:0] emit_cu_burst1;
    logic emit_dma_vld, dma_ack;
    logic [5:0] emit_dma_tid;
    logic [31:0] emit_dma_burst;
    logic emit_dma_pre;
    logic cw_upd_vld;
    logic [5:0] cw_upd_tid;
    logic [2:0] cw_upd_ind;
    logic [47:0] cw_upd_data;
    logic cu_done_vld0, cu_done_vld1;
    logic [5:0] cu_done_tid0, cu_done_tid1;
    logic dma_done_vld;
    logic [5:0] dma_done_tid;

    poe_thm #(.MAX_THREADS(64)) u_thm (
    .clk(clk), .rst_n(rst_n),
    .ko_vld(u_if.out_vld), .ko_data(u_if.out_data),
    .ko_stream(u_if.out_stream), .ko_cid(u_if.out_cid), .ko_pos(u_if.out_pos),
    .ko_pre_vld(u_if.out_pre_vld), .ko_dma_addr(u_if.out_dma_addr), .ko_pre_op(u_if.out_pre_op),
    .th_ts_cnt(th_ts_cnt), .th_bs_cnt(th_bs_cnt), .th_ts_id(th_ts_id),
    .th_pri(th_pri), .th_burst_seq(th_burst_seq),
    .th_vtsk_c_seq(th_vtsk_c_seq), .th_dma_c_seq(th_dma_c_seq), .th_cw_seq(th_cw_seq),
    .ko_rdy(ko_rdy),
    .cw_upd_vld(cw_upd_vld), .cw_upd_tid(cw_upd_tid),
    .cw_upd_ind(cw_upd_ind), .cw_upd_data(cw_upd_data),
    .ready_mask(ready_mask),
    .ready_pri(ready_pri),
    .ready_burst_ts(ready_burst_ts),
    .ready_curts(ready_curts),
    .ready_burst(ready_burst),
    .iss_vld0(iss_vld0), .iss_tid0(iss_tid0),
    .iss_vld1(iss_vld1), .iss_tid1(iss_tid1),
    .cu_done_vld0(cu_done_vld0), .cu_done_tid0(cu_done_tid0),
    .cu_done_vld1(cu_done_vld1), .cu_done_tid1(cu_done_tid1),
    .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid),
    .emit_vld(1'b0), .emit_tid(6'd0),
    .pre_buf_rdy(pre_buf_rdy),
    .pre_vld(pre_vld), .pre_tid(pre_tid),
    .pre_dma_addr(pre_dma_addr), .pre_op(pre_op),
    .csr_dma_c(csr_dma_c),
    .csr_cw(csr_cw),
    .pre_dma_c(pre_dma_c),
    .pre_cw(pre_cw),
    .th_rel_vld(th_rel_vld),
    .th_rel_tid(th_rel_tid)
    );

    poe_thsch #(.MAX_THREADS(64)) u_thsch (
    .clk(clk), .rst_n(rst_n),
    .ready_mask(ready_mask),
    .ready_pri(ready_pri),
    .ready_burst_ts(ready_burst_ts),
    .ready_burst(ready_burst),
    .iss_vld0(iss_vld0), .iss_tid0(iss_tid0),
    .iss_vld1(iss_vld1), .iss_tid1(iss_tid1),
    .q0_vld(q0_vld), .q0_tid(q0_tid), .q0_ts(q0_ts),
    .q0_burst(q0_burst), .q0_pre(q0_pre), .q0_ack(q0_ack),
    .q1_vld(q1_vld), .q1_tid(q1_tid), .q1_ts(q1_ts),
    .q1_burst(q1_burst), .q1_pre(q1_pre), .q1_ack(q1_ack)
    );

    poe_burstsch #(.MAX_THREADS(64)) u_burstsch (
    .clk(clk), .rst_n(rst_n),
    .q0_vld(q0_vld), .q0_tid(q0_tid), .q0_ts(q0_ts),
    .q0_burst(q0_burst), .q0_pre(q0_pre), .q0_ack(q0_ack),
    .q1_vld(q1_vld), .q1_tid(q1_tid), .q1_ts(q1_ts),
    .q1_burst(q1_burst), .q1_pre(q1_pre), .q1_ack(q1_ack),
    .thread_curts(ready_curts),
    .csr_dma_c(csr_dma_c),
    .cw_fifo_cnt(cw_fifo_cnt), .th_res_n(th_res_n),
    .pre_dma_c(pre_dma_c),
    .owin_bp(owin_bp),
    .emit_cu_vld0(emit_cu_vld0), .emit_cu_tid0(emit_cu_tid0), .emit_cu_burst0(emit_cu_burst0),
    .cu0_ack(cu0_ack),
    .emit_cu_vld1(emit_cu_vld1), .emit_cu_tid1(emit_cu_tid1), .emit_cu_burst1(emit_cu_burst1),
    .cu1_ack(cu1_ack),
    .emit_dma_vld(emit_dma_vld), .emit_dma_tid(emit_dma_tid), .emit_dma_burst(emit_dma_burst),
    .emit_dma_pre(emit_dma_pre),
    .dma_ack(dma_ack),
    .pre_vld(pre_vld), .pre_tid(pre_tid),
    .pre_dma_addr(pre_dma_addr), .pre_op(pre_op),
    .pre_buf_rdy(pre_buf_rdy),
    .pre_op_vld(pre_op_vld), .pre_op_tid(pre_op_tid),
    .pre_op_addr(pre_op_addr), .pre_op_type(pre_op_type),
    .pre_op_ack(pre_op_ack)
    );

    poe_cu_stub #(.LATENCY(1)) u_cu0 (
    .clk(clk), .rst_n(rst_n),
    .emit_cu_vld(emit_cu_vld0), .emit_cu_tid(emit_cu_tid0), .emit_cu_burst(emit_cu_burst0),
    .cu_ack(cu0_ack),
    .cu_done_vld(cu_done_vld0), .cu_done_tid(cu_done_tid0)
    );

    poe_cu_stub #(.LATENCY(1)) u_cu1 (
    .clk(clk), .rst_n(rst_n),
    .emit_cu_vld(emit_cu_vld1), .emit_cu_tid(emit_cu_tid1), .emit_cu_burst(emit_cu_burst1),
    .cu_ack(cu1_ack),
    .cu_done_vld(cu_done_vld1), .cu_done_tid(cu_done_tid1)
    );

    poe_dma_ctrl u_dma (
    .clk(clk), .rst_n(rst_n),
    .emit_dma_vld(emit_dma_vld), .emit_dma_tid(emit_dma_tid), .emit_dma_burst(emit_dma_burst),
    .emit_dma_pre(emit_dma_pre),
    .csr_dma_c(csr_dma_c), .csr_cw(csr_cw),
    .thread_curts(ready_curts),
    .cw_upd_vld(cw_upd_vld), .cw_upd_tid(cw_upd_tid),
    .cw_upd_ind(cw_upd_ind), .cw_upd_data(cw_upd_data),
    .th_rel_vld(th_rel_vld), .th_rel_tid(th_rel_tid),
    .cw_fifo_cnt(cw_fifo_cnt), .th_res_n(th_res_n),
    .dma_ack(dma_ack),
    .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid),
    .pre_op_vld(pre_op_vld), .pre_op_tid(pre_op_tid),
    .pre_op_addr(pre_op_addr), .pre_op_type(pre_op_type),
    .pre_op_ack(pre_op_ack)
    );

    // O 窗反压占位：固定 0（O 窗池设计后续补充）
    assign owin_bp = 1'b0;

    // ---- 随机生成一条 i/v_task burst（32bit；burst_type=0） ----
    function automatic logic [31:0] rand_burst_iv(input logic st, input logic [2:0] ts_len);
        logic tr, branch, vld, c0, c1;
        logic [2:0] t0, t1;
        logic [7:0] sp0, sp1;
        tr = $urandom % 2;
        branch = $urandom % 2;
        vld = $urandom % 2;
        c0 = $urandom % 2;
        c1 = $urandom % 2;
        t0 = $urandom % 8;
        t1 = $urandom % 8;
        sp0 = $urandom % 256;
        sp1 = $urandom % 256;
        rand_burst_iv = {st, tr, ts_len, branch, 1'b0, vld, t0, c0, t1, c1, sp0, sp1};
    endfunction

    // ---- 随机生成一条 c_task burst（32bit；burst_type=1，单任务 vld_cu=0） ----
    // 资源约束：单线程最多 4 个 c 窗资源（执行完归还 + 线程结束兜底），每 ts 模式内
    // 只放 1 个单任务 c_task，避免资源紧张
    function automatic logic [31:0] rand_burst_c(input logic st, input logic [2:0] ts_len);
        logic [3:0] rev;
        logic [2:0] d0, d1;
        logic [7:0] o0, o1;
        rev = $urandom % 16;
        d0 = $urandom % 8;
        d1 = $urandom % 8;
        o0 = 1 + $urandom % 16;
        o1 = 1 + $urandom % 16;
        rand_burst_c = {st, 1'b0, rev, 1'b1, 1'b0, d0, 1'b1, d1, 1'b0, o0, o1};
    endfunction

    // ---- 首个 ts 的唯一 burst：固定只含 1 个 i_task（vld_cu=0、c0=1、c1=0） ----
    function automatic logic [31:0] rand_burst_ts0();
        logic tr, branch;
        logic [2:0] t0;
        logic [7:0] sp0;
        tr = $urandom % 2;
        branch = $urandom % 2;
        t0 = $urandom % 8;
        sp0 = $urandom % 256;
        rand_burst_ts0 = {1'b1, // st：ts 首个
                          tr,
                          3'd1, // ts_len：本 ts 仅 1 条
                          branch,
                          1'b0, // burst_type：i/v_task
                          1'b0, // vld_cu：1 个 task
                          t0,
                          1'b1, // c0：task0 有效
                          3'd0,
                          1'b0, // c1：task1 无效
                          sp0,
                          8'd0}; // sub_pc1 无效
    endfunction

    // ---- 每 ts 的 burst 模式（4 条）：每条独立随机类型（i/v 或 c） ----
    // ts0 固定 1 条且为单 i_task；其余 ts 条数 = ts_len（1..4），每条 iv/c 各 50%
    function automatic logic [127:0] rand_burst_ts(input int ts_idx, input logic [2:0] ts_len);
        logic [31:0] b [4];
        for (int k = 0; k < 4; k++) begin
            if (ts_idx == 0 && k == 0) begin
                b[k] = rand_burst_ts0();
            end else if (k < ts_len) begin
                if (($urandom % 2) == 0)
                    b[k] = rand_burst_iv((k == 0) ? 1'b1 : 1'b0, ts_len);
                else
                    b[k] = rand_burst_c((k == 0) ? 1'b1 : 1'b0, ts_len);
            end else begin
                b[k] = 32'd0; // 超出本 ts 条数：无效
            end
        end
        rand_burst_ts = {b[3], b[2], b[1], b[0]};
    endfunction

    // ---- CSR.cw 序列（8×6B）：op_type/tag 随机；o=0（未占据，由 dma_ctrl 按 loc/free 管理） ----
    function automatic logic [383:0] rand_cw_seq();
        cw_entry_t ce [8];
        logic [19:0] loc_tag [8];
        int nloc = 0;
        for (int k = 0; k < 8; k++) begin
            ce[k].tag = $urandom;
            ce[k].op_type = $urandom % 2;
            ce[k].r = 1'b0;
            ce[k].o = 1'b0;
            ce[k].c_line_num = 8'd0;
            ce[k].start_ts = 8'd0;
            ce[k].occ_ts = 1 + ($urandom % 16);
            ce[k].rsv = 1'b0;
            if (!ce[k].op_type) begin // loc 条目 tag 入池
                loc_tag[nloc] = ce[k].tag;
                nloc++;
            end
        end
        // free 条目 tag 从 loc 池取（配对：free 释放的是同地址 loc 占的资源）
        for (int k = 0; k < 8; k++)
            if (ce[k].op_type && (nloc > 0))
                ce[k].tag = loc_tag[$urandom % nloc];
        // 至少保证 1 个 loc 条目（无 loc 时线程没有可释放资源，free 全部无效）
        if (nloc == 0) begin
            ce[0].op_type = 1'b0;
            ce[0].tag = $urandom;
            for (int k = 1; k < 8; k++)
                if (ce[k].op_type) ce[k].tag = ce[0].tag;
        end
        rand_cw_seq = {ce[7], ce[6], ce[5], ce[4], ce[3], ce[2], ce[1], ce[0]};
    endfunction

    // ---- 临时调试日志 ----
    integer thm_logf;
    initial thm_logf = $fopen("thm_dbg.log", "w");
    always @(posedge clk) begin
        burst_c_t b0, b1;
        logic [7:0] dc0, dc1;
        logic [1:0] need0, need1;
        b0 = q0_burst;
        b1 = q1_burst;
        if (q0_pre) dc0 = pre_dma_c;
        else dc0 = csr_dma_c[q0_tid*8 +: 8];
        if (q1_pre) dc1 = pre_dma_c;
        else dc1 = csr_dma_c[q1_tid*8 +: 8];
        need0 = b0.vld_cu ? (b0.c0 & dc0[b0.dma_id0]) + (b0.c1 & dc0[b0.dma_id1])
        : (b0.c0 & dc0[b0.dma_id0]);
        need1 = b1.vld_cu ? (b1.c0 & dc1[b1.dma_id0]) + (b1.c1 & dc1[b1.dma_id1])
        : (b1.c0 & dc1[b1.dma_id0]);
        // 新语义：队列允许出现 cur_ts 及更靠后的 burst；q.ts < cur_ts 才属于异常。
        // pre_read 插队 burst 无线程归属，跳过 ts/cur_ts 比较
    if (q0_vld && !q0_pre && (q0_ts < ready_curts[q0_tid*6 +: 6]))
        $fdisplay(thm_logf, "OLD_BURST0 t=%0t q0ts=%0d curts=%0d tid=%0d st=%0d pc=%0d need=%0d tscnt=%0d",
        $time, q0_ts, ready_curts[q0_tid*6 +: 6], q0_tid,
            u_thm.th_state[q0_tid], u_thm.th_bs_pc[q0_tid],
        u_thm.th_need[q0_tid][u_thm.th_ts_idx[q0_tid]], u_thm.th_ts_n[q0_tid]);
    if (q1_vld && !q1_pre && (q1_ts < ready_curts[q1_tid*6 +: 6]))
        $fdisplay(thm_logf, "OLD_BURST1 t=%0t q1ts=%0d curts=%0d tid=%0d st=%0d pc=%0d need=%0d tscnt=%0d",
        $time, q1_ts, ready_curts[q1_tid*6 +: 6], q1_tid,
            u_thm.th_state[q1_tid], u_thm.th_bs_pc[q1_tid],
        u_thm.th_need[q1_tid][u_thm.th_ts_idx[q1_tid]], u_thm.th_ts_n[q1_tid]);
        if (emit_cu_vld0 || emit_cu_vld1) begin
            burst_iv_t eb;
            if (emit_cu_vld1) begin
                eb = emit_cu_burst1;
                $fdisplay(thm_logf, "EMIT_CU1 t=%0t tid=%0d ts=%0d st=%0d tr=%0d ts_len=%0d branch=%0d vld=%0d tsk=%0d/%0d c=%0d/%0d spc=%0d/%0d pc=%0d need=%0d tscnt=%0d",
                $time, emit_cu_tid1, ready_curts[emit_cu_tid1*6 +: 6],
                eb.st, eb.tr, eb.ts_len, eb.branch, eb.vld_cu,
                eb.tsk_id0, eb.tsk_id1, eb.c0, eb.c1, eb.sub_pc0, eb.sub_pc1,
                u_thm.th_bs_pc[emit_cu_tid1], u_thm.th_need[emit_cu_tid1][u_thm.th_ts_idx[emit_cu_tid1]],
                u_thm.th_ts_n[emit_cu_tid1]);
            end else begin
                eb = emit_cu_burst0;
                $fdisplay(thm_logf, "EMIT_CU t=%0t tid=%0d ts=%0d st=%0d tr=%0d ts_len=%0d branch=%0d vld=%0d tsk=%0d/%0d c=%0d/%0d spc=%0d/%0d pc=%0d need=%0d tscnt=%0d",
                $time, emit_cu_tid0, ready_curts[emit_cu_tid0*6 +: 6],
                eb.st, eb.tr, eb.ts_len, eb.branch, eb.vld_cu,
                eb.tsk_id0, eb.tsk_id1, eb.c0, eb.c1, eb.sub_pc0, eb.sub_pc1,
                u_thm.th_bs_pc[emit_cu_tid0], u_thm.th_need[emit_cu_tid0][u_thm.th_ts_idx[emit_cu_tid0]],
                u_thm.th_ts_n[emit_cu_tid0]);
            end
        end
        if (emit_dma_vld) begin
            burst_c_t eb;
            eb = emit_dma_burst;
            $fdisplay(thm_logf, "EMIT_DMA t=%0t tid=%0d dma_id=%0d/%0d occ_ts=%0d/%0d vld=%0d c=%0d/%0d pre=%0d",
            $time, emit_dma_tid, eb.dma_id0, eb.dma_id1, eb.occ_ts0, eb.occ_ts1,
            eb.vld_cu, eb.c0, eb.c1, emit_dma_pre);
        end
        // c_task 阻塞观测：公共条件满足但 C 窗资源不足（FIFO 空闲不足或线程达上限 4）
        if (q0_vld && (b0.burst_type == 1'b1) && !q0_pre &&
    (q0_ts == ready_curts[q0_tid*6 +: 6]) &&
                !((cw_fifo_cnt >= need0) &&
                    ({2'b0, th_res_n[q0_tid*2 +: 2]} + {2'b0, need0} <= 5'd4)))
                    $fdisplay(thm_logf, "CBLOCK0 t=%0t tid=%0d ts=%0d dma=%0d/%0d need=%0d fifo=%0d res=%0d",
                    $time, q0_tid, q0_ts, b0.dma_id0, b0.dma_id1, need0,
                    cw_fifo_cnt, th_res_n[q0_tid*2 +: 2]);
        if (q1_vld && (b1.burst_type == 1'b1) && !q1_pre &&
    (q1_ts == ready_curts[q1_tid*6 +: 6]) &&
                !((cw_fifo_cnt >= need1) &&
                    ({2'b0, th_res_n[q1_tid*2 +: 2]} + {2'b0, need1} <= 5'd4)))
                    $fdisplay(thm_logf, "CBLOCK1 t=%0t tid=%0d ts=%0d dma=%0d/%0d need=%0d fifo=%0d res=%0d",
                    $time, q1_tid, q1_ts, b1.dma_id0, b1.dma_id1, need1,
                    cw_fifo_cnt, th_res_n[q1_tid*2 +: 2]);
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
        if (cu_done_vld0)
            $fdisplay(thm_logf, "DONE t=%0t tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
        $time, cu_done_tid0, ready_curts[cu_done_tid0*6 +: 6],
            u_thm.csr[cu_done_tid0].cur_ts,
        u_thm.th_done[cu_done_tid0], u_thm.th_need[cu_done_tid0][u_thm.th_ts_idx[cu_done_tid0]],
            u_thm.th_ts_n[cu_done_tid0], u_thm.th_bs_pc[cu_done_tid0],
            u_thm.th_state[cu_done_tid0]);
        if (cu_done_vld1)
            $fdisplay(thm_logf, "DONE1 t=%0t tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
        $time, cu_done_tid1, ready_curts[cu_done_tid1*6 +: 6],
            u_thm.csr[cu_done_tid1].cur_ts,
        u_thm.th_done[cu_done_tid1], u_thm.th_need[cu_done_tid1][u_thm.th_ts_idx[cu_done_tid1]],
            u_thm.th_ts_n[cu_done_tid1], u_thm.th_bs_pc[cu_done_tid1],
            u_thm.th_state[cu_done_tid1]);
        if (dma_done_vld)
            $fdisplay(thm_logf, "DONE_DMA t=%0t tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
        $time, dma_done_tid, ready_curts[dma_done_tid*6 +: 6],
            u_thm.csr[dma_done_tid].cur_ts,
        u_thm.th_done[dma_done_tid], u_thm.th_need[dma_done_tid][u_thm.th_ts_idx[dma_done_tid]],
            u_thm.th_ts_n[dma_done_tid], u_thm.th_bs_pc[dma_done_tid],
            u_thm.th_state[dma_done_tid]);
    end

    // 线程描述旁路（模拟 I_BUF_A 中的线程结构，随 KO 报文同拍）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            th_ts_cnt <= 5'd0;
            th_bs_cnt <= 48'd0;
            th_ts_id <= 96'd0;
            th_pri <= 3'd0;
            th_burst_seq <= 2048'd0;
            th_vtsk_c_seq <= 8'd0;
            th_dma_c_seq <= 8'd0;
            th_cw_seq <= 384'd0;
        end else begin
            begin
                logic [2:0] bs [16];
                logic [5:0] id [16];
                automatic logic [2:0] jmp;
                th_ts_cnt <= 1 + ($urandom % 16); // 1..16 个 ts
                for (int k = 0; k < 16; k++) begin
                    bs[k] = (k == 0) ? 3'd1 : 1 + ($urandom % 4); // ts0 固定 1 条
                    // ts 编号递增；25% 概率跳转 1..3（模拟 ts 跳转目标；空间 0..63）
                    if (k == 0) id[k] = 6'd0;
                    else begin
                        jmp = 3'd0;
                        if (($urandom % 4) == 0) jmp = 1 + ($urandom % 3);
                        id[k] = id[k-1] + 1 + jmp;
                    end
                end
                for (int k = 0; k < 16; k++) begin
                    th_bs_cnt[k*3 +: 3] <= bs[k];
                    th_ts_id[k*6 +: 6] <= id[k];
                    th_burst_seq[k*128 +: 128] <= rand_burst_ts(k, bs[k]);
                end
                th_pri <= $urandom % 8;
                th_vtsk_c_seq <= $urandom; // CSR vtsk_c（占位）
                th_dma_c_seq <= $urandom; // CSR dma_c（占位）
                th_cw_seq <= rand_cw_seq(); // 8×6B：op_type/tag 随机，o=0
            end
        end
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
        int tot;
        tot = 0;
        for (i = 0; i < 64; i++) tot = tot + u_dma.th_res_n_r[i];
        // 资源池收支校验：f_cnt 应回到 256（全部归还）、th_res_total 应为 0
        $fdisplay(thm_logf, "FINAL f_cnt=%0d th_res_total=%0d st=%0d alloc=%0d free=%0d rel=%0d",
        u_dma.f_cnt, tot, u_dma.st, u_dma.dbg_alloc, u_dma.dbg_free, u_dma.dbg_rel);
    end
endmodule
