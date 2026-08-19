// ============================================================================
// POE dma_ctrl 行为模型：c_task（loc/free）+ C 窗资源管理 + SMC/RBA 模型
// 结构（对应《dma_ctrl设计方案.md》）：
// - 接收 burst_sch 二级发射的 c_task burst（每拍 ≤1，含 ≤2 个 c_task）；
//   按 c0/c1 + CSR.dma_c 判有效任务，按 dma_id 查 CSR.cw 得 op_type（loc/free）
//   与 smc 地址（tag）；同拍两个 free 同地址只执行端口小者。
// - loc（0）：3 拍分 3 组扫描 C 窗（tag 匹配 && o=1）：
//   命中 → 存入指令预存资源（16 深），不占资源；
//   未命中 → 申请 C 窗资源（FIFO 出队，单线程上限 4）、写 C 窗条目
//   （tag/c_line/d/o/r/cnt/ind）、更新 CSR.cw（o=1、c_line_num、start_ts、occ_ts）、
//   经 RBA 读 SMC 数据回填 c_line 并置 r=1。
// - free（1）：RBA 把 C 窗 c_line 写回 SMC[tag] → C 窗条目 o=0、资源号入 FIFO、
//   th_res_n_r-1、cw.o=0；查指令预存同 tag → 转交（cw.c_line_num=预存 cw_ind、o=1），
//   清预存项。
// - 资源生命周期 = loc 申请（占据）→ free / 线程结束兜底释放；dma_done 仅表示
//   burst 执行完成（THM cur_ts 推进用），不归还资源。
// - pre 插队 burst：不占资源、不执行、不回 done（占位，预读语义待细化）。
// ============================================================================
module poe_dma_ctrl #(
    parameter int MAX_THREADS = 64,
    parameter int TS_ID_W = 6,
    parameter int C_WND_NUM = 256, // C 窗资源数（资源号 0..255）
    parameter int PRE_MEM_DEPTH = 16, // 指令预存深度
    parameter int SMC_DEPTH = 256 // SMC 模型深度（tag 低 8bit 索引）
) (
    input logic clk,
    input logic rst_n,
    // ---- burst_sch 二级发射（c_task burst，每拍 ≤1） ----
    input logic emit_dma_vld,
    input logic [5:0] emit_dma_tid,
    input logic [31:0] emit_dma_burst,
    input logic emit_dma_pre,
    output logic dma_ack,
    // ---- CSR / 线程状态（THM） ----
    input logic [MAX_THREADS*8-1:0] csr_dma_c,
    input logic [MAX_THREADS*384-1:0] csr_cw,
    input logic [MAX_THREADS*TS_ID_W-1:0] thread_curts,
    // ---- CSR.cw 条目更新（→ THM） ----
    output logic cw_upd_vld,
    output logic [5:0] cw_upd_tid,
    output logic [2:0] cw_upd_ind,
    output logic [47:0] cw_upd_data,
    // ---- 线程结束（兜底归还残留资源） ----
    input logic th_rel_vld,
    input logic [5:0] th_rel_tid,
    // ---- 资源池状态（burst_sch 发射条件） ----
    output logic [9:0] cw_fifo_cnt,
    output logic [MAX_THREADS*2-1:0] th_res_n,
    // ---- 完成（THM cur_ts 推进） ----
    output logic dma_done_vld,
    output logic [5:0] dma_done_tid,
    // ---- pre_read 预读入口（burst_sch 最高优先级发射；占位：接收即吸收，不执行/不占资源/不回 done） ----
    input logic [3:0] pre_op_vld,
    input logic [23:0] pre_op_tid,
    input logic [79:0] pre_op_addr,
    input logic [3:0] pre_op_type,
    output logic pre_op_ack
);

    import poe_types_pkg::*;

    typedef enum logic [3:0] {
        S_IDLE, S_LOAD,
        S_SCAN0, S_SCAN1, S_SCAN2,
        S_HIT, S_MISS,
        S_RBA_RD, S_RBA_RD_DONE,
        S_FREE_RBA, S_FREE_REL,
        S_TRANSFER, S_NEXT, S_DONE
    } state_t;

    // ---- C 窗 / 资源池 ----
    c_wnd_entry_t c_wnd [C_WND_NUM];
    logic [7:0] f_mem [C_WND_NUM];
    logic [7:0] f_head, f_tail;
    logic [9:0] f_cnt;
    // ---- 指令预存资源（36bit：{v, op_addr, op_type, th_id, cw_ind}） ----
    logic [35:0] pre_mem [PRE_MEM_DEPTH];
    // ---- 每线程已占用资源号（上限 4） ----
    logic [7:0] th_res [MAX_THREADS][4];
    logic [1:0] th_res_n_r [MAX_THREADS];
    // ---- SMC 模型（tag 低 8bit 索引，128bit 行） ----
    logic [127:0] smc_mem [SMC_DEPTH];

    state_t st;
    logic [5:0] cur_tid;
    logic [31:0] cur_burst;
    logic [2:0] cur_dma_id;
    logic [19:0] cur_tag;
    logic cur_op; // 0=loc 1=free
    logic cur_o; // 当前任务 cw 的 o（该线程是否已占据资源）
    logic [2:0] cur_tgt_ind; // free 释放目标 cw 条目索引（按 tag 匹配）
    logic [7:0] cur_occ;
    logic [7:0] cur_cn; // 当前 C 窗资源号
    logic hit_found;
    logic [7:0] hit_cn;
    logic hit_reg; // 3 拍扫描命中累积（任意一拍命中即命中）
    // task 解析结果（S_LOAD 锁存）
    logic t0_ok, t1_ok;
    logic [2:0] t1_dma_id;
    logic [19:0] t1_tag;
    logic t1_op;
    logic [7:0] t1_occ;
    logic [7:0] t1_cn;
    logic task_is0; // 当前处理 task0（否则 task1）
    logic [127:0] rba_rd_data;
    // 指令预存查询（free 转交用，组合）
    logic pre_found;
    logic [5:0] pre_thid;
    logic [7:0] pre_cn;
    // cw 更新请求（寄存，下一拍 THM 采样）
    logic cw_upd_vld_r;
    logic [5:0] cw_upd_tid_r;
    logic [2:0] cw_upd_ind_r;
    logic [47:0] cw_upd_data_r;
    // dma_done（寄存，S_DONE 拍置位）
    logic dma_done_vld_r;
    logic [5:0] dma_done_tid_r;
    // temp diag：资源收支计数
    logic [15:0] dbg_alloc, dbg_free, dbg_rel;

    assign dma_ack = (st == S_IDLE);
    assign cw_fifo_cnt = f_cnt;
    assign cw_upd_vld = cw_upd_vld_r;
    assign cw_upd_tid = cw_upd_tid_r;
    assign cw_upd_ind = cw_upd_ind_r;
    assign cw_upd_data = cw_upd_data_r;
    assign dma_done_vld = dma_done_vld_r;
    assign dma_done_tid = dma_done_tid_r;
    assign pre_op_ack = 1'b1; // 预读入口每拍可收（吸收占位，预读语义待细化）

    always_comb begin
        for (int i = 0; i < MAX_THREADS; i++)
            th_res_n[i*2 +: 2] = th_res_n_r[i];
    end

    // 当前任务对应的 CSR.cw 条目（组合）
    function automatic logic [47:0] cw_entry_of(logic [5:0] tid, logic [2:0] dma_id);
        cw_entry_of = csr_cw[tid*384 +: 384][dma_id*48 +: 48];
    endfunction

    // 组合：3 组 C 窗扫描（每组一拍，任一命中即命中）
    always_comb begin
        hit_found = 1'b0;
        hit_cn = '0;
        if (st == S_SCAN0 || st == S_SCAN1 || st == S_SCAN2) begin
            automatic int lo = (st == S_SCAN0) ? 0 :
                               (st == S_SCAN1) ? (C_WND_NUM / 3) : (2 * C_WND_NUM / 3);
            automatic int hi = (st == S_SCAN0) ? (C_WND_NUM / 3) :
                               (st == S_SCAN1) ? (2 * C_WND_NUM / 3) : C_WND_NUM;
            for (int i = lo; i < hi; i++)
                if (c_wnd[i].o && (c_wnd[i].tag == cur_tag)) begin
                    hit_found = 1'b1;
                    hit_cn = i[7:0];
                end
        end
    end

    // ---- 当拍资源池事件（合并 FIFO 指针/计数更新，避免同拍多事件覆盖） ----
    logic alloc_ev; // loc 未命中申请 1 个
    logic free_ev; // free 释放 1 个
    logic [2:0] rel_n; // 线程结束兜底释放 n 个（= 该线程 cw 中 o=1 条目数，上限 4）
    always_comb begin
        alloc_ev = (st == S_MISS) && !cur_o; // 复用已有资源时不申请
        // 转交命中时资源直接转移（不入 FIFO），不产生 free_ev
        free_ev = (st == S_FREE_REL) && cur_o && !pre_found;
        // 兜底释放数：线程结束该线程 cw 中 o=1 的条目数（cw 是资源占用的权威视图）
        rel_n = 3'd0;
        if (th_rel_vld)
            for (int k = 0; k < 8; k++)
                if (csr_cw[th_rel_tid*384 +: 384][k*48 +: 48][25])
                    rel_n = rel_n + 3'd1;
    end

    // 组合：查指令预存中与当前 free tag 相同的项（S_FREE_REL 拍有效）
    always_comb begin
        pre_found = 1'b0;
        pre_thid = '0;
        pre_cn = '0;
        if (st == S_FREE_REL) begin
            for (int k = 0; k < PRE_MEM_DEPTH; k++)
                if (pre_mem[k][35] && (pre_mem[k][34:15] == cur_tag)) begin
                    pre_found = 1'b1;
                    pre_thid = pre_mem[k][13:8];
                    pre_cn = pre_mem[k][7:0];
                    break;
                end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < C_WND_NUM; i++) begin
                c_wnd[i] <= '0;
                f_mem[i] <= i[7:0];
            end
            f_head <= '0;
            f_tail <= '0;
            f_cnt <= C_WND_NUM[9:0];
            for (int i = 0; i < PRE_MEM_DEPTH; i++) pre_mem[i] <= '0;
            for (int i = 0; i < MAX_THREADS; i++) begin
                for (int k = 0; k < 4; k++) th_res[i][k] <= '0;
                th_res_n_r[i] <= 2'd0;
            end
            for (int i = 0; i < SMC_DEPTH; i++) smc_mem[i] <= '0;
            st <= S_IDLE;
            cur_tid <= '0;
            cur_burst <= '0;
            cur_dma_id <= '0;
            cur_tag <= '0;
            cur_op <= 1'b0;
            cur_o <= 1'b0;
            cur_tgt_ind <= '0;
            cur_occ <= '0;
            cur_cn <= '0;
            hit_reg <= 1'b0;
            t0_ok <= 1'b0;
            t1_ok <= 1'b0;
            t1_dma_id <= '0;
            t1_tag <= '0;
            t1_op <= 1'b0;
            t1_occ <= '0;
            t1_cn <= '0;
            task_is0 <= 1'b1;
            rba_rd_data <= '0;
            cw_upd_vld_r <= 1'b0;
            cw_upd_tid_r <= '0;
            cw_upd_ind_r <= '0;
            cw_upd_data_r <= '0;
            dma_done_vld_r <= 1'b0;
            dma_done_tid_r <= '0;
            dbg_alloc <= '0;
            dbg_free <= '0;
            dbg_rel <= '0;
        end else begin
            cw_upd_vld_r <= 1'b0; // 单拍请求，默认清
            dma_done_vld_r <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (emit_dma_vld && !emit_dma_pre) begin
                        cur_tid <= emit_dma_tid;
                        cur_burst <= emit_dma_burst;
                        st <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    automatic burst_c_t b;
                    automatic logic [7:0] dc;
                    automatic logic [47:0] e0, e1;
                    automatic logic t0c, t1c;
                    b = cur_burst;
                    dc = csr_dma_c[cur_tid*8 +: 8];
                    e0 = cw_entry_of(cur_tid, b.dma_id0);
                    e1 = cw_entry_of(cur_tid, b.dma_id1);
                    t0c = b.c0 && dc[b.dma_id0];
                    t1c = b.vld_cu && b.c1 && dc[b.dma_id1];
                    // 同拍 free 去重：task0/task1 均 free 且 tag 相同 → 只执行 task0
                    if (t0c && t1c && e0[27] && e1[27] && (e0[47:28] == e1[47:28]))
                        t1c = 1'b0;
                    t0_ok <= t0c;
                    t1_ok <= t1c;
                    t1_dma_id <= b.dma_id1;
                    t1_tag <= e1[47:28];
                    t1_op <= e1[27];
                    t1_occ <= b.occ_ts1;
                    t1_cn <= 8'd0; // 实际值在 t1c 分支按 tag 查找后锁存
                    task_is0 <= 1'b1;
                    if (t0c) begin
                        automatic int tgt = b.dma_id0;
                        automatic logic [47:0] te = e0;
                        if (e0[27]) begin // free：释放目标按 tag 在 cw 中匹配（loc 条目）
                            // 优先找 tag 匹配且 o=1（占据资源）的条目；无则取第一个匹配（o=0，free 无效）
                            tgt = -1;
                            for (int k = 0; k < 8; k++)
                                if ((cw_entry_of(cur_tid, k[2:0])[47:28] == e0[47:28]) &&
                                    cw_entry_of(cur_tid, k[2:0])[25]) begin
                                    tgt = k;
                                    break;
                                end
                            if (tgt < 0)
                                for (int k = 0; k < 8; k++)
                                    if (cw_entry_of(cur_tid, k[2:0])[47:28] == e0[47:28]) begin
                                        tgt = k;
                                        break;
                                    end
                            te = cw_entry_of(cur_tid, tgt[2:0]);
                        end
                        cur_dma_id <= b.dma_id0;
                        cur_tag <= e0[47:28];
                        cur_op <= e0[27];
                        cur_tgt_ind <= tgt[2:0];
                        cur_o <= te[25];
                        cur_occ <= b.occ_ts0;
                        cur_cn <= te[24:17]; // loc 条目的 c_line_num
                        st <= e0[27] ? S_FREE_RBA : S_SCAN0;
                    end else if (t1c) begin
                        automatic int tgt = b.dma_id1;
                        automatic logic [47:0] te = e1;
                        if (e1[27]) begin
                            tgt = -1;
                            for (int k = 0; k < 8; k++)
                                if ((cw_entry_of(cur_tid, k[2:0])[47:28] == e1[47:28]) &&
                                    cw_entry_of(cur_tid, k[2:0])[25]) begin
                                    tgt = k;
                                    break;
                                end
                            if (tgt < 0)
                                for (int k = 0; k < 8; k++)
                                    if (cw_entry_of(cur_tid, k[2:0])[47:28] == e1[47:28]) begin
                                        tgt = k;
                                        break;
                                    end
                            te = cw_entry_of(cur_tid, tgt[2:0]);
                        end
                        cur_dma_id <= b.dma_id1;
                        cur_tag <= e1[47:28];
                        cur_op <= e1[27];
                        cur_tgt_ind <= tgt[2:0];
                        cur_o <= te[25];
                        cur_occ <= b.occ_ts1;
                        cur_cn <= te[24:17];
                        t1_cn <= te[24:17];
                        st <= e1[27] ? S_FREE_RBA : S_SCAN0;
                    end else begin
                        st <= S_DONE; // 无有效任务也回 done（THM cur_ts 依赖）
                    end
                end
                S_SCAN0: begin
                    hit_reg <= hit_found;
                    st <= S_SCAN1;
                end
                S_SCAN1: begin
                    if (hit_found) hit_reg <= 1'b1;
                    st <= S_SCAN2;
                end
                S_SCAN2: begin
                    if (hit_found) hit_reg <= 1'b1;
                    st <= (hit_reg || hit_found) ? S_HIT : S_MISS;
                end
                S_HIT: begin
                    // loc 命中：存指令预存资源（只写第一个空槽；满则丢弃，不占资源）
                    for (int k = 0; k < PRE_MEM_DEPTH; k++)
                        if (!pre_mem[k][35]) begin
                            pre_mem[k] <= {1'b1, cur_tag, cur_op, cur_tid, hit_cn};
                            break;
                        end
                    st <= S_NEXT;
                end
                S_MISS: begin
                    // loc 未命中：申请资源 + 写 C 窗 + 更新 cw；RBA 读下一拍发起
                    automatic c_wnd_entry_t we;
                    automatic cw_entry_t ce;
                    automatic logic [7:0] cn;
                    // 已占据（cw.o=1，重复 loc 同 tag）：复用现有资源，不重复申请
                    cn = cur_o ? cur_cn : f_mem[f_head];
                    cur_cn <= cn;
                    we.tag = cur_tag;
                    we.c_line = '0;
                    we.d = 1'b0;
                    we.o = 1'b1;
                    we.r = 1'b0;
                    we.cnt = 9'd0;
                    we.ind = cn;
                    c_wnd[cn] <= we;
                    ce.tag = cur_tag;
                    ce.op_type = cur_op;
                    ce.r = 1'b0;
                    ce.o = 1'b1;
                    ce.c_line_num = cn;
                    ce.start_ts = thread_curts[cur_tid*TS_ID_W +: TS_ID_W];
                    ce.occ_ts = cur_occ;
                    ce.rsv = 1'b0;
                    cw_upd_vld_r <= 1'b1;
                    cw_upd_tid_r <= cur_tid;
                    cw_upd_ind_r <= cur_dma_id;
                    cw_upd_data_r <= ce;
                    if (!cur_o) begin
                        th_res[cur_tid][th_res_n_r[cur_tid]] <= cn;
                        th_res_n_r[cur_tid] <= th_res_n_r[cur_tid] + 1'b1;
                    end
                    st <= S_RBA_RD;
                end
                S_RBA_RD: begin
                    rba_rd_data <= smc_mem[cur_tag[7:0]];
                    st <= S_RBA_RD_DONE;
                end
                S_RBA_RD_DONE: begin
                    // 数据回填 C 窗 c_line + r=1；更新 cw.r=1
                    c_wnd[cur_cn].c_line <= rba_rd_data;
                    c_wnd[cur_cn].r <= 1'b1;
                    cw_upd_vld_r <= 1'b1;
                    cw_upd_tid_r <= cur_tid;
                    cw_upd_ind_r <= cur_dma_id;
                    cw_upd_data_r <= {cw_entry_of(cur_tid, cur_dma_id)[47:27],
                                      1'b1, // r=1
                                      cw_entry_of(cur_tid, cur_dma_id)[25:0]};
                    st <= S_NEXT;
                end
                S_FREE_RBA: begin
                    // free：RBA 写（c_line → SMC[tag]），1 拍完成
                    if (cur_o)
                        smc_mem[cur_tag[7:0]] <= c_wnd[cur_cn].c_line;
                    st <= S_FREE_REL;
                end
                S_FREE_REL: begin
                    // 释放（仅该线程已占据资源时执行）；指令预存转交走 S_TRANSFER
                    automatic logic [47:0] ce;
                    ce = cw_entry_of(cur_tid, cur_tgt_ind);
                    if (cur_o) begin
                        if (!pre_found) begin
                            // 无转交：正常释放（C 窗 o=0、资源入 FIFO、占用-1）
                            c_wnd[cur_cn].o <= 1'b0;
                            f_mem[f_tail] <= cur_cn;
                            th_res_n_r[cur_tid] <= th_res_n_r[cur_tid] - 1'b1;
                            st <= S_NEXT;
                        end else if (pre_thid == cur_tid) begin
                            // 同线程转交：资源仍归自己，占用计数净 0
                            st <= S_TRANSFER;
                        end else begin
                            // 跨线程转交：资源从当前线程转到预存线程（C 窗 o 保持 1）
                            th_res_n_r[cur_tid] <= th_res_n_r[cur_tid] - 1'b1;
                            th_res_n_r[pre_thid] <= th_res_n_r[pre_thid] + 1'b1;
                            st <= S_TRANSFER;
                        end
                        ce[25] = 1'b0; // free 线程 o=0
                        cw_upd_vld_r <= 1'b1;
                        cw_upd_tid_r <= cur_tid;
                        cw_upd_ind_r <= cur_tgt_ind;
                        cw_upd_data_r <= ce;
                    end else begin
                        st <= S_NEXT;
                    end
                end
                S_TRANSFER: begin
                    // 预存 loc 接管资源：预存线程 cw 中 tag==cur_tag 的条目置 o=1、c_line_num=pre_cn
                    automatic int idx = -1;
                    automatic logic [47:0] ce;
                    for (int k = 0; k < 8; k++)
                        if (cw_entry_of(pre_thid, k[2:0])[47:28] == cur_tag) idx = k;
                    if (idx >= 0) begin
                        ce = cw_entry_of(pre_thid, idx[2:0]);
                        ce[24:17] = pre_cn;
                        ce[25] = 1'b1; // o=1
                        cw_upd_vld_r <= 1'b1;
                        cw_upd_tid_r <= pre_thid;
                        cw_upd_ind_r <= idx[2:0];
                        cw_upd_data_r <= ce;
                    end
                    // 转交资源登记进预存线程（兜底释放时按 th_res 数组找资源号）
                    th_res[pre_thid][th_res_n_r[pre_thid]] <= pre_cn;
                    // 清预存项
                    for (int k = 0; k < PRE_MEM_DEPTH; k++)
                        if (pre_mem[k][35] && (pre_mem[k][34:15] == cur_tag)) begin
                            pre_mem[k][35] <= 1'b0;
                            break;
                        end
                    st <= S_NEXT;
                end
                S_NEXT: begin
                    if (task_is0 && t1_ok) begin
                        task_is0 <= 1'b0;
                        cur_dma_id <= t1_dma_id;
                        cur_tag <= t1_tag;
                        cur_op <= t1_op;
                        cur_occ <= t1_occ;
                        cur_cn <= t1_cn;
                        st <= t1_op ? S_FREE_RBA : S_SCAN0;
                    end else begin
                        st <= S_DONE;
                    end
                end
                S_DONE: begin
                    dma_done_vld_r <= 1'b1;
                    dma_done_tid_r <= cur_tid;
                    st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
            // ---- 资源池 FIFO 统一更新（合并 alloc/free/线程兜底，避免同拍覆盖） ----
            if (alloc_ev) dbg_alloc <= dbg_alloc + 1'b1;
            if (free_ev) dbg_free <= dbg_free + 1'b1;
            if (rel_n != 3'd0) dbg_rel <= dbg_rel + rel_n;
            f_head <= f_head + alloc_ev;
            f_tail <= f_tail + free_ev + {5'd0, rel_n};
            f_cnt <= f_cnt - alloc_ev + free_ev + {7'd0, rel_n};
            // ---- 线程结束兜底：扫描该线程 cw 中 o=1 的条目释放对应资源 ----
            if (rel_n != 3'd0) begin
                automatic int m = 0;
                for (int k = 0; k < 8; k++)
                    if (csr_cw[th_rel_tid*384 +: 384][k*48 +: 48][25]) begin
                        automatic logic [7:0] cn =
                            csr_cw[th_rel_tid*384 +: 384][k*48 +: 48][24:17];
                        c_wnd[cn].o <= 1'b0;
                        f_mem[f_tail + free_ev + m[2:0]] <= cn;
                        m++;
                    end
                th_res_n_r[th_rel_tid] <= 2'd0;
            end
        end
    end
endmodule
