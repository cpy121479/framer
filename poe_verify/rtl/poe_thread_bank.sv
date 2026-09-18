// ============================================================================
// 线程上下文存储：每线程一份 CSR + RF（平台侧；DUT/RM 的 EU 接口不动）
//
// CSR = **字节寻址寄存器组**（地址是字节偏移，每个寄存器占它自己的那几个字节）：
//   0x0 16b ERR      0x2 16b CCR(EU 读写)   0x4 32b SYS_TS(系统时标)
//   0x8  8b TH_ID    0x9  8b TH_STAT        0xa  1b O_TSK_EN   0xb  8b O_LABEL
//   0xc 16b PC_INTER 0xe  8b CUR_TS         0xf  8b TSK_C      0x10 8b DMA_C
//   0x11 2b LK_SET   0x12 16b LK_TAG        0x14 64b MUX_PTR   0x1c 352b CW_CMD
//   总空间 0x00..0x47（72 字节）
//   访问方式：{addr[6:0], 位宽码[2:0], data[383:0]}；位宽码 0=8b 1=16b 2=32b 3=64b 4=352b
//   存储：0x00..0x1b 用字节数组；0x1c..0x47（CW 窗 = 8 项 × 44bit）单独用 352bit 寄存器，
//         因为预发射口按 44bit 表项写、不是字节对齐的。
//
// RF = 每线程 **256B（2048bit = 64 槽 × 32bit，槽 0 在最高位）**。
//   示例 EU 模型只有 128B：平台给 EU 的是表的高 EU_RF_W 位（槽 0..EU_RF_W/32-1），
//   EU 回刷也只覆盖这一段，低半区保持；接真实 256B EU 时把 EU_RF_W 设成 = RF_W。
//   读给 EU 前把槽位 0（x0，最高 32bit）强制清零。
// EU 侧对接（保持不变）：RMW 的 mstatus slot0 ← CSR 0x2 CCR；ro_regs 的 mcycle ← CSR 0x4 SYS_TS；
//   EU 的 WO 回刷本版只计数（真表里暂无对应只写寄存器）。
// 预发射口（与 DUT 的 csr 预发射口同形）：KO 建线程拍预写 CW 窗低 4 表项，
//   1bit vld + 线程号 + 4bit 表项掩码 + 4×44bit 数据；每拍 ≤1，无握手。
// ============================================================================
import poe_pkg::*;   // CSR 地址表 A_* / 位宽码 W* 来自 poe_pkg（唯一位号表）

