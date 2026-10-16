// ============================================================================
// MUX 指令存储 —— 一行 = 五组字段（取数 32×11 + 移位 32×15 + CCR 2×5 + O 路 16×11 + O 路移位 16×15），
//   行宽 1280bit（含预留），按 sub_pc 索引；行布局见 poe_pkg 的 ⑤ 节（唯一位号表）。
//
//   · 载入方式与 EU 的微指令 bank 一致：TB/test 通过 we/waddr/wdata 预载
//     （MUX 画像和微指令画像是一套程序的两半，一起加载才不会错位）。
//   · 读口组合：给出行号当拍就返回整行，MUX/DMUX 在同拍解码
//     （MUX 组窗口、DMUX 做逆操作回填；两边读的是同一行的同一份数据）。
//   · 取数指令字段（11bit）：[10]i、[9:8]mvld、[7:0]src_ptr/立即偏移
//     移位指令字段（15bit）：[14:11]bits0、[10]lr0、[9:7]shift0、[6:4]bits1、[3]lr1、[2:0]shift1
// ============================================================================
import poe_pkg::*;

module poe_mux_imem #(
    parameter int ROWS  = 16,         // 行数（与 EU 微指令 bank 一致）
    parameter int AW    = MUX_AW,     // 行号位宽（= sub_pc 位宽）
    parameter int ROW_W = MUX_ROW_W   // 行宽（1280bit，含预留；实际用到 1258bit）
) (
    input  logic             clk,      // 预载时钟
    input  logic [AW-1:0]    rd_addr,  // 读行号（= sub_pc）
    output logic [ROW_W-1:0] rd_row,   // 该行整行 MUX 指令（组合读）
    input  logic             we,       // 预载写使能
    input  logic [AW-1:0]    waddr,    // 预载行号
    input  logic [ROW_W-1:0] wdata     // 预载数据（一行）
);
    logic [ROW_W-1:0] mem [ROWS];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    assign rd_row = mem[rd_addr];
endmodule
