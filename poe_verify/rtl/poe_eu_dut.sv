// ============================================================================
// EU DUT 边界壳 —— **接真实 EU RTL 时的唯一替换点**
//
// 替换清单（只动本文件）：
//   1) 删掉下面的 `sa_core u_eu (...)`，改为例化真实 EU RTL
//   2) 按本文件的端口逐条对齐（位宽由 RF_W/TID_W 参数给定）
//   3) 其余文件（线程池/存储/CSR/RF/检查器/TB）全都不动
//
// 本层与 RM 壳（poe_eu_rm.sv）**完全同构**，只换内部实现：
//   ① task 握手 → EU 波前；
//   ② POE CSR ↔ EU 的 CSR 映射（本版是"RISC-V CSR ↔ POE CSR"的自定义映射，
//      真实 EU 到位后改成它的真实 CSR 口）：
//        mstatus[15:0] ↔ POE 0x2  CCR              （读写）
//        mcause[7:0]   → POE 0xa  TH_STAT          （写）
//        mepc[7:0]     → POE 0xf  CUR_TS           （写；将来跳转落点）
//        mtvec[31:0]   → POE 0x16 MUX_PTR 低 32 位 （写；将来 mux 指针）
//        mcycle        ← POE 0x5  SYS_TS           （只读）
//      写侧只写"被 EU 改过的槽"，每拍最多一笔；CCR 不再由平台特判，走通用 POE CSR 写口。
//   ③ 线程最后一条 task 完成后的下一拍，**EU 自己写 TH_STAT=DONE**
//      （占位：真实设计里这条由微指令写，对平台呈现的接口形状不变）。
//
// 今天的实情（写在文档里，别误解）：
//   真实 EU RTL 还没接，这里**暂时例化同一份 sa-studio 参考模型**，
//   所以今天的 DUT 与 RM 相同 ⇒ 比对通过只是**自洽**，不是验证。
// ============================================================================
import poe_pkg::*;