module poe_thread_bank #(
    parameter int N_THR = 8,      // 线程数 = CSR/RF 表的份数
    parameter int TID_W = 3,      // 线程号位宽
    parameter int RF_W    = 2048, // 每线程 RF 位宽（256B = 64 槽 × 32bit）
    parameter int EU_RF_W = 1024, // 送/收 EU 的 RF 视图位宽（示例 EU 模型 128B = 32 槽）
    parameter int CSRB  = 72      // 每线程 CSR 字节数（0x00..0x47）
) (
    input  logic             clk,             // 时钟
    input  logic             rst_n,           // 低有效异步复位
    input  logic             alloc,           // 申请线程脉冲（最高优先级）
    input  logic [TID_W-1:0] alloc_tid,       // 清哪个线程
    input  logic [15:0]      alloc_base_ts,   // 建线程同拍写 CSR 0xc PC_INTER（程序基址）
    input  logic             eu_done,         // EU 结果有效拍
    input  logic [TID_W-1:0] eu_done_tid,     // 结果属于哪个线程
    input  logic [EU_RF_W-1:0] eu_rf_out,     // EU 回刷的 RF（只覆盖表的高 EU_RF_W 位）
    input  logic [127:0]     eu_rmw_out,      // {mcause,mepc,mtvec,mstatus}；mstatus[15:0] → CSR 0x2
    input  logic [0:0]       eu_wo_fwe,       // 只写使能
    input  logic             pre_we,          // 预发射口写使能（= 平台 pre_vld）
    input  logic [TID_W-1:0] pre_tid,         // 预写哪个线程的 CW 窗
    input  logic [PRE_N-1:0] pre_strb,        // 每个表项一位（低 4 项）
    input  logic [PRE_N*CW_W-1:0] pre_data,   // 表项 e = pre_data[e*CW_W +: CW_W]
    input  logic             csr_we,          // 平台线程侧 CSR 写使能
    input  logic [TID_W-1:0] csr_wtid,        // 写哪个线程
    input  logic [6:0]       csr_waddr,       // 写地址（字节偏移）
    input  logic [2:0]       csr_ww,          // 写位宽码
    input  logic [383:0]     csr_wdata,       // 写数据（低位对齐）
    input  logic [TID_W-1:0] csr_rtid,        // 读哪个线程
    input  logic [6:0]       csr_raddr,       // 读地址
    input  logic [2:0]       csr_rw,          // 读位宽码
    output logic [383:0]     csr_rdata,       // 读数据（低位对齐）
    input  logic [TID_W-1:0] eu_rd_tid,       // 当前 task 的线程号
    output logic [EU_RF_W-1:0] rf_rdata,      // 送 EU 的 RF 视图（槽 0 = x0，已清零）
    output logic [127:0]     rmw_rdata,       // RMW 组 → EU 的 rmw_in
    output logic [63:0]      ro_regs,         // 只读组 → EU 的 ro_regs
    output logic [N_THR*RF_W-1:0]   rf_flat,  // 全表 RF
    output logic [N_THR*CSRB*8-1:0] csr_flat  // 全表 CSR（按字节：tid*576 +: 576）
);
    // ---- 地址常量（与文件头表一致；验证侧 poe_uvm_pkg 有同一份表）----

    // 位宽码 → 字节数
    function automatic int nbytes(input logic [2:0] w);
        case (w)
            3'd0:    nbytes = 1;    //  8bit
            3'd1:    nbytes = 2;    // 16bit
            3'd2:    nbytes = 4;    // 32bit
            3'd3:    nbytes = 8;    // 64bit
            default: nbytes = 44;   // 352bit
        endcase
    endfunction

    localparam int CWB = int'(A_CW_CMD);   // CW 窗起始字节（0x1c）：之前的字段用字节数组
    // 字节数组保留 72 字节的地址口径（索引宽度和 7bit 地址一致），实际只写到 0x1b；
    // 0x1c..0x47（CW 窗，44bit 表项非字节对齐）单独用下面的 cw 寄存器存。
    logic [7:0]      csr [N_THR][CSRB];
    logic [CW_N*CW_W-1:0] cw [N_THR];               // 0x1c..0x47：CW 窗（8×44bit）
    logic [RF_W-1:0] rf  [N_THR];

    // EU 回刷合并值：表的高 EU_RF_W 位来自 EU，低 (RF_W-EU_RF_W) 位保持表内旧值；
    // RF_W == EU_RF_W（真实 256B EU）时就是 EU 的整表值。
    logic [RF_W-1:0] rf_wb;
    always_comb begin
        rf_wb = rf[eu_done_tid];
        rf_wb[RF_W-1 -: EU_RF_W] = eu_rf_out;
    end

    // ---- EU 读口 ----
    // EU 视图 = 表的高 EU_RF_W 位（槽 0..EU_RF_W/32-1），其中槽 0（x0）硬连零
    assign rf_rdata  = {32'd0, rf[eu_rd_tid][RF_W-33 -: EU_RF_W-32]};
    // RMW 组布局按 sa_pkg：mstatus[127:96] | mtvec[95:64] | mepc[63:32] | mcause[31:0]
    // 平台把线程 CCR（CSR 0x2，低字节在低地址）映射到 **mstatus 的低 16bit**；
    // mtvec/mepc/mcause 本版不建模（给 0）。注意别把它放到 [15:0]（那是 mcause 槽）。
    assign rmw_rdata = {16'd0,
                        csr[eu_rd_tid][A_CCR + 1], csr[eu_rd_tid][A_CCR],   // mstatus[15:0] = CCR
                        96'd0};                                            // mtvec/mepc/mcause = 0
    assign ro_regs   = {{csr[eu_rd_tid][A_SYS_TS+3], csr[eu_rd_tid][A_SYS_TS+2],
                         csr[eu_rd_tid][A_SYS_TS+1], csr[eu_rd_tid][A_SYS_TS]}, 32'd0};

    // ---- SYS_TS：平台每拍刷新的系统时标（EU 当 mcycle 读）----
    logic [31:0] sys_ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sys_ts <= 32'd0;
        else        sys_ts <= sys_ts + 32'd1;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int t = 0; t < N_THR; t++) begin
                csr[t][A_SYS_TS]     <= 8'd0;
                csr[t][A_SYS_TS + 1] <= 8'd0;
                csr[t][A_SYS_TS + 2] <= 8'd0;
                csr[t][A_SYS_TS + 3] <= 8'd0;
            end
        end else begin
            for (int t = 0; t < N_THR; t++) begin
                // 小端：低字节在低地址
                csr[t][A_SYS_TS]     <= sys_ts[7:0];
                csr[t][A_SYS_TS + 1] <= sys_ts[15:8];
                csr[t][A_SYS_TS + 2] <= sys_ts[23:16];
                csr[t][A_SYS_TS + 3] <= sys_ts[31:24];
            end
        end
    end

    // ---- EU 回刷：done 拍直接落表（RF 整表 + CCR；WO 只计数）----
    //   契约见 poe_eu_rm 文件头：done 拍 rf_out/rmw_out 同拍有效。
    //   这里不能再打一拍：线程池在 done 的下一拍就可能发同线程的下一条 task，
    //   多一级流水会让 EU 读到回刷前的旧 RF（RAW 冒险）。
    logic [31:0]      wo_cnt;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    wo_cnt <= '0;
        else if (eu_done && eu_wo_fwe[0]) wo_cnt <= wo_cnt + 32'd1;   // WO 本版只计数（无落点）
    end

    // ---- 三个写来源仲裁：① 申请清零 ② EU 回刷 ③ 平台线程侧写 ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int t = 0; t < N_THR; t++) begin
                for (int b = 0; b < CWB; b++) csr[t][b] <= 8'd0;
                cw[t] <= '0;
                rf[t] <= '0;
            end
        end else begin
            if (alloc) begin
                // 建线程：一拍成型（先全清，再写 4 个字段；同一变量上后写的 NBA 生效）
                for (int b = 0; b < CWB; b++) csr[alloc_tid][b] <= 8'd0;
                cw[alloc_tid] <= '0;                                     // CW 窗清零
                csr[alloc_tid][A_TH_ID]        <= {{(8-TID_W){1'b0}}, alloc_tid};   // 0x8 TH_ID = tid
                csr[alloc_tid][A_TH_STAT]      <= TH_RUN;               // 0x9 TH_STAT = RUN
                csr[alloc_tid][A_PC_INTER]     <= alloc_base_ts[7:0];   // 0xc PC_INTER（小端）
                csr[alloc_tid][A_PC_INTER + 1] <= alloc_base_ts[15:8];
                csr[alloc_tid][A_CUR_TS]       <= 8'd0;                 // 0xe CUR_TS = 0
                rf[alloc_tid] <= '0;
            end
            // EU 回刷：只有"同一拍又在 alloc 同一个 tid"才让位（正常不会发生）
            if (eu_done && !(alloc && (alloc_tid == eu_done_tid))) begin
                rf[eu_done_tid] <= rf_wb;
                if (eu_rmw_out[111:96] != {csr[eu_done_tid][A_CCR+1], csr[eu_done_tid][A_CCR]}) begin
                    csr[eu_done_tid][A_CCR]     <= eu_rmw_out[103:96];
                    csr[eu_done_tid][A_CCR + 1] <= eu_rmw_out[111:104];
                end
            end
            // 平台线程侧写：只有"同一拍又在 alloc 同一个 tid"才让位
            if (csr_we && !(alloc && (alloc_tid == csr_wtid))) begin
                // 注意：下标必须内联算（int'(..)+i），不要用循环体里声明的变量 ——
                // 仿真器会把那种变量当单个静态变量，44 次 NBA 会全用最后一次的地址。
                for (int i = 0; i < 44; i++)
                    if ((i < nbytes(csr_ww)) && ((int'(csr_waddr) + i) < CSRB)) begin
                        if ((int'(csr_waddr) + i) < CWB)
                            csr[csr_wtid][int'(csr_waddr) + i] <= csr_wdata[i*8 +: 8];
                        else
                            cw[csr_wtid][(int'(csr_waddr) - CWB + i)*8 +: 8] <= csr_wdata[i*8 +: 8];
                    end
            end
            // 预发射口：建线程拍预写 CW 窗低 4 表项。
            //   放在 alloc 之后：同一拍又建同一个线程时，预读数据不会被清零覆盖（后写生效）。
            for (int e = 0; e < PRE_N; e++)
                if (pre_we && pre_strb[e])
                    cw[pre_tid][e*CW_W +: CW_W] <= pre_data[e*CW_W +: CW_W];
        end
    end

    // ---- 平台线程侧读口 ----
    always_comb begin
        csr_rdata = '0;
        for (int i = 0; i < 44; i++)
            if ((i < nbytes(csr_rw)) && ((int'(csr_raddr) + i) < CSRB)) begin
                if ((int'(csr_raddr) + i) < CWB)
                    csr_rdata[i*8 +: 8] = csr[csr_rtid][int'(csr_raddr) + i];
                else
                    csr_rdata[i*8 +: 8] = cw[csr_rtid][(int'(csr_raddr) - CWB + i)*8 +: 8];
            end
    end

    // ---- 观测扁平化 ----
    always_comb begin
        for (int t = 0; t < N_THR; t++) begin
            rf_flat[t*RF_W +: RF_W] = rf[t];
            for (int b = 0; b < CWB; b++)
                csr_flat[(t*CSRB + b)*8 +: 8] = csr[t][b];
            for (int b = 0; b < CW_N*CW_W/8; b++)
                csr_flat[(t*CSRB + CWB + b)*8 +: 8] = cw[t][b*8 +: 8];
        end
    end
endmodule
