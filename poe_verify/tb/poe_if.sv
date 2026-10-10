// ============================================================================
// 平台接口（UVM 侧唯一的激励/观测契约）
//   激励：KO 48B + 随路 pre_read 96bit（driver 驱动本接口，顶层分叉给两套平台）
//   预载：只有微指令（EU 内两级 bank）；burst 指令存储是 ROM，模块内部 initial 拼镜像
//   观测：DUT / RM 两侧的 ts 边界事件、线程结束、出口 KO、两张表快照
// ============================================================================
interface poe_if (
    input logic clk,              // 时钟
    input logic rst_n             // 低有效异步复位
);
    // 宽度定死：interface 的位宽就是 UVM 侧看到的契约，不做参数化
    // （Verilator 把不同参数化的 interface 当不同类型，virtual interface 会对不上）
    localparam int N_THR = 64;    // 线程数（表的份数）
    localparam int TID_W = 6;     // 线程号位宽（N_THR=64 → 6bit）
    localparam int RF_W  = 2048;  // 每线程 RF 位宽（256B = 64 槽 × 32bit）
    localparam int TS_W  = 4;     // ts 行号位宽
    // ---- 激励：KO 报文 ----
    logic         ko_vld;         // 入口 KO 有效（driver 驱动）
    logic         ko_rdy;         // 平台能收（两侧都 ready 才为 1）
    logic [383:0] ko_data;        // 48B 报文；行2 的 POE_HEAD = 程序基址（ts 行号）
    // ---- 激励：csr 预发射口（KO 建线程拍预写 CW 窗低 4 表项；每拍 ≤1，无握手）----
    logic         pre_vld;        // 1bit vld（与 KO 建线程同拍）
    logic [5:0]   pre_thid;       // 预写哪个线程的 CW 窗
    logic [3:0]   pre_strb;       // 4 个表项各自一位
    logic [175:0] pre_data;       // 4×44bit，表项 e = pre_data[e*44 +: 44]
    // ---- 预载：微指令存储（两级 bank 在 EU 内部）----
    logic         imem_we;        // bank 写使能
    logic [0:0]   imem_saddr;     // 0=s0（x0..x15）1=s1（x8..x31）
    logic [3:0]   imem_waddr;     // 行号 = sub_pc
    logic [63:0]  imem_wdata;     // 一行 = {lane0, lane1} 两条 32bit 指令
    // ---- 预载：MUX 指令存储（一行 = 32 条 × 11bit）----
    logic         mux_imem_we;    // 写使能
    logic [3:0]   mux_imem_waddr; // 行号 = sub_pc
    logic [351:0] mux_imem_wdata; // 一行 = 32 条 × 11bit
    // ---- DUT 侧观测 ----
    logic         out_vld;        // 出口 KO 有效（一拍）
    logic [383:0] out_data;       // 出口 48B（EU 回刷结果）
    logic [TID_W-1:0] out_tid;    // 属于哪个线程
    logic         ts_done_vld;    // 一个 ts 结束（校验点，一拍）
    logic [TID_W-1:0] ts_done_tid;// 该 ts 属于哪个线程
    logic [TS_W-1:0] ts_done_idx; // 第几个 ts
    logic         thr_done_vld;   // 线程结束（一拍）
    logic [TID_W-1:0] thr_done_tid; // 结束的线程号
    logic         busy;           // 平台上还有线程在跑
    logic [7:0]   ct_skip_cnt;    // 跳过的 c_task 条数
    // ---- EU 错误标志（随结果拍有效；EU 边界契约的一部分）----
    logic         eu_err_vld;     // DUT 侧错误标志有效
    logic [5:0]   eu_err_tid;     // DUT 侧错误属于哪个线程
    logic [3:0]   eu_err;         // DUT 侧错误标志
    logic [N_THR*RF_W-1:0] rf_dut;// DUT 侧全表 RF：tid*RF_W +: RF_W
    logic [N_THR*72*8-1:0] csr_dut;// DUT 侧 CSR 全表（按字节）：tid*576 +: 576
    logic [N_THR*32-1:0]   ccr_dut;// DUT 侧全表 CCR：tid*32 +: 16
    // ---- RM 侧观测（期望值）----
    logic         out_vld_rm;     // RM 出口 KO 有效
    logic [383:0] out_data_rm;    // RM 出口 48B
    logic [TID_W-1:0] out_tid_rm; // RM 出口 KO 的线程号
    logic         ts_done_vld_rm; // RM 侧 ts 边界事件
    logic [TID_W-1:0] ts_done_tid_rm; // 该 ts 属于哪个线程
    logic [TS_W-1:0] ts_done_idx_rm; // 第几个 ts
    logic [N_THR*RF_W-1:0] rf_rm; // RM 侧全表 RF
    logic [N_THR*72*8-1:0] csr_rm; // RM 侧 CSR 全表（按字节）
    logic [N_THR*32-1:0]   ccr_rm;// RM 侧全表 CCR
    // ---- RM 侧 EU 错误标志 ----
    logic         eu_err_vld_rm;  // RM 侧错误标志有效
    logic [5:0]   eu_err_tid_rm;  // RM 侧错误属于哪个线程
    logic [3:0]   eu_err_rm;      // RM 侧错误标志
endinterface
