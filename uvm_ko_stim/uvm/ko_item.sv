typedef enum {KO_OVERHEAD, KO_IO, KO_CTRL, KO_DMA} ko_tmpl_t;

// KO 指令事务：48B（6×8B），字段按行 1 公共表头 + 行 2 POE/MEM + 行 3-6 模板负载
class ko_item extends uvm_sequence_item;
  rand bit [7:0]  da;
  rand bit [7:0]  dp;
  rand bit [7:0]  sa;
  rand bit [7:0]  sp;
  rand bit [7:0]  type_f;    // TYPE
  rand bit [2:0]  pri;       // PRI 3bit
  rand bit [12:0] sn;        // SN 13bit
  rand bit [7:0]  boe_lbo;   // B/E/LBO(CHN)
  rand bit [31:0] poe_head;
  rand bit [31:0] mem_head;
  rand ko_tmpl_t  tmpl;
  rand bit [63:0] row3, row4, row5, row6;   // 行 3-6 负载（按模板解释）

  // 旁路定位信息（非 KO 报文内容，仅用于波形/日志核对）
  bit        sf_vld;
  int        sf_row, sf_col;      // 服务层 OTN 帧位置（1..4，17..3824）
  bit        fg_vld;
  int        fg_row, fg_col;      // fgOTN 帧开销位置（1..4，1..16/1905..1920）
  int        fg_pos_idx;          // fgOTN 帧内开销位置序号（0..oh_pos_per_frame-1）
  int        sf_frame_idx;        // 服务层帧序号
  int        fg_frame_idx;        // fgOTN 帧序号
  int        chan_id;             // 业务通道号（多通道；单通道恒 0）

  `uvm_object_utils_begin(ko_item)
    `uvm_field_enum(ko_tmpl_t, tmpl, UVM_ALL_ON)
    `uvm_field_int(da, UVM_ALL_ON)
    `uvm_field_int(dp, UVM_ALL_ON)
    `uvm_field_int(sa, UVM_ALL_ON)
    `uvm_field_int(sp, UVM_ALL_ON)
    `uvm_field_int(type_f, UVM_ALL_ON)
    `uvm_field_int(pri, UVM_ALL_ON)
    `uvm_field_int(sn, UVM_ALL_ON)
    `uvm_field_int(boe_lbo, UVM_ALL_ON)
    `uvm_field_int(poe_head, UVM_ALL_ON)
    `uvm_field_int(mem_head, UVM_ALL_ON)
    `uvm_field_int(sf_vld, UVM_ALL_ON)
    `uvm_field_int(sf_row, UVM_ALL_ON)
    `uvm_field_int(sf_col, UVM_ALL_ON)
    `uvm_field_int(fg_vld, UVM_ALL_ON)
    `uvm_field_int(fg_row, UVM_ALL_ON)
    `uvm_field_int(fg_col, UVM_ALL_ON)
    `uvm_field_int(fg_pos_idx, UVM_ALL_ON)
    `uvm_field_int(sf_frame_idx, UVM_ALL_ON)
    `uvm_field_int(fg_frame_idx, UVM_ALL_ON)
    `uvm_field_int(chan_id, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "ko_item");
    super.new(name);
  endfunction

  // 打包为 48B（384bit）：行0 表头 8B + 行1 POE/MEM 8B + 行2-5 负载 32B
  function bit [383:0] pack();
    bit [63:0] row0, row1;
    row0 = {da, dp, sa, sp, type_f, {pri, sn[12:8]}, sn[7:0], boe_lbo};
    row1 = {poe_head, mem_head};
    pack = {row0, row1, row3, row4, row5, row6};
  endfunction

  // 解析 48B 载荷回字段（monitor/scoreboard 使用）
  function void unpack(bit [383:0] data);
    bit [63:0] row0, row1;
    {row0, row1, row3, row4, row5, row6} = data;
    da      = row0[63:56];
    dp      = row0[55:48];
    sa      = row0[47:40];
    sp      = row0[39:32];
    type_f  = row0[31:24];
    pri     = row0[23:21];
    sn      = {row0[20:16], row0[15:8]};
    boe_lbo = row0[7:0];
    {poe_head, mem_head} = row1;
  endfunction

  // 填充随机载荷：直接用 $urandom（Verilator 的 randomize() 不支持约束求解）
  function void randomize_payload();
    da      = $urandom;
    dp      = $urandom;
    sa      = $urandom;
    sp      = $urandom;
    type_f  = $urandom;
    pri     = $urandom % 8;
    sn      = $urandom % 8192;
    boe_lbo = $urandom;
    poe_head = $urandom;
    mem_head = $urandom;
    tmpl = ko_tmpl_t'($urandom % 4);
    case (tmpl)
      KO_CTRL: begin
        row3 = $urandom;   // 控制头
        row4 = 0; row5 = 0; row6 = 0;   // RES
      end
      KO_DMA: begin
        row3 = $urandom; row4 = $urandom;  // DMA META
        row5 = 0; row6 = 0;                // RES
      end
      KO_OVERHEAD: begin
        row3 = $urandom;                     // 开销头 8B
        row4 = {$urandom, $urandom};         // 高 4B=开销头，低 4B=META
        row5 = $urandom; row6 = $urandom;    // META
      end
      default: begin
        row3 = $urandom; row4 = $urandom; row5 = $urandom; row6 = $urandom;  // META
      end
    endcase
  endfunction
endclass
