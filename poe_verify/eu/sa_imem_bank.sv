// sa_imem_bank.sv —— SA-generator 固定模板，请勿手工修改
// 纯存储：加载口写、随路 PC 组合读出（寄存器堆实现；BRAM 推断为后续扩展项）。
module sa_imem_bank #(
  parameter int unsigned DEPTH  = 64,
  parameter int unsigned WORD_W = 32
) (
  input  logic clk,
  input  logic load_we,
  input  logic [$clog2(DEPTH)-1:0] load_addr,
  input  logic [WORD_W-1:0]        load_wdata,
  input  logic [$clog2(DEPTH)-1:0] rd_addr,    // 波前随路 PC
  output logic [WORD_W-1:0]        instr
);

  logic [WORD_W-1:0] mem [DEPTH];

  always_ff @(posedge clk) begin
    if (load_we)
      mem[load_addr] <= load_wdata;
  end

  assign instr = mem[rd_addr];

endmodule
