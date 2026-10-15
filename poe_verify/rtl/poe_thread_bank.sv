// ============================================================================
// 线程上下文存储：每线程一份 CSR + RF（平台侧；DUT/RM 的 EU 接口不动）
//
// CSR = **字节寻址寄存器组**（地址是字节偏移，每个寄存器占它自己的那几个字节）：
//   0x0  16b ERR        0x2  16b CCR       0x4   8b CCR_MASK   0x5  32b SYS_TS
//   0x9   8b TH_ID      0xa   8b TH_STAT   0xb   2b O_TSK_SET  0xc   8b O_LABEL
//   0xd  16b PC_INTER   0xf   8b CUR_TS    0x10  8b TSK_C      0x11  8b DMA_C
//   0x12  8b MUX_C      0x13  2b LK_SET    0x14 16b LK_TAG     0x16 64b MUX_PTR
//   0x1e 128b CW_MUX    0x2e 352b CW_CMD
//   总空间 0x00..0x59（90 字节）
//   访问方式：{addr[6:0], 位宽码[2:0], data[383:0]}；位宽码 0=8b 1=16b 2=32b 3=64b 4=352b 5=128b
//   存储：0x00..0x2d 用字节数组；0x2e..0x59（CW 窗 = 8 项 × 44bit）单独用 352bit 寄存器，
//         因为预发射口按 44bit 表项写、不是字节对齐的。
//
// RF = 每线程 **256B（2048bit = 64 槽 × 32bit，槽 0 在最高位）**。
//   本模块只做存储：给 MUX 一个"整份 RF 读口 + 整份 RF 回写口"，
//   取数/回写的字节位置由 MUX（poe_mux）按 MUX 指令决定，bank 不解释 RF 的语义。
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
    parameter int CSRB  = 90      // 每线程 CSR 字节数（0x00..0x59）
) (
    input  logic             clk,             // 时钟
    input  logic             rst_n,           // 低有效异步复位
    input  logic             alloc,           // 申请线程脉冲（最高优先级）
    input  logic [TID_W-1:0] alloc_tid,       // 清哪个线程
    input  logic [15:0]      alloc_base_ts,   // 建线程同拍写 CSR 0xc PC_INTER（程序基址）
    input  logic             mux_rf_we,       // MUX 回写 RF（一拍，一个 task 一次）
    input  logic [TID_W-1:0] mux_rf_tid,      // 回写哪个线程
    input  logic [RF_W-1:0]  mux_rf_wdata,    // 回写后的整份 RF
    // ---- EU 侧 POE CSR 写口（通用：地址 + 位宽 + 数据；CCR 只是地址 0x2 的一个表项）----
    input  logic             eu_csr_we,       // EU 发起的 CSR 写使能
    input  logic [TID_W-1:0] eu_csr_wtid,     // 写哪个线程
    input  logic [6:0]       eu_csr_waddr,    // 写地址（字节偏移）
    input  logic [2:0]       eu_csr_ww,       // 写位宽码
    input  logic [383:0]     eu_csr_wdata,    // 写数据（低位对齐）
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
    input  logic [TID_W-1:0] rf_rd_tid,       // MUX 要读哪个线程的 RF
    output logic [RF_W-1:0]  rf_rd,           // 该线程整份 256B RF（组合读）
    output logic [N_THR*RF_W-1:0]   rf_flat,  // 全表 RF
    output logic [N_THR*CSRB*8-1:0] csr_flat  // 全表 CSR（按字节：tid*CSRB*8 +: CSRB*8）
);
    // ---- 地址常量（与文件头表一致；验证侧 poe_uvm_pkg 有同一份表）----

    // 位宽码 → 字节数
    function automatic int nbytes(input logic [2:0] w);
        case (w)
            3'd0:    nbytes = 1;    //  8bit
            3'd1:    nbytes = 2;    // 16bit
            3'd2:    nbytes = 4;    // 32bit
            3'd3:    nbytes = 8;    // 64bit
            3'd5:    nbytes = 16;   // 128bit（CW_MUX）
            default: nbytes = 44;   // 352bit
        endcase
    endfunction

    localparam int CWB = int'(A_CW_CMD);   // CW 窗起始字节（0x2e）：之前的字段用字节数组
    // 字节数组保留 90 字节的地址口径（索引宽度和 7bit 地址一致），实际只写到 0x2d；
    // 0x2e..0x59（CW 窗，44bit 表项非字节对齐）单独用下面的 cw 寄存器存。
    logic [7:0]      csr [N_THR][CSRB];
    logic [CW_N*CW_W-1:0] cw [N_THR];               // 0x2e..0x59：CW 窗（8×44bit）
    logic [RF_W-1:0] rf  [N_THR];

    // ---- MUX 读口：整份 RF 给 MUX，按字节切数由 MUX 自己做 ----
    assign rf_rd = rf[rf_rd_tid];
    // 注：POE CSR ↔ EU 侧 CSR（RISC-V 束）的映射**不在这里**，
    //     已经挪到 EU 壳（poe_eu_dut/poe_eu_rm），bank 只做通用存储。

    // ---- SYS_TS：平台每拍刷新的系统时标（EU 当 mcycle 读）----
    logic [31:0] sys_ts;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sys_ts <= 32'd0;
        else        sys_ts <= sys_ts + 32'd1;
    end

    // ---- **csr/cw/rf 的唯一写者**（所有写来源合在一个 always_ff 里）----
    //   写来源（按本块内顺序，后面的优先级更高）：
    //     ① SYS_TS 每拍刷新  ② 申请清零+初始化  ③ EU 的 RF 回刷
    //     ④ 平台线程侧 CSR 写 ⑤ EU 侧通用 CSR 写 ⑥ 预发射口预写 CW 低 4 项
    //   注意：VCS/Xcelium 不允许同一个变量被两个 always 块写，所以 SYS_TS 刷新
    //   也必须放在这里（Verilator 容忍但别的工具会报 left-hand 多进程写）。
    //   EU 的 RF 回刷必须 done 拍直接落表（契约见 poe_eu_rm 文件头）：
    //   线程池在 done 的下一拍就可能发同线程的下一条 task，多一级流水会读到旧 RF。
    //   CSR 写（CCR 等）走同一套字节/位宽逻辑，CCR 只是地址 0x2 的一个表项，不再特判。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int t = 0; t < N_THR; t++) begin
                for (int b = 0; b < CWB; b++) csr[t][b] <= 8'd0;
                cw[t] <= '0;
                rf[t] <= '0;
            end
        end else begin
            // ① SYS_TS：每拍把所有线程的 0x5..0x8 刷成系统时标（小端）
            for (int t = 0; t < N_THR; t++) begin
                csr[t][int'(A_SYS_TS)]     <= sys_ts[7:0];
                csr[t][int'(A_SYS_TS) + 1] <= sys_ts[15:8];
                csr[t][int'(A_SYS_TS) + 2] <= sys_ts[23:16];
                csr[t][int'(A_SYS_TS) + 3] <= sys_ts[31:24];
            end
            if (alloc) begin
                // 建线程：一拍成型（先全清，再写 4 个字段；同一变量上后写的 NBA 生效）
                for (int b = 0; b < CWB; b++) csr[alloc_tid][b] <= 8'd0;
                cw[alloc_tid] <= '0;                                     // CW 窗清零
                csr[alloc_tid][A_TH_ID]        <= {{(8-TID_W){1'b0}}, alloc_tid};   // 0x9 TH_ID = tid
                csr[alloc_tid][A_TH_STAT]      <= TH_RUN;               // 0xa TH_STAT = RUN
                csr[alloc_tid][A_PC_INTER]     <= alloc_base_ts[7:0];   // 0xd PC_INTER（小端）
                csr[alloc_tid][A_PC_INTER + 1] <= alloc_base_ts[15:8];
                csr[alloc_tid][A_CUR_TS]       <= 8'd0;                 // 0xf CUR_TS = 0
                // 0x16 MUX_PTR 建线程默认值（8×8bit 指针表，非全 0）
                for (int i = 0; i < 8; i++)
                    csr[alloc_tid][int'(A_MUX_PTR) + i] <= MUX_PTR_DEF[i*8 +: 8];
                rf[alloc_tid] <= '0;
            end
            // MUX 回写整份 RF：一个 task 一次（MUX 已经把没被指令覆盖的字节并好）
            //   只有"同一拍又在 alloc 同一个 tid"才让位（正常不会发生）
            if (mux_rf_we && !(alloc && (alloc_tid == mux_rf_tid))) begin
                rf[mux_rf_tid] <= mux_rf_wdata;
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
            // EU 侧 CSR 写（通用口，CCR 就是地址 0x2）：与线程侧同一套落表逻辑，
            //   放在最后 → 同一拍同地址时 EU 优先。
            if (eu_csr_we && !(alloc && (alloc_tid == eu_csr_wtid))) begin
                for (int i = 0; i < 44; i++)
                    if ((i < nbytes(eu_csr_ww)) && ((int'(eu_csr_waddr) + i) < CSRB)) begin
                        if ((int'(eu_csr_waddr) + i) < CWB)
                            csr[eu_csr_wtid][int'(eu_csr_waddr) + i] <= eu_csr_wdata[i*8 +: 8];
                        else
                            cw[eu_csr_wtid][(int'(eu_csr_waddr) - CWB + i)*8 +: 8] <= eu_csr_wdata[i*8 +: 8];
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
