// ============================================================
// 示例混合指令集 v0.1 —— 指令格式解析包
// 由 ISA Studio 自动生成：每格式一个 packed struct + 解码函数。
// struct 首成员 = 最高位，与编码图位序一致；带枚举的字段直接使用枚举类型。
// 语义中可直接调用：isa_formats_pkg::decode_i(instr).imm_11_0
// ============================================================
package isa_formats_pkg;
  import isa_pkg::*; // 指令字位宽 IW

  // ---- U（32 位）----
  // 字段自最高位：imm[31:12]（31:12）, dst（11:7）, opcode（6:0）
  typedef struct packed {
    logic [19:0] imm_31_12;                 // [31:12]（imm[31:12]）
    logic [4:0] dst;                        // [11:7]
    logic [6:0] opcode;                     // [6:0]
  } fmt_u_t;

  // 解码：指令字低 32 位按位覆盖到结构体，如 fmt_u_t h = decode_u(instr);
  function automatic fmt_u_t decode_u(input logic [31:0] instr);
    fmt_u_t s;
    s = instr[31:0]; // 高位对齐：取指令字顶部 32 位
    return s;
  endfunction

  // ---- J（32 位）----
  // 字段自最高位：imm[20|10:1|11|19:12]（31:12）, dst（11:7）, opcode（6:0）
  typedef struct packed {
    logic [19:0] imm_20_10_1_11_19_12;      // [31:12]（imm[20|10:1|11|19:12]）
    logic [4:0] dst;                        // [11:7]
    logic [6:0] opcode;                     // [6:0]
  } fmt_j_t;

  // 解码：指令字低 32 位按位覆盖到结构体，如 fmt_j_t h = decode_j(instr);
  function automatic fmt_j_t decode_j(input logic [31:0] instr);
    fmt_j_t s;
    s = instr[31:0]; // 高位对齐：取指令字顶部 32 位
    return s;
  endfunction

  // ---- I（32 位）----
  // 字段自最高位：imm[11:0]（31:20）, rs1（19:15）, funct3（14:12）, dst（11:7）, opcode（6:0）
  typedef struct packed {
    logic [11:0] imm_11_0;                  // [31:20]（imm[11:0]）
    logic [4:0] rs1;                        // [19:15]
    logic [2:0] funct3;                     // [14:12]
    logic [4:0] dst;                        // [11:7]
    logic [6:0] opcode;                     // [6:0]
  } fmt_i_t;

  // 解码：指令字低 32 位按位覆盖到结构体，如 fmt_i_t h = decode_i(instr);
  function automatic fmt_i_t decode_i(input logic [31:0] instr);
    fmt_i_t s;
    s = instr[31:0]; // 高位对齐：取指令字顶部 32 位
    return s;
  endfunction

  // ---- I0（32 位）----
  // 字段自最高位：zero（31:20）, rs1（19:15）, funct3（14:12）, dst（11:7）, opcode（6:0）
  typedef struct packed {
    logic [11:0] zero;                      // [31:20]
    logic [4:0] rs1;                        // [19:15]
    logic [2:0] funct3;                     // [14:12]
    logic [4:0] dst;                        // [11:7]
    logic [6:0] opcode;                     // [6:0]
  } fmt_i0_t;

  // 解码：指令字低 32 位按位覆盖到结构体，如 fmt_i0_t h = decode_i0(instr);
  function automatic fmt_i0_t decode_i0(input logic [31:0] instr);
    fmt_i0_t s;
    s = instr[31:0]; // 高位对齐：取指令字顶部 32 位
    return s;
  endfunction

  // ---- R（32 位）----
  // 字段自最高位：funct7（31:25）, rs2（24:20）, rs1（19:15）, funct3（14:12）, dst（11:7）, opcode（6:0）
  typedef struct packed {
    logic [6:0] funct7;                     // [31:25]
    logic [4:0] rs2;                        // [24:20]
    logic [4:0] rs1;                        // [19:15]
    logic [2:0] funct3;                     // [14:12]
    logic [4:0] dst;                        // [11:7]
    logic [6:0] opcode;                     // [6:0]
  } fmt_r_t;

  // 解码：指令字低 32 位按位覆盖到结构体，如 fmt_r_t h = decode_r(instr);
  function automatic fmt_r_t decode_r(input logic [31:0] instr);
    fmt_r_t s;
    s = instr[31:0]; // 高位对齐：取指令字顶部 32 位
    return s;
  endfunction

  // ---- S（32 位）----
  // 字段自最高位：imm[11:5]（31:25）, rs2（24:20）, rs1（19:15）, funct3（14:12）, imm[4:0]（11:7）, opcode（6:0）
  typedef struct packed {
    logic [6:0] imm_11_5;                   // [31:25]（imm[11:5]）
    logic [4:0] rs2;                        // [24:20]
    logic [4:0] rs1;                        // [19:15]
    logic [2:0] funct3;                     // [14:12]
    logic [4:0] imm_4_0;                    // [11:7]（imm[4:0]）
    logic [6:0] opcode;                     // [6:0]
  } fmt_s_t;

  // 解码：指令字低 32 位按位覆盖到结构体，如 fmt_s_t h = decode_s(instr);
  function automatic fmt_s_t decode_s(input logic [31:0] instr);
    fmt_s_t s;
    s = instr[31:0]; // 高位对齐：取指令字顶部 32 位
    return s;
  endfunction

  // ---- B（32 位）----
  // 字段自最高位：imm[12|10:5]（31:25）, rs2（24:20）, rs1（19:15）, funct3（14:12）, imm[4:1|11]（11:7）, opcode（6:0）
  typedef struct packed {
    logic [6:0] imm_12_10_5;                // [31:25]（imm[12|10:5]）
    logic [4:0] rs2;                        // [24:20]
    logic [4:0] rs1;                        // [19:15]
    logic [2:0] funct3;                     // [14:12]
    logic [4:0] imm_4_1_11;                 // [11:7]（imm[4:1|11]）
    logic [6:0] opcode;                     // [6:0]
  } fmt_b_t;

  // 解码：指令字低 32 位按位覆盖到结构体，如 fmt_b_t h = decode_b(instr);
  function automatic fmt_b_t decode_b(input logic [31:0] instr);
    fmt_b_t s;
    s = instr[31:0]; // 高位对齐：取指令字顶部 32 位
    return s;
  endfunction
endpackage
