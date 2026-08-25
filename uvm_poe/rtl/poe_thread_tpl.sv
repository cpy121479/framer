// ============================================================================
// POE 线程模板池（THM 建线程时随机选取，替代激励旁路线程描述）
// 对应《poe_thm实现方案.md》：THM 不再从 KOA/tb 接收完整线程描述，
// 而是在创建线程时从模板池随机选一个模板，解出全部线程字段。
//
// 线程模板字段（与 THM 建线程所需一致）：
//   ts_cnt      ts 数（1..16）
//   ts_bs       每 ts burst 数（16×4bit，0..8，ts0 固定 1）
//   ts_id       每 ts 编号（16×6bit，递增可跳转，模拟 ts 跳转）
//   pri         线程 burst 优先级（0 最高）
//   burst_seq   每 ts burst 模式（16 ts × 8 burst × 38bit，含 ts 级锁字段）
//   vtsk_c      CSR vtsk_c：i/v 任务执行掩码
//   dma_c       CSR dma_c：c_task 执行指示（8bit 掩码，对应 cw 8 项）
//   cw          CSR cw：c_task 操作表（8×6B，条目 48bit）
//
// 模板覆盖场景：短 i/v、混合 i/v+c_task、长线程+ts_id 跳变、DMA 密集、
// 单段持锁、双段持锁（ts 级互斥锁：lock_req/unlock_req 仅 ts 首个 burst 生效）、
// 空 c_task（无有效任务，不产生 done，ts 推进不依赖 dma_ctrl）。
// ============================================================================
package poe_thread_tpl_pkg;

    import poe_types_pkg::*;

    localparam int TPL_MAX_TS = 16;
    localparam int TPL_MAX_BURST = 8; // 每 ts 最多 burst 数

    // ---- 线程模板（打包结构） ----
    typedef struct packed {
        logic [4:0] ts_cnt; // ts 数（1..16）
        logic [2:0] pri; // 优先级
        logic [TPL_MAX_TS*4-1:0] ts_bs; // 每 ts burst 数（0..8）
        logic [TPL_MAX_TS*6-1:0] ts_id; // 每 ts 编号
        logic [TPL_MAX_TS*TPL_MAX_BURST*BURST_W-1:0] burst_seq; // 每 ts burst 模式
        logic [7:0] vtsk_c;
        logic [7:0] dma_c;
        logic [383:0] cw; // 8×6B
    } thread_tpl_t;

    localparam int N_TPL = 10; // 模板数量（T0..T9）

    // ==================== 辅助构造函数 ====================

    // i/v_task burst（38bit；锁字段可单独设置）
    function automatic logic [BURST_W-1:0] tpl_iv(
        input logic st, input logic [2:0] ts_len,
        input logic branch, input logic tr, input logic [2:0] tsk0);
        burst_iv_t b;
        b = '0;
        b.lock_id = 4'd0;
        b.unlock_req = 1'b0;
        b.lock_req = 1'b0;
        b.st = st;
        b.tr = tr;
        b.ts_len = ts_len;
        b.branch = branch;
        b.burst_type = 1'b0; // i/v
        b.vld_cu = 1'b0; // 单任务
        b.tsk_id0 = tsk0;
        b.c0 = 1'b1;
        b.tsk_id1 = 3'd0;
        b.c1 = 1'b0;
        b.sub_pc0 = 8'h10;
        b.sub_pc1 = 8'h00;
        tpl_iv = b;
    endfunction

    // c_task burst（38bit，单任务；dma_id 与 cw 配对；occ0 参数为占位——
    // THM 建线程时对 occ_ts 运行时随机 1-4 覆盖）
    function automatic logic [BURST_W-1:0] tpl_c(
        input logic st, input logic [2:0] dma0, input logic [7:0] occ0);
        burst_c_t b;
        b = '0;
        b.lock_id = 4'd0;
        b.unlock_req = 1'b0;
        b.lock_req = 1'b0;
        b.st = st;
        b.tr = 1'b0;
        b.rev = 4'd0;
        b.burst_type = 1'b1; // c_task
        b.vld_cu = 1'b0; // 单任务
        b.dma_id0 = dma0;
        b.c0 = 1'b1;
        b.dma_id1 = 3'd0;
        b.c1 = 1'b0;
        b.occ_ts0 = occ0;
        b.occ_ts1 = 8'd1;
        tpl_c = b;
    endfunction

    // 对 burst 设置 ts 级锁字段（lock/unlock 仅 st=1 有效）
    function automatic logic [BURST_W-1:0] tpl_set_lock(
        input logic [BURST_W-1:0] b,
        input logic [3:0] lock_id, input logic lock_req, input logic unlock_req);
        automatic logic [BURST_W-1:0] r = b;
        r[BURST_W-1 -: 4] = lock_id;
        r[BURST_W-5] = unlock_req;
        r[BURST_W-6] = lock_req;
        tpl_set_lock = r;
    endfunction

    // cw 条目（48bit）
    function automatic logic [47:0] tpl_cw_entry(
        input logic [19:0] tag, input logic op_type);
        cw_entry_t ce;
        ce = '0;
        ce.tag = tag;
        ce.op_type = op_type; // 0=loc 1=free
        ce.r = 1'b0;
        ce.o = 1'b0;
        ce.c_line_num = 8'd0;
        ce.start_ts = 8'd0;
        ce.occ_ts = 8'd4;
        ce.rsv = 1'b0;
        tpl_cw_entry = ce;
    endfunction

    // 把 8 个 burst 写入模板第 k 个 ts（每 ts 8×38bit；未用槽填 '0）
    function automatic void tpl_put_ts8(inout thread_tpl_t t, input int k,
        input logic [BURST_W-1:0] b0, input logic [BURST_W-1:0] b1,
        input logic [BURST_W-1:0] b2, input logic [BURST_W-1:0] b3,
        input logic [BURST_W-1:0] b4, input logic [BURST_W-1:0] b5,
        input logic [BURST_W-1:0] b6, input logic [BURST_W-1:0] b7);
        t.burst_seq[k*(8*BURST_W) +: 8*BURST_W] = {b7, b6, b5, b4, b3, b2, b1, b0};
    endfunction
    // 兼容 4 参数调用（写入低 4 槽）
    function automatic void tpl_put_ts(inout thread_tpl_t t, input int k,
        input logic [BURST_W-1:0] b0, input logic [BURST_W-1:0] b1,
        input logic [BURST_W-1:0] b2, input logic [BURST_W-1:0] b3);
        tpl_put_ts8(t, k, b0, b1, b2, b3, '0, '0, '0, '0);
    endfunction

    // ==================== 模板定义 ====================

    // ---- T0：短 i/v 线程（2 ts，纯计算，无 c_task / 无锁） ----
    function automatic thread_tpl_t tpl_short_iv();
        thread_tpl_t t;
        t = '0;
        t.ts_cnt = 5'd2;
        t.pri = 3'd1;
        t.ts_bs[3:0] = 4'd1; // ts0 固定 1
        t.ts_bs[7:4] = 4'd2; // ts1 2 条
        t.ts_id[5:0] = 6'd0;
        t.ts_id[11:6] = 6'd1;
        tpl_put_ts(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0), '0, '0, '0);
        tpl_put_ts(t, 1, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd1),
                        tpl_iv(1'b0, 3'd2, 1'b1, 1'b0, 3'd2), '0, '0);
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h00;
        t.cw = '0;
        tpl_short_iv = t;
    endfunction

    // ---- T1：混合线程（4 ts，1 对共享 c_task loc/free，无锁） ----
    function automatic thread_tpl_t tpl_mix_1pair();
        thread_tpl_t t;
        automatic logic [19:0] tg;
        t = '0;
        t.ts_cnt = 5'd4;
        t.pri = 3'd2;
        t.ts_bs[3:0] = 4'd1;
        t.ts_bs[7:4] = 4'd2;
        t.ts_bs[11:8] = 4'd2;
        t.ts_bs[15:12] = 4'd1;
        t.ts_id[5:0] = 6'd0;
        t.ts_id[11:6] = 6'd1;
        t.ts_id[17:12] = 6'd2;
        t.ts_id[23:18] = 6'd3;
        tpl_put_ts(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0), '0, '0, '0);
        tpl_put_ts(t, 1, tpl_iv(1'b1, 3'd2, 1'b0, 1'b1, 3'd1),
                        tpl_c(1'b0, 3'd4, 8'd4), '0, '0); // ts1: dma4 loc（共享）
        tpl_put_ts(t, 2, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd2),
                        tpl_c(1'b0, 3'd5, 8'd4), '0, '0); // ts2: dma5 free（共享）
        tpl_put_ts(t, 3, tpl_iv(1'b1, 3'd1, 1'b1, 1'b0, 3'd3), '0, '0, '0);
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h30; // dma4/5 有效
        t.cw = {6{48'd0}};
        tg = $urandom % 4; // tag/DSE 0..3 随机（配对同 tag）
        t.cw[239:192] = tpl_cw_entry(tg, 1'b0); // cw[4] loc
        t.cw[287:240] = tpl_cw_entry(tg, 1'b1); // cw[5] free
        tpl_mix_1pair = t;
    endfunction

    // ---- T2：长线程 + ts_id 跳变（8 ts，1 对 c_task） ----
    function automatic thread_tpl_t tpl_long_branch();
        thread_tpl_t t;
        automatic logic [19:0] tg;
        t = '0;
        t.ts_cnt = 5'd8;
        t.pri = 3'd3;
        // 每 ts burst 数
        t.ts_bs[3:0] = 4'd1;
        t.ts_bs[7:4] = 4'd2;
        t.ts_bs[11:8] = 4'd1;
        t.ts_bs[15:12] = 4'd2;
        t.ts_bs[19:16] = 4'd1;
        t.ts_bs[23:20] = 4'd2;
        t.ts_bs[27:24] = 4'd2;
        t.ts_bs[31:28] = 4'd1;
        // ts 编号递增可跳转（模拟跳转目标）
        t.ts_id[5:0] = 6'd0;
        t.ts_id[11:6] = 6'd1;
        t.ts_id[17:12] = 6'd3;
        t.ts_id[23:18] = 6'd4;
        t.ts_id[29:24] = 6'd7;
        t.ts_id[35:30] = 6'd9;
        t.ts_id[41:36] = 6'd11;
        t.ts_id[47:42] = 6'd13;
        tpl_put_ts(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0), '0, '0, '0);
        tpl_put_ts(t, 1, tpl_iv(1'b1, 3'd2, 1'b1, 1'b0, 3'd1), // branch 在 ts1
                        tpl_iv(1'b0, 3'd2, 1'b0, 1'b1, 3'd2), '0, '0);
        tpl_put_ts(t, 2, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd3), '0, '0, '0);
        tpl_put_ts(t, 3, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd4),
                        tpl_c(1'b0, 3'd4, 8'd4), '0, '0); // loc（共享）
        tpl_put_ts(t, 4, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd5), '0, '0, '0);
        tpl_put_ts(t, 5, tpl_iv(1'b1, 3'd2, 1'b0, 1'b1, 3'd6),
                        tpl_c(1'b0, 3'd5, 8'd4), '0, '0); // free（共享）
        tpl_put_ts(t, 6, tpl_iv(1'b1, 3'd2, 1'b1, 1'b0, 3'd7),
                        tpl_iv(1'b0, 3'd2, 1'b0, 1'b0, 3'd0), '0, '0);
        tpl_put_ts(t, 7, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd1), '0, '0, '0);
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h30;
        t.cw = {6{48'd0}};
        tg = $urandom % 4;
        t.cw[239:192] = tpl_cw_entry(tg, 1'b0); // cw[4] loc
        t.cw[287:240] = tpl_cw_entry(tg, 1'b1); // cw[5] free
        tpl_long_branch = t;
    endfunction

    // ---- T3：DMA 密集线程（6 ts，3 对 c_task） ----
    // 仅同配对的 loc/free 分处不同 ts（pair3：loc dma4→ts4、free dma5→ts5）；
    // 不同配对可同 ts（ts4 含 pair2 的 free dma3 与 pair3 的 loc dma4，无依赖）
    function automatic thread_tpl_t tpl_dma_dense();
        thread_tpl_t t;
        automatic logic [19:0] tg;
        t = '0;
        t.ts_cnt = 5'd6;
        t.pri = 3'd0;
        t.ts_bs[3:0] = 4'd1;
        t.ts_bs[7:4] = 4'd2;
        t.ts_bs[11:8] = 4'd2;
        t.ts_bs[15:12] = 4'd2;
        t.ts_bs[19:16] = 4'd3;
        t.ts_bs[23:20] = 4'd2;
        t.ts_id[5:0] = 6'd0;
        t.ts_id[11:6] = 6'd1;
        t.ts_id[17:12] = 6'd2;
        t.ts_id[23:18] = 6'd3;
        t.ts_id[29:24] = 6'd4;
        t.ts_id[35:30] = 6'd5;
        tpl_put_ts(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0), '0, '0, '0);
        // 配对 1（dma0/1）、配对 2（dma2/3）、配对 3（dma4/5）
        tpl_put_ts(t, 1, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd1),
                        tpl_c(1'b0, 3'd0, 8'd4), '0, '0); // loc dma0
        tpl_put_ts(t, 2, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd2),
                        tpl_c(1'b0, 3'd1, 8'd4), '0, '0); // free dma1
        tpl_put_ts(t, 3, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd3),
                        tpl_c(1'b0, 3'd2, 8'd4), '0, '0); // loc dma2
        // ts4：free dma3（pair2）+ loc dma4（pair3）——不同配对同 ts，无依赖
        tpl_put_ts(t, 4, tpl_iv(1'b1, 3'd3, 1'b0, 1'b0, 3'd4),
                        tpl_c(1'b0, 3'd3, 8'd4), // free dma3
                        tpl_c(1'b0, 3'd4, 8'd4), '0); // loc dma4
        tpl_put_ts(t, 5, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd5),
                        tpl_c(1'b0, 3'd5, 8'd4), '0, '0); // free dma5
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h3F; // dma0..5 有效
        t.cw = '0;
        tg = $urandom % 4; // 配对 1
        t.cw[47:0] = tpl_cw_entry(tg, 1'b0); // cw[0] loc
        t.cw[95:48] = tpl_cw_entry(tg, 1'b1); // cw[1] free
        tg = $urandom % 4; // 配对 2
        t.cw[143:96] = tpl_cw_entry(tg, 1'b0); // cw[2] loc
        t.cw[191:144] = tpl_cw_entry(tg, 1'b1); // cw[3] free
        tg = $urandom % 4; // 配对 3
        t.cw[239:192] = tpl_cw_entry(tg, 1'b0); // cw[4] loc
        t.cw[287:240] = tpl_cw_entry(tg, 1'b1); // cw[5] free
        tpl_dma_dense = t;
    endfunction

    // ---- T4：单段持锁线程（5 ts，ts0 lock、ts3 unlock，锁 ID=0） ----
    function automatic thread_tpl_t tpl_locked();
        thread_tpl_t t;
        automatic logic [BURST_W-1:0] b;
        automatic logic [19:0] tg;
        t = '0;
        t.ts_cnt = 5'd5;
        t.pri = 3'd2;
        t.ts_bs[3:0] = 4'd1;
        t.ts_bs[7:4] = 4'd2;
        t.ts_bs[11:8] = 4'd1;
        t.ts_bs[15:12] = 4'd2;
        t.ts_bs[19:16] = 4'd1;
        t.ts_id[5:0] = 6'd0;
        t.ts_id[11:6] = 6'd1;
        t.ts_id[17:12] = 6'd2;
        t.ts_id[23:18] = 6'd3;
        t.ts_id[29:24] = 6'd4;
        // ts0 首个 burst：加锁 lock_id=0
        b = tpl_set_lock(tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0), 4'd0, 1'b1, 1'b0);
        tpl_put_ts(t, 0, b, '0, '0, '0);
        // ts1：i/v + c_task loc（持锁执行）
        tpl_put_ts(t, 1, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd1),
                        tpl_c(1'b0, 3'd4, 8'd4), '0, '0);
        tpl_put_ts(t, 2, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd2), '0, '0, '0);
        // ts3 首个 burst：解锁 lock_id=0（该 ts 完成时释放）
        b = tpl_set_lock(tpl_iv(1'b1, 3'd2, 1'b0, 1'b1, 3'd3), 4'd0, 1'b0, 1'b1);
        tpl_put_ts(t, 3, b, tpl_c(1'b0, 3'd5, 8'd4), '0, '0);
        tpl_put_ts(t, 4, tpl_iv(1'b1, 3'd1, 1'b1, 1'b0, 3'd4), '0, '0, '0);
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h30;
        t.cw = {6{48'd0}};
        tg = $urandom % 4;
        t.cw[239:192] = tpl_cw_entry(tg, 1'b0); // cw[4] loc
        t.cw[287:240] = tpl_cw_entry(tg, 1'b1); // cw[5] free
        tpl_locked = t;
    endfunction

    // ---- T5：双段持锁线程（7 ts，同一锁 id=1：ts0 lock、ts2 unlock、ts3 lock、ts6 unlock） ----
    function automatic thread_tpl_t tpl_double_lock();
        thread_tpl_t t;
        automatic logic [BURST_W-1:0] b;
        automatic logic [19:0] tg;
        t = '0;
        t.ts_cnt = 5'd7;
        t.pri = 3'd4;
        t.ts_bs[3:0] = 4'd1;
        t.ts_bs[7:4] = 4'd2;
        t.ts_bs[11:8] = 4'd1;
        t.ts_bs[15:12] = 4'd1;
        t.ts_bs[19:16] = 4'd2;
        t.ts_bs[23:20] = 4'd2;
        t.ts_bs[27:24] = 4'd1;
        t.ts_id[5:0] = 6'd0;
        t.ts_id[11:6] = 6'd1;
        t.ts_id[17:12] = 6'd2;
        t.ts_id[23:18] = 6'd4;
        t.ts_id[29:24] = 6'd6;
        t.ts_id[35:30] = 6'd7;
        t.ts_id[41:36] = 6'd8;
        b = tpl_set_lock(tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0), 4'd1, 1'b1, 1'b0);
        tpl_put_ts(t, 0, b, '0, '0, '0); // ts0 lock(1)
        tpl_put_ts(t, 1, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd1),
                        tpl_iv(1'b0, 3'd2, 1'b0, 1'b1, 3'd2), '0, '0);
        b = tpl_set_lock(tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd3), 4'd1, 1'b0, 1'b1);
        tpl_put_ts(t, 2, b, '0, '0, '0); // ts2 unlock(1)
        b = tpl_set_lock(tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd4), 4'd1, 1'b1, 1'b0);
        tpl_put_ts(t, 3, b, '0, '0, '0); // ts3 lock（段2，锁 id=1）
        tpl_put_ts(t, 4, tpl_iv(1'b1, 3'd2, 1'b0, 1'b1, 3'd5),
                        tpl_c(1'b0, 3'd4, 8'd4), '0, '0); // ts4: loc dma4（持锁 2）
        tpl_put_ts(t, 5, tpl_iv(1'b1, 3'd2, 1'b0, 1'b1, 3'd6),
                        tpl_c(1'b0, 3'd5, 8'd4), '0, '0); // ts5: free dma5（配对释放）
        b = tpl_set_lock(tpl_iv(1'b1, 3'd1, 1'b1, 1'b0, 3'd7), 4'd1, 1'b0, 1'b1);
        tpl_put_ts(t, 6, b, '0, '0, '0); // ts6 unlock（段2，锁 id=1）
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h30;
        t.cw = {6{48'd0}};
        tg = $urandom % 4;
        t.cw[239:192] = tpl_cw_entry(tg, 1'b0); // cw[4] loc
        t.cw[287:240] = tpl_cw_entry(tg, 1'b1); // cw[5] free
        tpl_double_lock = t;
    endfunction

    // ==================== 池接口 ====================

    // ---- T6：c_task 密集（16 ts，每 ts 8 burst：1 iv + 7 c_task，RBA/FIFO 高压力） ----
    function automatic thread_tpl_t tpl_hp_c();
        thread_tpl_t t;
        automatic logic [19:0] tg;
        t = '0;
        t.ts_cnt = 5'd16;
        t.pri = 3'd0;
        t.ts_bs[3:0] = 4'd1;
        for (int k = 1; k < 16; k++) t.ts_bs[k*4 +: 4] = 4'd8;
        for (int k = 0; k < 16; k++) t.ts_id[k*6 +: 6] = k[5:0];
        tpl_put_ts8(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0),
                    '0, '0, '0, '0, '0, '0, '0);
        for (int k = 1; k < 16; k++)
            tpl_put_ts8(t, k,
                tpl_iv(1'b1, 3'd7, 1'b0, 1'b0, 3'd0),
                tpl_c(1'b0, 3'd0, 8'd4), tpl_c(1'b0, 3'd1, 8'd4),
                tpl_c(1'b0, 3'd2, 8'd4), tpl_c(1'b0, 3'd3, 8'd4),
                tpl_c(1'b0, 3'd4, 8'd4), tpl_c(1'b0, 3'd5, 8'd4),
                tpl_c(1'b0, 3'd6, 8'd4));
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h7F; // dma0..6 有效
        t.cw = '0;
        tg = $urandom % 4; // 配对 1（dma0/1）
        t.cw[47:0] = tpl_cw_entry(tg, 1'b0);
        t.cw[95:48] = tpl_cw_entry(tg, 1'b1);
        tg = $urandom % 4; // 配对 2（dma2/3）
        t.cw[143:96] = tpl_cw_entry(tg, 1'b0);
        t.cw[191:144] = tpl_cw_entry(tg, 1'b1);
        tg = $urandom % 4; // 配对 3（dma4/5）
        t.cw[239:192] = tpl_cw_entry(tg, 1'b0);
        t.cw[287:240] = tpl_cw_entry(tg, 1'b1);
        tg = $urandom % 4; // dma6 单条
        t.cw[335:288] = tpl_cw_entry(tg, 1'b0);
        tpl_hp_c = t;
    endfunction

    // ---- T7：i/v 密集（16 ts，每 ts 8 i/v，奇数 ts 第 6 条 br（预留），其后 ts_id 跳变） ----
    function automatic thread_tpl_t tpl_hp_iv();
        thread_tpl_t t;
        t = '0;
        t.ts_cnt = 5'd16;
        t.pri = 3'd1;
        t.ts_bs[3:0] = 4'd1;
        for (int k = 1; k < 16; k++) t.ts_bs[k*4 +: 4] = 4'd8;
        // ts_id 跳变：奇数 ts 带 br，其后 ts_id 不连续（真实跳转标记）
        for (int k = 0; k < 16; k++) t.ts_id[k*6 +: 6] = (k + (k >> 1)) & 6'h3F;
        tpl_put_ts8(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0),
                    '0, '0, '0, '0, '0, '0, '0);
        for (int k = 1; k < 16; k++)
            tpl_put_ts8(t, k,
                tpl_iv(1'b1, 3'd7, 1'b0, 1'b0, 3'd0),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd1),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd2),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd3),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd4),
                tpl_iv(1'b0, 3'd7, (k[0] ? 1'b1 : 1'b0), 1'b0, 3'd5),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd6),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd7));
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h00;
        t.cw = '0;
        tpl_hp_iv = t;
    endfunction

    // ---- T8：混合（16 ts，每 ts 8 burst：4 i/v + 4 c_task 交替，中等压力） ----
    function automatic thread_tpl_t tpl_hp_mix();
        thread_tpl_t t;
        automatic logic [19:0] tg;
        t = '0;
        t.ts_cnt = 5'd16;
        t.pri = 3'd2;
        t.ts_bs[3:0] = 4'd1;
        for (int k = 1; k < 16; k++) t.ts_bs[k*4 +: 4] = 4'd8;
        for (int k = 0; k < 16; k++) t.ts_id[k*6 +: 6] = k[5:0];
        tpl_put_ts8(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0),
                    '0, '0, '0, '0, '0, '0, '0);
        for (int k = 1; k < 16; k++)
            tpl_put_ts8(t, k,
                tpl_iv(1'b1, 3'd7, 1'b0, 1'b0, 3'd0),
                tpl_c(1'b0, 3'd0, 8'd4),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd1),
                tpl_c(1'b0, 3'd1, 8'd4),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd2),
                tpl_c(1'b0, 3'd2, 8'd4),
                tpl_iv(1'b0, 3'd7, 1'b0, 1'b0, 3'd3),
                tpl_c(1'b0, 3'd3, 8'd4));
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h0F; // dma0..3 有效
        t.cw = '0;
        tg = $urandom % 4; // 配对 1（dma0/1）
        t.cw[47:0] = tpl_cw_entry(tg, 1'b0);
        t.cw[95:48] = tpl_cw_entry(tg, 1'b1);
        tg = $urandom % 4; // 配对 2（dma2/3）
        t.cw[143:96] = tpl_cw_entry(tg, 1'b0);
        t.cw[191:144] = tpl_cw_entry(tg, 1'b1);
        tpl_hp_mix = t;
    endfunction

    // ---- T9：空 c_task 线程（4 ts。dma_c=0x00 → 全部 c_task 无效：
    // ts1 = iv+空 c（dneed=1，仅 iv 回 done）；ts2 = 单空 c（dneed=0，
    // 无任何 done 事件，验证 THM 每拍兜底推进、空 c 不入缓存/不占 DSE 机会）） ----
    function automatic thread_tpl_t tpl_empty_c();
        thread_tpl_t t;
        t = '0;
        t.ts_cnt = 5'd4;
        t.pri = 3'd2;
        t.ts_bs[3:0] = 4'd1;
        t.ts_bs[7:4] = 4'd2;
        t.ts_bs[11:8] = 4'd1;
        t.ts_bs[15:12] = 4'd1;
        t.ts_id[5:0] = 6'd0;
        t.ts_id[11:6] = 6'd1;
        t.ts_id[17:12] = 6'd2;
        t.ts_id[23:18] = 6'd3;
        tpl_put_ts(t, 0, tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0), '0, '0, '0);
        tpl_put_ts(t, 1, tpl_iv(1'b1, 3'd2, 1'b0, 1'b0, 3'd1),
                        tpl_c(1'b0, 3'd6, 8'd4), '0, '0); // 空 c（dma6 被 dma_c 屏蔽）
        tpl_put_ts(t, 2, tpl_c(1'b1, 3'd6, 8'd4), '0, '0, '0); // 单空 c（dneed=0）
        tpl_put_ts(t, 3, tpl_iv(1'b1, 3'd1, 1'b1, 1'b0, 3'd3), '0, '0, '0);
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h00; // 全部 c_task 无效（cw 不使用）
        t.cw = '0;
        tpl_empty_c = t;
    endfunction

    // ==================== 来源相关模板库（全 7 条 KO 输入流） ====================
    // 不同的 KO 来源伴随不同的 c_task 数量：按实测每线程 c_task 平均数生成——
    // fgOTN EXT/INS 按 (stream,pos) 粒度（41~52 / 10~17），其余来源单值：
    // APS_EXT=3、APS_INS=3、ALM=4、UART_EXT=20、UART_INS=15。
    // 生成规则：16 ts（ts0 固定 1 条 i_task，ts_id 可跳变）；ts1..15 的 c_task
    // 按 U 形权重 [6,4,2,1,1,1,1,1,1,1,1,1,2,4,6] 分配（靠前/靠后的 ts 多、中间
    // 的 ts 少，单 ts ≤7 条 c）；每 ts 的 i_task 数随机 1~8（受 iv+c ≤ 8 上限）；
    // 跳转：每来源 4 个变体（C ±{2,1,1,2}，池均值 = 实测值）中变体 0 不跳转，
    // 其余 3 个按 20% 跳变率（15 个 ts 边界随机取 3 个，ts_id 跳 1~2）。
    // tag 按 T6 式 3 对 loc/free（同 tag）+ dma6 单条，模板生成时随机。

    // (stream,pos) → 每线程 c_task 实测平均数（无数据的来源返回 -1 → 通用池）
    function automatic int src_ct_avg(input int st, input int pos);
        if (st == 0) // fgOTN EXT（OH_EXT）
            case (pos)
                0: return 42; 1: return 41; 2: return 52; 3: return 41;
                4: return 44; 5: return 41; 6: return 45; 7: return 41;
            endcase
        if (st == 1) // fgOTN INS（OH_INS）
            case (pos)
                0: return 11; 1: return 10; 2: return 17; 3: return 14;
                4: return 14; 5: return 10; 6: return 13; 7: return 10;
            endcase
        if (st == 2) return 3; // X2X APS_EXT
        if (st == 3) return 3; // X2X APS_INS
        if (st == 4) return 4; // X2X ALM
        if (st == 5) return 20; // UART_EXT
        if (st == 6) return 15; // UART_INS
        return -1;
    endfunction

    // 生成一个 16 ts 来源模板：c_task 总数 = c_cnt（U 形分布）；每 ts i_task
    // 随机 1~8（受 iv+c ≤ 8 上限）；jump_en=1 时 15 个 ts 边界随机取 3 个跳变
    // （ts_id 跳 1~2，触发 THM 4+t 跳转等待）
    function automatic thread_tpl_t tpl_gen(input int c_cnt, input bit jump_en);
        thread_tpl_t t;
        automatic int w [15];
        automatic int ord [15];
        automatic int asg [15];
        automatic logic jb [15]; // 跳变边界（jb[k-1]=ts k-1→k 跳变）
        automatic int tot_w = 0;
        automatic int sum = 0;
        automatic int rem;
        automatic logic [19:0] tg;
        w = '{6,4,2,1,1,1,1,1,1,1,1,1,2,4,6};
        ord = '{0,14,1,13,2,12,3,11,4,10,5,9,6,8,7}; // 权重降序（补余按形状优先）
        for (int j = 0; j < 15; j++) tot_w += w[j];
        for (int j = 0; j < 15; j++) begin
            asg[j] = (c_cnt * w[j]) / tot_w;
            if (asg[j] > 7) asg[j] = 7;
        end
        for (int j = 0; j < 15; j++) sum += asg[j];
        rem = c_cnt - sum;
        while (rem > 0) // 余数按权重降序补 1（满 7 跳过顺延；c_cnt ≤ 54 < 105 上限）
            for (int o = 0; o < 15 && rem > 0; o++)
                if (asg[ord[o]] < 7) begin
                    asg[ord[o]]++;
                    rem--;
                end
        // 跳变边界：3/15 = 20%（随机选不重复边界）
        for (int j = 0; j < 15; j++) jb[j] = 1'b0;
        if (jump_en)
            for (int s = 0; s < 3; s++) begin
                automatic int b = $urandom % 15;
                while (jb[b]) b = $urandom % 15;
                jb[b] = 1'b1;
            end
        t = '0;
        t.ts_cnt = 5'd16;
        t.pri = 3'd1 + ($urandom % 3); // 1..3
        t.ts_bs[3:0] = 4'd1; // ts0：固定 1 条 i_task
        t.ts_id[0 +: 6] = 6'd0;
        t.burst_seq[0 +: BURST_W] = tpl_iv(1'b1, 3'd1, 1'b0, 1'b0, 3'd0);
        for (int k = 1; k < 16; k++) begin
            automatic int n = asg[k-1];
            automatic int iv_n = 1 + ($urandom % 8); // 每 ts i_task 随机 1..8
            automatic int gap;
            if (iv_n > 8 - n) iv_n = 8 - n; // 结构上限：iv + c ≤ 8
            t.ts_bs[k*4 +: 4] = iv_n + n;
            for (int m = 0; m < iv_n; m++)
                t.burst_seq[(k*8 + m)*BURST_W +: BURST_W] =
                    tpl_iv((m == 0) ? 1'b1 : 1'b0,
                           (iv_n + n > 7) ? 3'd7 : 3'(iv_n + n),
                           1'b0, 1'b0, (k + m) % 8);
            for (int m = 0; m < n; m++)
                t.burst_seq[(k*8 + iv_n + m)*BURST_W +: BURST_W] =
                    tpl_c(1'b0, m[2:0], 8'd4);
            gap = jb[k-1] ? (1 + ($urandom % 2)) : 0; // 跳变：ts_id 跳 1~2
            t.ts_id[k*6 +: 6] = t.ts_id[(k-1)*6 +: 6] + gap[5:0] + 6'd1;
        end
        t.vtsk_c = 8'hFF;
        t.dma_c = 8'h7F; // dma0..6 有效（单 ts 最多 7 条 c）
        for (int pr = 0; pr < 3; pr++) begin // cw：3 对 loc/free（同 tag）+ dma6 单条
            tg = $urandom % 4;
            t.cw[(pr*2)*48 +: 48] = tpl_cw_entry(tg, 1'b0);
            t.cw[(pr*2+1)*48 +: 48] = tpl_cw_entry(tg, 1'b1);
        end
        tg = $urandom % 4;
        t.cw[6*48 +: 48] = tpl_cw_entry(tg, 1'b0);
        tpl_gen = t;
    endfunction

    // 来源模板：按 (stream,pos) 实测均值 ±{2,1,1,2} 随机 4 选 1（池均值 = 实测值）；
    // 变体 0（C-2）不跳转，其余按 20% 跳变率（3/15 边界）
    function automatic thread_tpl_t tpl_src(input int st, input int pos);
        automatic int c0 = src_ct_avg(st, pos);
        automatic int k = $urandom % 4;
        automatic int dk = (k == 0) ? -2 : (k == 1) ? -1 : (k == 2) ? 1 : 2;
        automatic int c = c0 + dk;
        if (c < 0) c = 0;
        tpl_src = tpl_gen(c, k != 0);
    endfunction

    // 按索引取模板（越界回退到 T0）
    function automatic thread_tpl_t tpl_get(input int idx);
        case (idx)
            0: tpl_get = tpl_short_iv();
            1: tpl_get = tpl_mix_1pair();
            2: tpl_get = tpl_long_branch();
            3: tpl_get = tpl_dma_dense();
            4: tpl_get = tpl_locked();
            5: tpl_get = tpl_double_lock();
            6: tpl_get = tpl_hp_c();
            7: tpl_get = tpl_hp_iv();
            8: tpl_get = tpl_hp_mix();
            9: tpl_get = tpl_empty_c();
            default: tpl_get = tpl_short_iv();
        endcase
    endfunction

endpackage
