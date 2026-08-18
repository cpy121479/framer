// POE dma_ctrl 行为模型（c_task 执行 + C 窗资源管理）：
// - C 窗 = 64（线程）× 8 × 21B 缓存（资源条目 168bit）；资源池由 256 深 FIFO 管理
//   （复位入队资源号 0..255）
// - 收到 c_task burst（emit_dma_vld）时：按 burst 的 c0/c1 判任务有效，查 CSR.dma_c
//   确认生效（bit=1），需执行任务数 N 个资源从 FIFO 出队，登记到该线程（单线程上限 4）
// - 资源归还：c_task 执行完（dma_done）即归还本次申请的 N 个资源（资源池复用）；
//   线程结束（THM th_rel_vld+tid）时兜底清理该线程残留资源
// - pre_read 插队 burst（emit_dma_pre=1）暂不占资源、不回 dma_done（占位，释放时机待定）
// - 占位：真实 dma_ctrl 按 cw[dma_id] 确认 op_type(loc/free) 与 tag（smc 地址），
//   loc 3 拍查 C 窗/申请资源/更新 CSR.cw/RBA 读；free 同拍去重、RBA 写 c_line、
//   cw.o 置 0、查指令预存资源转交；occ_ts 指示占据 ts 数
module poe_dma_ctrl_stub #(
    parameter int MAX_THREADS = 64,
    parameter int C_WND_FIFO_DEPTH = 256,
    parameter int LATENCY = 1
    ) (
    input logic clk,
    input logic rst_n,
    // ---- burst_sch 二级发射（c_task 操作指令，每拍 ≤4 路） ----
    input logic emit_dma_vld,
    input logic [5:0] emit_dma_tid,
    input logic [31:0] emit_dma_burst,
    input logic emit_dma_pre,
    output logic dma_ack,
    // ---- CSR / pre（dma_c 决定执行，cw 提供操作类型与 tag） ----
    input logic [MAX_THREADS*8-1:0] csr_dma_c,
    input logic [MAX_THREADS*384-1:0] csr_cw,
    input logic [7:0] pre_dma_c,
    input logic [255:0] pre_cw,
    // ---- THM 线程释放通知（兜底归还该线程残留资源） ----
    input logic th_rel_vld,
    input logic [5:0] th_rel_tid,
    // ---- 资源池状态（burst_sch 发射条件用） ----
    output logic [9:0] cw_fifo_cnt,
    output logic [MAX_THREADS*2-1:0] th_res_n,
    // ---- 完成通知（回 THM 统计） ----
    output logic dma_done_vld,
    output logic [5:0] dma_done_tid
    );

    import poe_types_pkg::*;

    // ---- C 窗资源池：256 深 FIFO（存资源号 0..255） ----
    logic [7:0] f_mem [C_WND_FIFO_DEPTH];
    logic [7:0] f_head, f_tail;
    logic [9:0] f_cnt;
    // ---- 每线程已占用资源（上限 4；线程结束兜底归还） ----
    logic [7:0] th_res [MAX_THREADS][4];
    logic [1:0] th_res_n_r [MAX_THREADS];
    // ---- 本次 burst 申请的资源（dma_done 时归还） ----
    logic [7:0] alloc_res [2];
    logic [1:0] alloc_cnt_r;

    // 执行/完成（保持 LATENCY 后回 dma_done）
    logic busy;
    logic [5:0] cur_tid;
    logic [7:0] remain;
    logic done_vld_r;
    logic [5:0] done_tid_r;
    // 诊断计数（临时，用于仿真结束校验资源收支平衡：申请 == 归还）
    logic [15:0] dbg_alloc, dbg_free, dbg_done;

    assign dma_ack = !busy;
    assign dma_done_vld = done_vld_r;
    assign dma_done_tid = done_tid_r;

    // 本次需执行 c_task 数：c0/c1 有效且 dma_c 置位（pre 用 pre_dma_c；pre 不占资源）
    logic [1:0] alloc_n;
    always_comb begin
        burst_c_t b;
        logic [7:0] dc;
        alloc_n = 2'd0;
        if (emit_dma_vld && !emit_dma_pre) begin
            b = emit_dma_burst;
            dc = csr_dma_c[emit_dma_tid*8 +: 8];
            alloc_n = b.c0 & dc[b.dma_id0];
            if (b.vld_cu) alloc_n = alloc_n + (b.c1 & dc[b.dma_id1]);
        end
    end

    // 当拍完成归还数（dma_done 时归还本次申请）
    logic [1:0] done_free_n;
    assign done_free_n = done_vld_r ? alloc_cnt_r : 2'd0;

    // 当拍线程结束兜底归还数
    logic [1:0] rel_free_n;
    always_comb begin
        rel_free_n = 2'd0;
        if (th_rel_vld)
            rel_free_n = th_res_n_r[th_rel_tid];
    end

    // 资源池状态输出（burst_sch 用）
    always_comb begin
        for (int i = 0; i < MAX_THREADS; i++)
            th_res_n[i*2 +: 2] = th_res_n_r[i];
    end
    assign cw_fifo_cnt = f_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < C_WND_FIFO_DEPTH; i++)
                f_mem[i] <= i[7:0];
            f_head <= '0;
            f_tail <= '0;
            f_cnt <= C_WND_FIFO_DEPTH[9:0];
            for (int i = 0; i < MAX_THREADS; i++) begin
                for (int k = 0; k < 4; k++) th_res[i][k] <= '0;
                th_res_n_r[i] <= 2'd0;
            end
            alloc_res[0] <= '0;
            alloc_res[1] <= '0;
            alloc_cnt_r <= 2'd0;
            busy <= 1'b0;
            cur_tid <= '0;
            remain <= '0;
            done_vld_r <= 1'b0;
            done_tid_r <= '0;
            dbg_alloc <= '0;
            dbg_free <= '0;
            dbg_done <= '0;
        end else begin
            done_vld_r <= 1'b0;
            // ---- 申请：接收 c_task 时按需执行数出队资源并登记 ----
            if (emit_dma_vld && !busy && !emit_dma_pre) begin
                alloc_cnt_r <= alloc_n; // 每 burst 刷新（含 0），避免残留导致误归还
                if (alloc_n != 2'd0) begin
                    alloc_res[0] <= f_mem[f_head];
                    alloc_res[1] <= f_mem[f_head + 1];
                    for (int k = 0; k < 4; k++)
                        if (k < alloc_n)
                            th_res[emit_dma_tid][th_res_n_r[emit_dma_tid] + k] <= f_mem[f_head + k];
                    th_res_n_r[emit_dma_tid] <= th_res_n_r[emit_dma_tid] + alloc_n;
                    f_head <= f_head + alloc_n;
                    dbg_alloc <= dbg_alloc + alloc_n;
                end
            end
            // ---- 完成归还：dma_done 时把本次申请的资源入队 ----
            if (done_vld_r && (alloc_cnt_r != 2'd0)) begin
                for (int k = 0; k < 2; k++)
                    if (k < alloc_cnt_r)
                        f_mem[f_tail + k] <= alloc_res[k];
                th_res_n_r[cur_tid] <= th_res_n_r[cur_tid] - alloc_cnt_r;
                dbg_free <= dbg_free + alloc_cnt_r;
            end
            // ---- 线程结束兜底：归还该线程残留资源 ----
            if (th_rel_vld && (rel_free_n != 2'd0)) begin
                for (int k = 0; k < 4; k++)
                    if (k < rel_free_n)
                        f_mem[f_tail + done_free_n + k] <= th_res[th_rel_tid][k];
                th_res_n_r[th_rel_tid] <= 2'd0;
                dbg_free <= dbg_free + rel_free_n;
            end
            f_tail <= f_tail + done_free_n + rel_free_n;
            f_cnt <= f_cnt - alloc_n + done_free_n + rel_free_n;
            // ---- 执行/完成（pre 插队 burst 不占资源、不回 done） ----
            if (busy) begin
                if (remain == 1) begin
                    busy <= 1'b0;
                    done_vld_r <= 1'b1;
                    done_tid_r <= cur_tid;
                    dbg_done <= dbg_done + 1'b1;
                end else
                remain <= remain - 1'b1;
            end else if (emit_dma_vld && !emit_dma_pre) begin
                busy <= 1'b1;
                cur_tid <= emit_dma_tid;
                remain <= LATENCY;
            end
        end
    end
endmodule
