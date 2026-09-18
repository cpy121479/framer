// ============================================================
// 示例混合指令集 v0.1 —— 公共包：XLEN 与内建函数
// 由 ISA Studio 自动生成（指令函数与 ALU 依赖本包；内建函数来自指令集定义）
// ============================================================
package isa_pkg;
  parameter int XLEN = 32; // 数据通路位宽（ISA 设置）
  parameter int IW = 32; // 指令字位宽（本分组最长指令；短指令高位对齐、低位补 0）

  // sext —— 符号扩展：低 w 位按符号扩展到 XLEN
  // 指令语义中可直接调用：isa_pkg::sext(...)（isa_instr_pkg 已 import isa_pkg::*）
  function automatic logic [XLEN-1:0] sext(
    input logic [31:0] v,
    input int unsigned w
  );
    logic [XLEN-1:0] result = {XLEN{1'b0}}; // 语义中对 result 赋值即返回值；也可提前 return
    // ---- 语义（SystemVerilog 原文）----
    logic [XLEN-1:0] m;
    integer i;
    m = {XLEN{1'b0}};
    for (i = 0; i < w; i = i + 1) m[i] = 1'b1;
    result = (v & m) | (v[w-1] ? ~m : {XLEN{1'b0}});
    // ---- 语义结束 ----
    return result;
  endfunction

  // satadd —— 饱和加法：无符号上溢时饱和到最大值
  // 指令语义中可直接调用：isa_pkg::satadd(...)（isa_instr_pkg 已 import isa_pkg::*）
  function automatic logic [XLEN-1:0] satadd(
    input logic [31:0] a,
    input logic [31:0] b
  );
    logic [XLEN-1:0] result = {XLEN{1'b0}}; // 语义中对 result 赋值即返回值；也可提前 return
    // ---- 语义（SystemVerilog 原文）----
    logic [XLEN-1:0] s = a + b;
    result = (s < a) ? {XLEN{1'b1}} : s; // s < a 即发生上溢
    // ---- 语义结束 ----
    return result;
  endfunction

  // neg —— 最高位是否为 1（有符号数为负）
  // 指令语义中可直接调用：isa_pkg::neg(...)（isa_instr_pkg 已 import isa_pkg::*）
  function automatic logic neg(
    input logic [31:0] v
  );
    logic result = 1'b0; // 语义中对 result 赋值即返回值；也可提前 return
    // ---- 语义（SystemVerilog 原文）----
    result = v[XLEN-1];
    // ---- 语义结束 ----
    return result;
  endfunction

  // clz —— 前导零计数（返回 int）
  // 指令语义中可直接调用：isa_pkg::clz(...)（isa_instr_pkg 已 import isa_pkg::*）
  function automatic int unsigned clz(
    input logic [31:0] v
  );
    int unsigned result = 0; // 语义中对 result 赋值即返回值；也可提前 return
    // ---- 语义（SystemVerilog 原文）----
    integer i;
    logic done;
    done = 1'b0;
    result = 0;
    for (i = XLEN-1; i >= 0; i = i - 1) begin
      if (!done) begin
        if (v[i]) done = 1'b1;
        else result = result + 1;
      end
    end
    // ---- 语义结束 ----
    return result;
  endfunction
endpackage
