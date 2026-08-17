//----------------------------------------------------------------------------
// fgotn_if.sv - fgODUflex 帧字节流接口
//   tvalid/tready 握手传输，每拍 1 字节；
//   tstart 在帧首字节（FAS0 第 1 字节）所在拍拉高；
//   tend   在帧尾字节（第 3824 列最后一行）所在拍拉高。
// 一帧固定 4 行 x 3824 列 = 15296 字节。
//----------------------------------------------------------------------------
interface fgotn_if(input logic clk, input logic rst_n);

  logic [7:0] tdata;
  logic       tvalid;
  logic       tready;
  logic       tstart;
  logic       tend;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;             // 输出沿后 #1 生效，避免与 DUT 时序竞争
    output tdata, tvalid, tstart, tend;
    input  tready;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;                       // 沿前一个时间步采样，读到稳定值
    input tdata, tvalid, tstart, tend, tready;
  endclocking

  modport drv(clocking drv_cb);
  modport mon(clocking mon_cb);

endinterface