module poe_eu_dut #(
    parameter int WIN_W = 512,    // 送/收 EU 的操作数窗口位宽（64B）
    parameter int TID_W = 3       // 线程号位宽
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             task_vld,        // 一条 task（burst）有效
    input  logic [TID_W-1:0] task_tid,        // 该 task 属于哪个线程
    input  logic [3:0]       task_sub_pc,     // 微指令行号
    input  logic             task_last,       // 本 task 是该线程的最后一条
    output logic             task_rdy,        // 能否收
    input  logic [WIN_W-1:0] win_in,          // 64B 操作数窗口（MUX 组好）
    output logic [WIN_W-1:0] win_out,         // 处理后的 64B 窗口
    output logic             win_we,          // 结果有效
    input  logic [CSRB*8-1:0] csr_snap,       // 该线程 POE CSR 全表快照（0x00..0x59）
    output logic             csr_we,          // EU 发起的 POE CSR 写
    output logic [TID_W-1:0] csr_wtid,        // 写哪个线程
    output logic [6:0]       csr_waddr,       // POE CSR 地址（字节偏移）
    output logic [2:0]       csr_ww,          // 写位宽码
    output logic [383:0]     csr_wdata,       // 写数据（低位对齐）
    output logic [3:0]       err_out,         // 按线程错误标志
    output logic             done,            // 结果有效
    output logic [TID_W-1:0] done_tid,        // 结果属于哪个线程
    input  logic             imem_we,         // 微指令 bank 预载
    input  logic [0:0]       imem_saddr,      // 0=s0 1=s1
    input  logic [3:0]       imem_waddr,      // 行号
    input  logic [63:0]      imem_wdata       // 一行内容
);
    logic             busy;                   // 单任务未完成
    logic             in_valid;               // 收下一条 task
    logic [7:0]       in_tid;
    logic [3:0]       in_pc;
    logic [WIN_W-1:0] out_win;                // sa_core 结果（窗口那一半）
    logic [1023:0]    in_regs_w;              // sa_core 的 128B 入参（窗口放高半区）
    logic [1023:0]    out_regs;               // sa_core 结果快照
    logic             out_valid;
    logic [7:0]       out_tid;
    logic [3:0]       out_pc;
    logic [127:0]     rmw_in_w, rmw_out_w;    // RISC-V CSR 读改写束
    logic [127:0]     rmw_in_q;               // 该 task 收下时读到的 CSR 初值（判"改没改"用它）
    logic [63:0]      ro_regs_w;              // RISC-V 只读束
    logic             last_v;                 // 已收下"最后一条 task"
    logic [TID_W-1:0] last_tid_q;             // 它的线程号
    logic             last_done;              // 上一拍完成的正是它

    assign task_rdy = ~busy;
    assign in_valid = task_vld & ~busy;
    assign in_tid   = {{(8-TID_W){1'b0}}, task_tid};   // 补零到 sa_core 的 8bit tid
    assign in_pc    = task_sub_pc;

    assign win_out  = out_win;
    assign win_we   = out_valid;
    // 示例模型是 128B 口：64B 窗口放高半区（= x0..x15），低半区补 0；
    // 窗口最高的 32bit 对应 x0，按平台约定硬连零。
    always_comb begin
        in_regs_w           = '0;
        in_regs_w[1023:512] = win_in;
        in_regs_w[1023:992] = 32'd0;
    end
    assign out_win = out_regs[1023:512];
    assign done     = out_valid;
    assign done_tid = out_tid[TID_W-1:0];
    assign csr_wtid = last_done ? last_tid_q : out_tid[TID_W-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        busy <= 1'b0;
        else if (in_valid) busy <= 1'b1;
        else if (out_valid) busy <= 1'b0;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)         rmw_in_q <= '0;
        else if (in_valid)  rmw_in_q <= rmw_in_w;   // 随 task 一起收下
    end

    // ---- POE CSR → RISC-V CSR（读侧映射）----
    always_comb begin
        rmw_in_w         = '0;
        rmw_in_w[111:96] = csr_snap[8*int'(A_CCR) +: 16];         // mstatus[15:0] = POE 0x2 CCR
    end
    assign ro_regs_w = {csr_snap[8*int'(A_SYS_TS) +: 32], 32'd0}; // mcycle = POE 0x5 SYS_TS

    // ---- RISC-V CSR → POE CSR（写侧映射）：out_valid 拍，写"被 EU 改过"的槽 ----
    always_comb begin
        csr_we    = 1'b0;
        csr_waddr = A_CCR;
        csr_ww    = W16;
        csr_wdata = '0;
        if (last_done) begin                                  // 线程结束：EU 自己写 TH_STAT=DONE
            csr_we    = 1'b1;
            csr_waddr = A_TH_STAT;
            csr_ww    = W8;
            csr_wdata = {376'd0, TH_DONE};
        end else if (out_valid) begin
            if (rmw_out_w[111:96] !== rmw_in_q[111:96]) begin // mstatus → CCR
                csr_we    = 1'b1;
                csr_waddr = A_CCR;
                csr_ww    = W16;
                csr_wdata = {368'd0, rmw_out_w[111:96]};
            end else if (rmw_out_w[31:0] !== rmw_in_q[31:0]) begin // mcause → TH_STAT
                csr_we    = 1'b1;
                csr_waddr = A_TH_STAT;
                csr_ww    = W8;
                csr_wdata = {376'd0, rmw_out_w[7:0]};
            end else if (rmw_out_w[63:32] !== rmw_in_q[63:32]) begin // mepc → CUR_TS
                csr_we    = 1'b1;
                csr_waddr = A_CUR_TS;
                csr_ww    = W8;
                csr_wdata = {376'd0, rmw_out_w[39:32]};
            end else if (rmw_out_w[95:64] !== rmw_in_q[95:64]) begin // mtvec → MUX_PTR 低 32 位
                csr_we    = 1'b1;
                csr_waddr = A_MUX_PTR;
                csr_ww    = W32;
                csr_wdata = {352'd0, rmw_out_w[95:64]};
            end
        end
    end

    // ---- 记住"最后一条 task"；它完成后的下一拍发那笔 TH_STAT 写 ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_v <= 1'b0; last_tid_q <= '0; last_done <= 1'b0;
        end else begin
            if (in_valid && task_last) begin
                last_v     <= 1'b1;
                last_tid_q <= task_tid;
            end
            if (last_done) last_v <= 1'b0;
            last_done <= out_valid && last_v && (out_tid[TID_W-1:0] == last_tid_q);
        end
    end

    // ---- ↓↓↓ 替换点：真实 EU RTL 放在这里 ↓↓↓ ----
    sa_core u_eu (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (1'b1),
        .in_regs    (in_regs_w),
        .out_regs   (out_regs),
        .in_valid   (in_valid),
        .out_valid  (out_valid),
        .in_tid     (in_tid),
        .out_tid    (out_tid),
        .in_pc      (in_pc),
        .out_pc     (out_pc),
        .rmw_in     (rmw_in_w),
        .rmw_out    (rmw_out_w),
        .ro_regs    (ro_regs_w),
        .wo_out     (),
        .wo_fwe     (),
        .err_out    (err_out),
        .imem_we    (imem_we),
        .imem_saddr (imem_saddr),
        .imem_waddr (imem_waddr),
        .imem_wdata (imem_wdata)
    );
endmodule
