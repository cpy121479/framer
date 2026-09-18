// ============================================================
// 示例混合指令集 v0.1 —— 指令行为函数包
// 由 ISA Studio 自动生成：语义即 SystemVerilog，原文嵌入。
// 每条（子）指令一个函数：接口 = 指令字 / pc / 寄存器操作数值 / 立即数 /
// 读 CSR 值 → result（写 CSR 经 <函数名>_out_t 结构体返回）；
// 有子指令的指令只生成子指令函数（继承其 CSR 配置），无语义的留白 // TODO。
// 语义中可直接调用 isa_formats_pkg::decode_<格式>(instr) 与 isa_enums_pkg 枚举。
// ============================================================
package isa_instr_pkg;
  import isa_pkg::*;

  // ============================================================
  // 指令行为函数：LUI —— 将立即数装载到 dst 高 20 位，低 12 位清零
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：U（32 位）｜分组：基础整数
  // 语法：lui dst, imm
  // 译码：opcode=0110111｜掩码 32'h0000_007F｜值 32'h0000_0037
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } LUI_out_t;
  function automatic LUI_out_t LUI(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc // 程序计数器
  );
    LUI_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_u_t f = isa_formats_pkg::decode_u(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = {f.imm_31_12, 12'b0};
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：AUIPC —— rd = pc + 高 20 位立即数
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：U（32 位）｜分组：基础整数
  // 语法：auipc dst, imm
  // 译码：opcode=0010111｜掩码 32'h0000_007F｜值 32'h0000_0017
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } AUIPC_out_t;
  function automatic AUIPC_out_t AUIPC(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc // 程序计数器
  );
    AUIPC_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_u_t f = isa_formats_pkg::decode_u(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = pc + {f.imm_31_12, 12'b0};
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：JAL —— 无条件跳转并链接，返回地址写入 rd
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：J（32 位）｜分组：基础整数
  // 语法：jal dst, offset
  // 译码：opcode=1101111｜掩码 32'h0000_007F｜值 32'h0000_006F
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } JAL_out_t;
  function automatic JAL_out_t JAL(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc // 程序计数器
  );
    JAL_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_j_t f = isa_formats_pkg::decode_j(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = pc + 32'd4; // 返回链接；跳转目标 = pc + J 型散列立即数（f.imm_20_10_1_11_19_12 需重排）
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：JALR —— 寄存器间接跳转并链接
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：I（32 位）｜分组：基础整数
  // 语法：jalr dst, offset(rs1)
  // 译码：opcode=1100111, funct3=000｜掩码 32'h0000_707F｜值 32'h0000_0067
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } JALR_out_t;
  function automatic JALR_out_t JALR(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1 // x[rs1] 读值
  );
    JALR_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_i_t f = isa_formats_pkg::decode_i(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = pc + 32'd4; // 跳转目标 = (rs1 + isa_pkg::sext(f.imm_11_0, 12)) & ~1
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：ADDI —— 寄存器加符号扩展立即数
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：I（32 位）｜分组：基础整数
  // 语法：addi dst, rs1, imm
  // 译码：opcode=0010011, funct3=000｜掩码 32'h0000_707F｜值 32'h0000_0013
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } ADDI_out_t;
  function automatic ADDI_out_t ADDI(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1 // x[rs1] 读值
  );
    ADDI_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_i_t f = isa_formats_pkg::decode_i(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = rs1 + isa_pkg::sext(f.imm_11_0, 12);
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：LW —— 从内存加载 32 位字到 rd
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：I（32 位）｜分组：基础整数
  // 语法：lw dst, offset(rs1)
  // 译码：opcode=0000011, funct3=010｜掩码 32'h0000_707F｜值 32'h0000_2003
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } LW_out_t;
  function automatic LW_out_t LW(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1 // x[rs1] 读值
  );
    LW_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_i_t f = isa_formats_pkg::decode_i(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = rs1 + isa_pkg::sext(f.imm_11_0, 12); // Load 地址（数据经访存通道返回）
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：ADD —— 寄存器加法
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：R（32 位）｜分组：基础整数
  // 语法：add dst, rs1, rs2
  // 译码：opcode=0110011, funct3=000, funct7=0000000｜掩码 32'hFE00_707F｜值 32'h0000_0033
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } ADD_out_t;
  function automatic ADD_out_t ADD(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1, // x[rs1] 读值
    input logic [XLEN-1:0] rs2 // x[rs2] 读值
  );
    ADD_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_r_t f = isa_formats_pkg::decode_r(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = rs1 + rs2;
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：SUB —— 寄存器减法
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：R（32 位）｜分组：基础整数
  // 语法：sub dst, rs1, rs2
  // 译码：opcode=0110011, funct3=000, funct7=0100000｜掩码 32'hFE00_707F｜值 32'h4000_0033
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } SUB_out_t;
  function automatic SUB_out_t SUB(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1, // x[rs1] 读值
    input logic [XLEN-1:0] rs2 // x[rs2] 读值
  );
    SUB_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_r_t f = isa_formats_pkg::decode_r(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = rs1 - rs2;
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：SLL —— 逻辑左移
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：R（32 位）｜分组：基础整数
  // 语法：sll dst, rs1, rs2
  // 译码：opcode=0110011, funct3=001, funct7=0000000｜掩码 32'hFE00_707F｜值 32'h0000_1033
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } SLL_out_t;
  function automatic SLL_out_t SLL(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1, // x[rs1] 读值
    input logic [XLEN-1:0] rs2 // x[rs2] 读值
  );
    SLL_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_r_t f = isa_formats_pkg::decode_r(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = rs1 << rs2[4:0];
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：SW —— 将 rs2 存入内存
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：S（32 位）｜分组：基础整数
  // 语法：sw rs2, offset(rs1)
  // 译码：opcode=0100011, funct3=010｜掩码 32'h0000_707F｜值 32'h0000_2023
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → （无输出）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  function automatic void SW(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1, // x[rs1] 读值
    input logic [XLEN-1:0] rs2 // x[rs2] 读值
  );
    isa_formats_pkg::fmt_s_t f = isa_formats_pkg::decode_s(instr); // f.<字段名> 取字段
    // ---- 语义（SystemVerilog 原文）----
    // Store：地址 = rs1 + {f.imm_11_5, f.imm_4_0}，写数据 = rs2（访存由调用方处理；本指令无 dst）
    // ---- 语义结束 ----
  endfunction

  // ============================================================
  // 指令行为函数：BEQ —— 相等则分支跳转
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：B（32 位）｜分组：基础整数
  // 语法：beq rs1, rs2, offset
  // 译码：opcode=1100011, funct3=000｜掩码 32'h0000_707F｜值 32'h0000_0063
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → （无输出）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  function automatic void BEQ(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1, // x[rs1] 读值
    input logic [XLEN-1:0] rs2 // x[rs2] 读值
  );
    isa_formats_pkg::fmt_b_t f = isa_formats_pkg::decode_b(instr); // f.<字段名> 取字段
    // ---- 语义（SystemVerilog 原文）----
    // 相等则跳转：rs1 == rs2 时目标 = pc + isa_pkg::sext({f.imm_12_10_5, f.imm_4_1_11}, 12)（散列位序需手工重排；本指令无 dst）
    // ---- 语义结束 ----
  endfunction

  // ============================================================
  // 指令行为函数：CSRRW —— 读旧值写入 rd，rs1 写入 CSR（示例访问 mstatus）
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：I（32 位）｜分组：基础整数
  // 语法：csrrw dst, csr, rs1
  // 译码：opcode=1110011, funct3=001｜掩码 32'h0000_707F｜值 32'h0000_1073
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能） + 写 CSR 值；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写） + 写 CSR 值
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
    logic [31:0] mstatus_w; // 写 mstatus（读写）
  } CSRRW_out_t;
  function automatic CSRRW_out_t CSRRW(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1, // x[rs1] 读值
    input logic [31:0] mstatus // CSR 读：mstatus（读写）
  );
    CSRRW_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_i_t f = isa_formats_pkg::decode_i(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    logic [31:0] mstatus_w = {32{1'b0}}; // 语义中对其赋值 = 写 mstatus
    // ---- 语义（SystemVerilog 原文）----
    dst = mstatus; // 旧值写入 dst
    mstatus_w = rs1;   // rs1 作为新值写回 CSR
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    ret.mstatus_w = mstatus_w;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：CSRR —— 读只读 CSR 到 rd（示例读 mcycle）
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：I（32 位）｜分组：基础整数
  // 语法：csrr dst, csr
  // 译码：opcode=1110011, funct3=010｜掩码 32'h0000_707F｜值 32'h0000_2073
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } CSRR_out_t;
  function automatic CSRR_out_t CSRR(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1, // x[rs1] 读值
    input logic [31:0] mcycle // CSR 读：mcycle（只读）
  );
    CSRR_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_i_t f = isa_formats_pkg::decode_i(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    dst = mcycle; // 读取周期计数器
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction

  // ============================================================
  // 指令行为函数：ECALL —— 环境调用请求（真实保留字段示例：高 12 位 zero 恒为 0，灰色显示）
  // 语义即 SystemVerilog，原文嵌入；
  // 格式：I0（32 位）｜分组：基础整数
  // 语法：ecall
  // 译码：opcode=1110011, dst=00000, funct3=000, rs1=00000, zero=000000000000｜掩码 32'hFFFF_FFFF｜值 32'h0000_0073
  // 接口：指令字 / pc / 寄存器操作数值 / 读 CSR 值 → dst + dst_mask（按位写使能）；
  //       立即数等字段不作输入：语义经 f（格式结构体）从指令字内部识别
  // ============================================================
  // 函数返回：dst + dst_mask（按位写使能，全 1 = 全写）
  //       语义中对 dst / dst_mask / <CSR 名>_w 赋值
  typedef struct packed {
    logic [XLEN-1:0] dst;
    logic [XLEN-1:0] dst_mask; // 按位写使能：0 = 该位不写入，默认全 1
  } ECALL_out_t;
  function automatic ECALL_out_t ECALL(
    input logic [31:0]     instr, // 指令字（字段经格式结构体内部识别）
    input logic [XLEN-1:0] pc, // 程序计数器
    input logic [XLEN-1:0] rs1 // x[rs1] 读值
  );
    ECALL_out_t ret; // 返回值（函数尾部装配）
    isa_formats_pkg::fmt_i0_t f = isa_formats_pkg::decode_i0(instr); // f.<字段名> 取字段
    logic [XLEN-1:0] dst = {XLEN{1'b0}}; // 语义中对 dst 赋值即输出；也可提前 return
    logic [XLEN-1:0] dst_mask = {XLEN{1'b1}}; // 按位写使能，默认全 1；部分写指令按需清位
    // ---- 语义（SystemVerilog 原文）----
    // 触发环境调用异常（dst 保持 0）
    // ---- 语义结束 ----
    ret.dst = dst;
    ret.dst_mask = dst_mask;
    return ret;
  endfunction
endpackage
