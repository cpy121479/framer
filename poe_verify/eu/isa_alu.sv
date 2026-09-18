// ============================================================
// 示例混合指令集 v0.1 —— ALU：按指令编码选择指令行为函数
// 由 ISA Studio 自动生成。掩码/值与编码编辑一致（x/未填位不参与）；
// 优先级：固定位多者先、长指令先；编码交叠处以下方注释提示。
// 用法：送入指令字/pc/寄存器操作数值/读 CSR；立即数等字段在指令函数内部经格式
//       结构体识别。valid=1 时 dst/dst_mask = 命中指令的结果与按位写使能（无 dst
//       字段的指令不驱动）；寄存器堆提交建议：if (valid) for 每位 if (dst_mask[i]) gpr[dst_idx][i] <= dst[i]。
// ============================================================
module isa_alu #(
  parameter XLEN = isa_pkg::XLEN
) (
  input  wire [31:0]     instr,
  input  wire [XLEN-1:0] pc,
  input  wire [XLEN-1:0] rs1, // rs1（寄存器值）
  input  wire [XLEN-1:0] rs2, // rs2（寄存器值）
  input  wire [31:0] mstatus, // CSR 读口：mstatus（读写）
  input  wire [31:0] mcycle, // CSR 读口：mcycle（只读）
  output logic [XLEN-1:0] dst,
  output logic [XLEN-1:0] dst_mask, // 按位写使能：0 = dst 对应位不写入（默认全 1）
  output logic            valid,
  output logic [31:0] mstatus_w, output logic mstatus_we // CSR 写口：mstatus（读写）
);
  import isa_instr_pkg::*; // void 指令函数需非限定名调用（Icarus 不支持包限定 void 语句）
  // ---- 编码命中 ----
  wire hit0 = (instr & 32'hFFFF_FFFF) == 32'h0000_0073; // ECALL
  wire hit1 = (instr & 32'hFE00_707F) == 32'h0000_0033; // ADD
  wire hit2 = (instr & 32'hFE00_707F) == 32'h4000_0033; // SUB
  wire hit3 = (instr & 32'hFE00_707F) == 32'h0000_1033; // SLL
  wire hit4 = (instr & 32'h0000_707F) == 32'h0000_0067; // JALR
  wire hit5 = (instr & 32'h0000_707F) == 32'h0000_0013; // ADDI
  wire hit6 = (instr & 32'h0000_707F) == 32'h0000_2003; // LW
  wire hit7 = (instr & 32'h0000_707F) == 32'h0000_2023; // SW
  wire hit8 = (instr & 32'h0000_707F) == 32'h0000_0063; // BEQ
  wire hit9 = (instr & 32'h0000_707F) == 32'h0000_1073; // CSRRW
  wire hit10 = (instr & 32'h0000_707F) == 32'h0000_2073; // CSRR
  wire hit11 = (instr & 32'h0000_007F) == 32'h0000_0037; // LUI
  wire hit12 = (instr & 32'h0000_007F) == 32'h0000_0017; // AUIPC
  wire hit13 = (instr & 32'h0000_007F) == 32'h0000_006F; // JAL

  // ---- 按命中选择指令函数（含 CSR 自动连线）----
  always_comb begin
    isa_instr_pkg::ECALL_out_t out0; // ECALL 返回
    isa_instr_pkg::ADD_out_t out1; // ADD 返回
    isa_instr_pkg::SUB_out_t out2; // SUB 返回
    isa_instr_pkg::SLL_out_t out3; // SLL 返回
    isa_instr_pkg::JALR_out_t out4; // JALR 返回
    isa_instr_pkg::ADDI_out_t out5; // ADDI 返回
    isa_instr_pkg::LW_out_t out6; // LW 返回
    isa_instr_pkg::CSRRW_out_t out9; // CSRRW 返回
    isa_instr_pkg::CSRR_out_t out10; // CSRR 返回
    isa_instr_pkg::LUI_out_t out11; // LUI 返回
    isa_instr_pkg::AUIPC_out_t out12; // AUIPC 返回
    isa_instr_pkg::JAL_out_t out13; // JAL 返回
    out0 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out1 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out2 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out3 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out4 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out5 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out6 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out9 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out10 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out11 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out12 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    out13 = '0; // 默认值：仅在命中分支读取，缺省赋值以避免综合/告警按锁存器处理
    valid  = 1'b0;
    dst = {XLEN{1'b0}}; // 无 dst 字段的指令不驱动 dst/dst_mask
    dst_mask = {XLEN{1'b1}}; // 默认全写
    mstatus_w = {32{1'b0}};
    mstatus_we = 1'b0;
      if (hit0) begin
        valid  = 1'b1;
        out0 = isa_instr_pkg::ECALL(instr, pc, rs1);
        dst = out0.dst;
        dst_mask = out0.dst_mask;
      end
      else if (hit1) begin
        valid  = 1'b1;
        out1 = isa_instr_pkg::ADD(instr, pc, rs1, rs2);
        dst = out1.dst;
        dst_mask = out1.dst_mask;
      end
      else if (hit2) begin
        valid  = 1'b1;
        out2 = isa_instr_pkg::SUB(instr, pc, rs1, rs2);
        dst = out2.dst;
        dst_mask = out2.dst_mask;
      end
      else if (hit3) begin
        valid  = 1'b1;
        out3 = isa_instr_pkg::SLL(instr, pc, rs1, rs2);
        dst = out3.dst;
        dst_mask = out3.dst_mask;
      end
      else if (hit4) begin
        valid  = 1'b1;
        out4 = isa_instr_pkg::JALR(instr, pc, rs1);
        dst = out4.dst;
        dst_mask = out4.dst_mask;
      end
      else if (hit5) begin
        valid  = 1'b1;
        out5 = isa_instr_pkg::ADDI(instr, pc, rs1);
        dst = out5.dst;
        dst_mask = out5.dst_mask;
      end
      else if (hit6) begin
        valid  = 1'b1;
        out6 = isa_instr_pkg::LW(instr, pc, rs1);
        dst = out6.dst;
        dst_mask = out6.dst_mask;
      end
      else if (hit7) begin
        valid  = 1'b1;
        SW(instr, pc, rs1, rs2); // 无 dst 字段：void 调用（非限定名，Icarus 不支持包限定 void 语句）
      end
      else if (hit8) begin
        valid  = 1'b1;
        BEQ(instr, pc, rs1, rs2); // 无 dst 字段：void 调用（非限定名，Icarus 不支持包限定 void 语句）
      end
      else if (hit9) begin
        valid  = 1'b1;
        out9 = isa_instr_pkg::CSRRW(instr, pc, rs1, mstatus);
        dst = out9.dst;
        dst_mask = out9.dst_mask;
        mstatus_w = out9.mstatus_w;
        mstatus_we = 1'b1;
      end
      else if (hit10) begin
        valid  = 1'b1;
        out10 = isa_instr_pkg::CSRR(instr, pc, rs1, mcycle);
        dst = out10.dst;
        dst_mask = out10.dst_mask;
      end
      else if (hit11) begin
        valid  = 1'b1;
        out11 = isa_instr_pkg::LUI(instr, pc);
        dst = out11.dst;
        dst_mask = out11.dst_mask;
      end
      else if (hit12) begin
        valid  = 1'b1;
        out12 = isa_instr_pkg::AUIPC(instr, pc);
        dst = out12.dst;
        dst_mask = out12.dst_mask;
      end
      else if (hit13) begin
        valid  = 1'b1;
        out13 = isa_instr_pkg::JAL(instr, pc);
        dst = out13.dst;
        dst_mask = out13.dst_mask;
      end
  end
endmodule
