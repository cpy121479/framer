// ko_if：KO 指令接口（1bit vld + 48 字节 KO 总线 + 可选反压 tready）
interface ko_if(input logic clk, input logic rst_n);
  logic        vld;
  logic [383:0] ko_data;   // 48B = 384bit
  logic        tready;     // KOIU 反压（简化；可配置开关）
  logic [6:0]  ko_chan_id; // 业务通道号（多通道对比用；单通道恒 0）

  // 旁路观测：KO 对应的服务层 OTN 帧位置（4×4080，fgTS 位于净荷列 17..3824）
  logic        sf_vld;
  logic [2:0]  sf_row;
  logic [11:0] sf_col;
  logic [15:0] sf_frame_idx;   // 服务层帧号（全局位置 = 帧号×16320 + 帧内偏移，严格递增）
  // 旁路观测：KO 对应的 fgOTN 帧开销位置（4×3824，开销列 1..16 / 1905..1920）
  logic        fg_vld;
  logic [2:0]  fg_row;
  logic [11:0] fg_col;
  logic [15:0] fg_frame_idx;   // fgOTN 帧号

  clocking cb @(posedge clk);
    default input #1step output #1;
    output vld, ko_data, ko_chan_id;
    output sf_vld, sf_row, sf_col, sf_frame_idx, fg_vld, fg_row, fg_col, fg_frame_idx;
    input  tready;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input vld, ko_data, ko_chan_id, tready, sf_vld, sf_row, sf_col, sf_frame_idx,
          fg_vld, fg_row, fg_col, fg_frame_idx;
  endclocking
endinterface
