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
    .out_pos (u_if.out_pos)
    );

    // ================= POE 链路：KOA → THM → th_sch → burst_sch → CU/EU + dma_ctrl =================
    // 线程描述旁路（模拟 I_BUF_A 内容）：ts_cnt/bs_cnt/pri + 每 ts 的 burst 模式（32bit×4）
    logic [2:0] th_ts_cnt;
    logic [2:0] th_bs_cnt;
    logic [2:0] th_pri;
    logic [127:0] th_burst_seq; // 4×32bit burst（每 ts 复用）
    logic [7:0] th_vtsk_c_seq; // CSR vtsk_c
    logic [7:0] th_dma_c_seq; // CSR dma_c
    logic [383:0] th_cw_seq; // CSR cw（8×6B）
    logic ko_rdy;
    logic [63:0] ready_mask;
    logic [191:0] ready_pri;
    logic [127:0] ready_burst_ts;
    logic [127:0] ready_curts;
    logic [2047:0] ready_burst;
    logic iss_vld0, iss_vld1;
    logic [5:0] iss_tid0, iss_tid1;
    logic pre_inj_vld, pre_inj_rdy;
    logic [5:0] pre_inj_tid;
    logic [1:0] pre_inj_ts;
    logic [31:0] pre_inj_burst;
    logic ko_pre_read;
    logic q0_vld, q1_vld;
    logic [5:0] q0_tid, q1_tid;
    logic [1:0] q0_ts, q1_ts;
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
    logic emit_cu_vld, cu_ack;
    logic [5:0] emit_cu_tid;
    logic [31:0] emit_cu_burst;
    logic emit_dma_vld, dma_ack;
    logic [5:0] emit_dma_tid;
    logic [31:0] emit_dma_burst;
    logic emit_dma_pre;
    logic cu_done_vld;
    logic [5:0] cu_done_tid;
    logic dma_done_vld;
    logic [5:0] dma_done_tid;

    poe_thm #(.MAX_THREADS(64)) u_thm (
    .clk(clk), .rst_n(rst_n),
    .ko_vld(u_if.out_vld), .ko_data(u_if.out_data),
    .ko_stream(u_if.out_stream), .ko_cid(u_if.out_cid), .ko_pos(u_if.out_pos),
    .ko_pre_read(ko_pre_read),
    .th_ts_cnt(th_ts_cnt), .th_bs_cnt(th_bs_cnt),
    .th_pri(th_pri), .th_burst_seq(th_burst_seq),
    .th_vtsk_c_seq(th_vtsk_c_seq), .th_dma_c_seq(th_dma_c_seq), .th_cw_seq(th_cw_seq),
    .ko_rdy(ko_rdy),
    .ready_mask(ready_mask),
    .ready_pri(ready_pri),
    .ready_burst_ts(ready_burst_ts),
    .ready_curts(ready_curts),
    .ready_burst(ready_burst),
    .iss_vld0(iss_vld0), .iss_tid0(iss_tid0),
    .iss_vld1(iss_vld1), .iss_tid1(iss_tid1),
    .cu_done_vld(cu_done_vld), .cu_done_tid(cu_done_tid),
    .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid),
    .emit_vld(emit_cu_vld), .emit_tid(emit_cu_tid),
    .pre_inj_rdy(pre_inj_rdy),
    .pre_inj_vld(pre_inj_vld),
    .pre_inj_tid(pre_inj_tid),
    .pre_inj_ts(pre_inj_ts),
    .pre_inj_burst(pre_inj_burst),
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
    .pre_inj_vld(pre_inj_vld),
    .pre_inj_tid(pre_inj_tid),
    .pre_inj_ts(pre_inj_ts),
    .pre_inj_burst(pre_inj_burst),
    .pre_inj_rdy(pre_inj_rdy),
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
    .emit_cu_vld(emit_cu_vld), .emit_cu_tid(emit_cu_tid), .emit_cu_burst(emit_cu_burst),
    .cu_ack(cu_ack),
    .emit_dma_vld(emit_dma_vld), .emit_dma_tid(emit_dma_tid), .emit_dma_burst(emit_dma_burst),
    .emit_dma_pre(emit_dma_pre),
    .dma_ack(dma_ack)
    );

    poe_cu_stub #(.LATENCY(1)) u_cu (
    .clk(clk), .rst_n(rst_n),
    .emit_cu_vld(emit_cu_vld), .emit_cu_tid(emit_cu_tid), .emit_cu_burst(emit_cu_burst),
    .cu_ack(cu_ack),
    .cu_done_vld(cu_done_vld), .cu_done_tid(cu_done_tid)
    );

    poe_dma_ctrl_stub #(.LATENCY(1)) u_dma (
    .clk(clk), .rst_n(rst_n),
    .emit_dma_vld(emit_dma_vld), .emit_dma_tid(emit_dma_tid), .emit_dma_burst(emit_dma_burst),
    .emit_dma_pre(emit_dma_pre),
    .csr_dma_c(csr_dma_c), .csr_cw(csr_cw),
    .pre_dma_c(pre_dma_c), .pre_cw(pre_cw),
    .th_rel_vld(th_rel_vld), .th_rel_tid(th_rel_tid),
    .cw_fifo_cnt(cw_fifo_cnt), .th_res_n(th_res_n),
    .dma_ack(dma_ack),
    .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid)
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

    // ---- 每 ts 的 burst 模式（4 条）：随机选 1 个位置放 c_task，其余 i/v_task ----
    function automatic logic [127:0] rand_burst_seq(input logic [2:0] ts_len);
        int cpos;
        logic [31:0] b [4];
        cpos = $urandom % 4;
        for (int k = 0; k < 4; k++) begin
            if (k == cpos) b[k] = rand_burst_c((k == 0) ? 1'b1 : 1'b0, ts_len);
            else b[k] = rand_burst_iv((k == 0) ? 1'b1 : 1'b0, ts_len);
        end
        rand_burst_seq = {b[3], b[2], b[1], b[0]};
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
        if (q0_vld && !q0_pre && (q0_ts < ready_curts[q0_tid*2 +: 2]))
            $fdisplay(thm_logf, "OLD_BURST0 t=%0t q0ts=%0d curts=%0d tid=%0d st=%0d pc=%0d need=%0d tscnt=%0d",
            $time, q0_ts, ready_curts[q0_tid*2 +: 2], q0_tid,
            u_thm.th_state[q0_tid], u_thm.th_bs_pc[q0_tid],
            u_thm.th_need[q0_tid], u_thm.th_ts_n[q0_tid]);
        if (q1_vld && !q1_pre && (q1_ts < ready_curts[q1_tid*2 +: 2]))
            $fdisplay(thm_logf, "OLD_BURST1 t=%0t q1ts=%0d curts=%0d tid=%0d st=%0d pc=%0d need=%0d tscnt=%0d",
            $time, q1_ts, ready_curts[q1_tid*2 +: 2], q1_tid,
            u_thm.th_state[q1_tid], u_thm.th_bs_pc[q1_tid],
            u_thm.th_need[q1_tid], u_thm.th_ts_n[q1_tid]);
        if (emit_cu_vld) begin
            burst_iv_t eb;
            eb = emit_cu_burst;
            $fdisplay(thm_logf, "EMIT_CU t=%0t tid=%0d ts=%0d st=%0d tr=%0d ts_len=%0d branch=%0d vld=%0d tsk=%0d/%0d c=%0d/%0d spc=%0d/%0d pc=%0d need=%0d tscnt=%0d",
            $time, emit_cu_tid, ready_curts[emit_cu_tid*2 +: 2],
            eb.st, eb.tr, eb.ts_len, eb.branch, eb.vld_cu,
            eb.tsk_id0, eb.tsk_id1, eb.c0, eb.c1, eb.sub_pc0, eb.sub_pc1,
            u_thm.th_bs_pc[emit_cu_tid], u_thm.th_need[emit_cu_tid],
            u_thm.th_ts_n[emit_cu_tid]);
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
            (q0_ts == ready_curts[q0_tid*2 +: 2]) &&
                !((cw_fifo_cnt >= need0) &&
                    ({2'b0, th_res_n[q0_tid*2 +: 2]} + {2'b0, need0} <= 5'd4)))
                    $fdisplay(thm_logf, "CBLOCK0 t=%0t tid=%0d ts=%0d dma=%0d/%0d need=%0d fifo=%0d res=%0d",
                    $time, q0_tid, q0_ts, b0.dma_id0, b0.dma_id1, need0,
                    cw_fifo_cnt, th_res_n[q0_tid*2 +: 2]);
        if (q1_vld && (b1.burst_type == 1'b1) && !q1_pre &&
            (q1_ts == ready_curts[q1_tid*2 +: 2]) &&
                !((cw_fifo_cnt >= need1) &&
                    ({2'b0, th_res_n[q1_tid*2 +: 2]} + {2'b0, need1} <= 5'd4)))
                    $fdisplay(thm_logf, "CBLOCK1 t=%0t tid=%0d ts=%0d dma=%0d/%0d need=%0d fifo=%0d res=%0d",
                    $time, q1_tid, q1_ts, b1.dma_id0, b1.dma_id1, need1,
                    cw_fifo_cnt, th_res_n[q1_tid*2 +: 2]);
        if (iss_vld0)
            $fdisplay(thm_logf, "ISS0 t=%0t tid=%0d curts=%0d burst_ts=%0d pc=%0d need=%0d tscnt=%0d st=%0d",
            $time, iss_tid0, ready_curts[iss_tid0*2 +: 2],
            ready_burst_ts[iss_tid0*2 +: 2],
            u_thm.th_bs_pc[iss_tid0], u_thm.th_need[iss_tid0],
            u_thm.th_ts_n[iss_tid0], u_thm.th_state[iss_tid0]);
        if (iss_vld1)
            $fdisplay(thm_logf, "ISS1 t=%0t tid=%0d curts=%0d burst_ts=%0d pc=%0d need=%0d tscnt=%0d st=%0d",
            $time, iss_tid1, ready_curts[iss_tid1*2 +: 2],
            ready_burst_ts[iss_tid1*2 +: 2],
            u_thm.th_bs_pc[iss_tid1], u_thm.th_need[iss_tid1],
            u_thm.th_ts_n[iss_tid1], u_thm.th_state[iss_tid1]);
        if (cu_done_vld)
            $fdisplay(thm_logf, "DONE t=%0t tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
            $time, cu_done_tid, ready_curts[cu_done_tid*2 +: 2],
            u_thm.csr[cu_done_tid].cur_ts,
            u_thm.th_done[cu_done_tid], u_thm.th_need[cu_done_tid],
            u_thm.th_ts_n[cu_done_tid], u_thm.th_bs_pc[cu_done_tid],
            u_thm.th_state[cu_done_tid]);
        if (dma_done_vld)
            $fdisplay(thm_logf, "DONE_DMA t=%0t tid=%0d curts=%0d csr_curts=%0d done=%0d need=%0d tscnt=%0d pc=%0d st=%0d",
            $time, dma_done_tid, ready_curts[dma_done_tid*2 +: 2],
            u_thm.csr[dma_done_tid].cur_ts,
            u_thm.th_done[dma_done_tid], u_thm.th_need[dma_done_tid],
            u_thm.th_ts_n[dma_done_tid], u_thm.th_bs_pc[dma_done_tid],
            u_thm.th_state[dma_done_tid]);
    end

    // 线程描述旁路（模拟 I_BUF_A 中的线程结构，随 KO 报文同拍）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            th_ts_cnt <= 3'd0;
            th_bs_cnt <= 3'd0;
            th_pri <= 3'd0;
            th_burst_seq <= 128'd0;
            th_vtsk_c_seq <= 8'd0;
            th_dma_c_seq <= 8'd0;
            th_cw_seq <= 384'd0;
        end else begin
            th_ts_cnt <= 1 + ($urandom % 4); // 1..4 个 ts
            th_bs_cnt <= 1 + ($urandom % 4); // 每 ts 1..4 个 burst（= ts_len）
            th_pri <= $urandom % 8;
            th_burst_seq <= rand_burst_seq(1 + ($urandom % 4));
            th_vtsk_c_seq <= $urandom; // CSR vtsk_c（占位）
            th_dma_c_seq <= $urandom; // CSR dma_c（占位）
            th_cw_seq <= {$urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom,
            $urandom, $urandom, $urandom, $urandom}; // 8×6B（占位）
        end
    end

    // pre_read 标志占位：约 1/16 的 KO 带 pre_read（实际应由 KO 报文字段决定）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ko_pre_read <= 1'b0;
        else ko_pre_read <= ($urandom % 16) == 0;
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
        $fdisplay(thm_logf, "FINAL f_cnt=%0d th_res_total=%0d alloc_cnt_r=%0d busy=%0d dbg_alloc=%0d dbg_free=%0d dbg_done=%0d",
        u_dma.f_cnt, tot, u_dma.alloc_cnt_r, u_dma.busy,
        u_dma.dbg_alloc, u_dma.dbg_free, u_dma.dbg_done);
    end
endmodule
