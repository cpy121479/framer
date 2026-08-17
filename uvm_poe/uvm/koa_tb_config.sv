// 顶层仿真配置（全局握手对象，兼容 Verilator config_db 问题）
class koa_tb_config;
  virtual koa_if vif;

  // 时钟与运行
  real clk_freq_hz = 1e9;        // 1 GHz
  real run_us      = 200;        // 激励产生窗口（µs）

  // fgOTN：OH_EXT / OH_INS，各 4 平面；每平面通道时隙表（各通道时隙可不同，总和 ≤ 9520）
  int  n_oh_planes        = 4;
  int  n_ch_per_plane     = 8;   // 每平面最大通道数（实际通道数随机 1..N；全单时隙最大 9520）
  int  oh_slots_total     = 9520; // 每平面总时隙（随机拆给各通道，如 1+1+9518）
  bit  oh_plane_skew      = 1;

  // X2X：APS_EXT / APS_INS / ALM，各 8 平面；每平面 N_CH 通道
  int  n_x2x_planes        = 8;
  int  x2x_slots_total     = 9520;
  bit  x2x_plane_skew      = 1;

  // 串口：UART_EXT / UART_INS，各 ≤60 Mpps
  real uart_mpps = 60.0;

  // ---- 反压统计（monitor 更新，scoreboard 报告）----
  // 流顺序：0=OH_EXT 1=OH_INS 2=APS_EXT 3=APS_INS 4=ALM 5=UART_EXT 6=UART_INS
  int  bp_clks[7];    // 每流被反压拍数（vld 有效但 rdy=0）
  int  bp_events[7];  // 每流反压事件数（连续反压段计数）
  bit  bp_prev[7];    // 上一拍该流是否处于反压

  // ---- 速率（Mpps） ----
  // fgOTN 每平面每帧 8 KO；帧周期 T_fg = 122368/(slots×10.409203e6)
  function real oh_rate_mpps();
    if (oh_slots_total <= 0) oh_slots_total = 1;
    return n_oh_planes * 8.0 * oh_slots_total * 10.409203e6 / 122368.0 / 1e6;
  endfunction
  // X2X：APS 每帧 1 KO、ALM 每帧 4 KO（合计每帧 6 KO）
  function real x2x_aps_rate_mpps();
    if (x2x_slots_total <= 0) x2x_slots_total = 1;
    return n_x2x_planes * 1.0 * x2x_slots_total * 10.409203e6 / 122368.0 / 1e6;
  endfunction
  function real x2x_alm_rate_mpps();
    if (x2x_slots_total <= 0) x2x_slots_total = 1;
    return n_x2x_planes * 4.0 * x2x_slots_total * 10.409203e6 / 122368.0 / 1e6;
  endfunction

  // 帧周期（s）
  function real oh_frame_period_s();
    return 122368.0 / (oh_slots_total * 10.409203e6);
  endfunction
  function real x2x_frame_period_s();
    return 122368.0 / (x2x_slots_total * 10.409203e6);
  endfunction
endclass
