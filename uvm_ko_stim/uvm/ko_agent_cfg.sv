class ko_agent_cfg extends uvm_object;
  bit use_tready = 0;
  `uvm_object_utils(ko_agent_cfg)
  function new(string name = "ko_agent_cfg"); super.new(name); endfunction
endclass

// 顶层仿真配置：带宽建模参数 + 接口句柄（全局握手对象，兼容 Verilator config_db 问题）
class ko_tb_config;
  virtual ko_if vif;

  // ---- 服务层 ODU（承载 fgOTN 的服务器帧，限定 ODU0/ODU1/ODU2） ----
  real otu_rate_bps      = 10.037273924e9;  // 服务层速率（默认 ODU2）
  int  otu_frame_bytes   = 15296;           // ODU0/1/2 帧均为 4×3824 字节

  // ---- fgOTN 业务参数 ----
  int  n_slots           = 119;             // fgODUflex(p) 占用服务层 fgTS 1..119（p 最大 119）
  int  oh_pos_per_frame  = 8;               // 每 fgOTN 帧 KO 数 = 4 行 × 每行 2 个开销区域
  int  n_channels        = 1;               // 业务通道数（1=单通道 p=n_slots；N=多条单时隙业务）
  int  p_per_chan        = 0;               // 每通道 fgTS 数；0=与 n_slots 相同
  bit  chan_skew         = 1;               // 多通道帧头相位：1=均匀错开（打散）；0=全部对齐（集中）
  real frame_period_us   = 0;               // fgOTN 帧周期（µs）；0=按 n_slots 从协议推导，>0 手动覆盖

  // 协议常数（ITU-T G.709.20 / G.709 Annex M/N）
  real fg_rate_bps_per_slot = 10.409203e6;  // fgODUflex(p) 每 fgTS 标称速率（bit/s）
  int  fg_frame_bytes       = 15296;        // fgOTN 帧 = 4 行 × 3824 列
  int  fg_cols              = 3824;         // fgOTN 每行列数
  int  fg_rows              = 4;            // fgOTN 行数
  int  fg_oh_bytes_per_frame = 128;         // 每帧开销字节 = 112(fgODUflex OH) + 16(fgOPUflex OH)
  int  fg_oh_per_row        = 32;           // 每行开销字节 = 列 1..16 + 列 1905..1920
  int  fg_oh_right_off      = 1904;         // 右半开销区（列 1905..1920）在行内的字节偏移

  // ---- 接口与仿真 ----
  real clk_freq_hz       = 312.5e6;         // KO 接口时钟
  int  n_frames          = 100;             // 仿真的服务层帧数
  int  jitter_pct        = 0;               // KO 发射时刻抖动 %（默认 0=字节时刻确定性；只扰动时刻）
  real rate_tolerance_pct = 25.0;           // 带宽校验容差 %
  bit  use_tready        = 0;

  // fgOTN 帧周期（µs）：T = 4×3824×8 / (p × 10.409203M)，p=n_slots
  function real fg_frame_period_us();
    if (frame_period_us > 0) return frame_period_us;
    return fg_frame_bytes * 8.0 / (n_slots * fg_rate_bps_per_slot) * 1e6;
  endfunction

  // 开销位置带宽（位置/s）= 每帧开销位置数 / fgOTN 帧周期
  function real bw_oh();
    return oh_pos_per_frame / (fg_frame_period_us() * 1e-6);
  endfunction

  // 服务层 OTN 帧周期（s）
  function real sf_period_s();
    return otu_frame_bytes * 8.0 / otu_rate_bps;
  endfunction

  // 每服务层帧 KO 数（GMP 相位穿越的长程均值）
  function real ko_per_sf();
    return bw_oh() * sf_period_s();
  endfunction

  // 每服务层帧承载的 fgOTN 字节数（有效值，含 GMP 速率适配/填充）：
  // W = fg 帧字节数 × T_sf / T_fg
  function real fg_bytes_per_sf();
    return fg_frame_bytes * sf_period_s() / (fg_frame_period_us() * 1e-6);
  endfunction

  // 单通道 fgOTN 帧周期（µs）：p 为该通道 fgTS 数
  function real chan_frame_period_us(int p);
    if (p <= 0) p = n_slots;
    return fg_frame_bytes * 8.0 / (p * fg_rate_bps_per_slot) * 1e6;
  endfunction

  // 期望 KO 总数（与序列同口径）：所有通道、所有帧、所有开销区域的字节时刻 < 仿真时长
  function int expected_ko_count();
    int p_c, n_ch, cnt;
    real t_fg_c, delta, run_s;
    p_c  = (p_per_chan > 0) ? p_per_chan : n_slots;
    n_ch = (n_channels > 0) ? n_channels : 1;
    t_fg_c = chan_frame_period_us(p_c) * 1e-6;
    delta  = chan_skew ? (t_fg_c / n_ch) : 0.0;
    run_s  = n_frames * sf_period_s();
    cnt = 0;
    for (int c = 0; c < n_ch; c++) begin
      for (int N = 0; ; N++) begin
        int added = 0;
        for (int k = 0; k < oh_pos_per_frame; k++) begin
          int off = overhead_offset(k);
          if (c * delta + (N * fg_frame_bytes + off) * t_fg_c / fg_frame_bytes < run_s) begin
            cnt++;
            added++;
          end
        end
        if (added == 0) break;
      end
    end
    return cnt;
  endfunction

  // 第 k 个开销区域在 fgOTN 帧内的字节偏移（帧扫描序）：
  // 每行 2 个开销区域：左区列 1..16（行内偏移 0）、右区列 1905..1920（行内偏移 1904）
  // k = 0..7 → 行1左/行1右/行2左/行2右/行3左/行3右/行4左/行4右
  function int overhead_offset(int k);
    int r;
    if (oh_pos_per_frame <= 0) oh_pos_per_frame = 1;
    if (k < 0) k = 0;
    if (k > 7) k = 7;
    r = k / 2;                              // 行 0..3
    overhead_offset = r * fg_cols + ((k % 2 == 0) ? 0 : fg_oh_right_off);
  endfunction

  // fgOTN 帧内字节偏移 →（行,列）：标准 4×3824 帧，行主序
  function void fg_byte_to_rc(int off, output int fg_row, output int fg_col);
    if (off < 0) off = 0;
    if (off > fg_frame_bytes - 1) off = fg_frame_bytes - 1;
    fg_row = off / fg_cols + 1;      // 1..4
    fg_col = off % fg_cols + 1;      // 1..3824
  endfunction

  // 服务层帧内比例（0..1）→（行,列）：OTN 帧 4×4080，fgTS 位于净荷列 17..3824
  function void sf_frac_to_rc(real frac, output int sf_row, output int sf_col);
    real rowf, colf;
    if (frac < 0.0) frac = 0.0;
    if (frac > 1.0) frac = 1.0;
    rowf  = frac * 4.0;
    sf_row = $rtoi(rowf) + 1;
    if (sf_row > 4) sf_row = 4;
    colf  = (rowf - (sf_row - 1)) * 3808.0;   // 净荷区 3808 列
    sf_col = 17 + $rtoi(colf);
    if (sf_col > 3824) sf_col = 3824;
  endfunction
endclass
