// ============================================================================
// MUX 指令存储 —— 一行 32 条 × 11bit = 352bit，按 sub_pc 索引
//
//   · 载入方式与 EU 的微指令 bank 一致：TB/test 通过 we/waddr/wdata 预载
//     （MUX 画像和微指令画像是一套程序的两半，一起加载才不会错位）。
//   · 读口组合：给出行号当拍就返回整行 352bit，MUX 在同拍解码 32 条。
//   · 指令字段见 poe_pkg（MI_* / MUX_INS_*）：[10]i、[9:8]mvld、[7:0]src_ptr/立即偏移。
// ============================================================================
import poe_pkg::*;

module poe_mux_imem #(
    parameter int ROWS  = 16,         // 行数（与 EU 微指令 bank 一致）
    parameter int AW    = MUX_AW,     // 行号位宽（= sub_pc 位宽）
    parameter int ROW_W = MUX_ROW_W   // 行宽（32×11 = 352bit）
) (
    input  logic             clk,      // 预载时钟
    input  logic [AW-1:0]    rd_addr,  // 读行号（= sub_pc）
    output logic [ROW_W-1:0] rd_row,   // 该行 32 条 MUX 指令（组合读）
    input  logic             we,       // 预载写使能
    input  logic [AW-1:0]    waddr,    // 预载行号
    input  logic [ROW_W-1:0] wdata     // 预载数据（一行 32 条）
);
    logic [ROW_W-1:0] mem [ROWS];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
    end

    assign rd_row = mem[rd_addr];
endmodule
