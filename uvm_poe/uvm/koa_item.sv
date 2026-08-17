// KO 报文四种模板（48B = 6×8B）
typedef enum {KO_OVERHEAD, KO_IO, KO_CTRL, KO_DMA} ko_tmpl_t;
// 7 条 KO 输入流
typedef enum {
  ST_OH_EXT,     // fgOTN 开销提取（pri=7）
  ST_OH_INS,     // fgOTN 开销下插（pri=带宽）
  ST_APS_EXT,    // X2X APS 提取（pri=带宽）
  ST_APS_INS,    // X2X APS 下插（pri=带宽）
  ST_ALM,        // X2X ALM（pri=带宽）
  ST_UART_EXT,   // 串口提取（pri=7）
  ST_UART_INS    // 串口下插（pri=随机）
} koa_stream_t;

// KOA 输入/输出 KO 事务：48B 报文（四种模板）+ 3bit 调度优先级（0 最高）+ 流/平面
// 48B 布局：行1 公共表头 DA|DP|SA|SP|TYPE|PRI+SN|B/E/LBO(CHN)（PRI 3bit、SN 13bit）
//          行2 POE_HEAD|MEM_HEAD（公共）
//          行3-6 按模板：开销=开销头+META；IO=全 META；控制=控制头+RES；DMA=DMA META+RES
class koa_item extends uvm_sequence_item;
  rand bit [2:0]   pri;          // 调度优先级（写入报文行1 PRI）
  rand ko_tmpl_t   tmpl;
  rand bit [7:0]   da, dp, sa, sp, type_f;
  rand bit [12:0]  sn;
  rand bit [7:0]   boe_lbo;
  rand bit [31:0]  poe_head, mem_head;
  rand bit [63:0]  row3, row4, row5, row6;   // 行 3-6 负载
  bit [383:0]      ko_data;     // pack() 生成的 48B
  koa_stream_t     stream;      // 输入流（输出事件由 out_src 映射）
  int              plane;       // 平面号（串口恒 0）
  bit [16:0]       cid;         // 通道号（1 时隙粒度；串口恒 0）
  bit [2:0]        pos;         // 该流内开销位置序号（串口恒 0）
  int              sbuf;        // SBUF 编号：0=EXT 1=INS 2=ALM 3=UART_EXT 4=UART_INS
  longint          ev_time;     // 事件上报时间戳（check_phase 排序用）
  bit              is_out;      // 1=输出事件，0=输入事件

  `uvm_object_utils_begin(koa_item)
    `uvm_field_int(pri, UVM_ALL_ON)
    `uvm_field_enum(ko_tmpl_t, tmpl, UVM_ALL_ON)
    `uvm_field_enum(koa_stream_t, stream, UVM_ALL_ON)
    `uvm_field_int(cid, UVM_ALL_ON)
    `uvm_field_int(pos, UVM_ALL_ON)
    `uvm_field_int(sbuf, UVM_ALL_ON)
    `uvm_field_int(ko_data, UVM_ALL_ON)
    `uvm_field_int(plane, UVM_ALL_ON)
    `uvm_field_int(ev_time, UVM_ALL_ON)
    `uvm_field_int(is_out, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "koa_item");
    super.new(name);
  endfunction

  // 按模板随机填充报文字段（直接用 $urandom，Verilator 约束求解不可靠）
  function void randomize_payload(ko_tmpl_t t);
    tmpl    = t;
    pri     = $urandom % 8;
    da      = $urandom;
    dp      = $urandom;
    sa      = $urandom;
    sp      = $urandom;
    type_f  = $urandom;
    sn      = $urandom % 8192;
    boe_lbo = $urandom;
    poe_head = $urandom;
    mem_head = $urandom;
    case (t)
      KO_CTRL: begin
        row3 = $urandom;              // 控制头 8B
        row4 = 0; row5 = 0; row6 = 0; // RES
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
        row3 = $urandom; row4 = $urandom;    // KO_IO：全 META
        row5 = $urandom; row6 = $urandom;
      end
    endcase
  endfunction

  // 打包为 48B（384bit）
  function bit [383:0] pack();
    bit [63:0] row0, row1;
    row0 = {da, dp, sa, sp, type_f, {pri, sn[12:8]}, sn[7:0], boe_lbo};
    row1 = {poe_head, mem_head};
    pack = {row0, row1, row3, row4, row5, row6};
  endfunction
endclass
