// ============================================================================
// DMUX 指令存储 —— 与 MUX 指令存储**物理分开**（各自独立的预载口/内容）
//   行布局与 MUX 指令行相同（见 poe_pkg ⑤ 节）：
//     32×11 取数 + 8×15 主 lane + 8×5 CCR + 16×11 O 取数 + 4×15 O lane，行宽 768bit。
//   默认画像与 MUX 相同（DMUX 用同一组指令做逆操作），但后续可以独立修改/加载，
//   不影响 MUX 侧指令。
// ============================================================================
import poe_pkg::*;

module poe_dmux_imem #(
    parameter int ROWS  = 16,         // 行数（与 EU 微指令 bank 一致）
    parameter int AW    = MUX_AW,     // 行号位宽（= sub_pc）
    parameter int ROW_W = MUX_ROW_W   // 行宽（768bit）
) (
    input  logic             clk,      // 预载时钟
    input  logic [AW-1:0]    rd_addr,  // 读行号（= sub_pc）
    output logic [ROW_W-1:0] rd_row,   // 该行整行 DMUX 指令（组合读）
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
