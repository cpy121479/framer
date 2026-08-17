class ko_scoreboard extends uvm_scoreboard;
  uvm_analysis_imp #(ko_item, ko_scoreboard) ap_imp;

  int ko_count = 0;
  `uvm_component_utils(ko_scoreboard)

  function new(string name = "ko_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    ap_imp = new("ap_imp", this);
  endfunction

  function void write(ko_item it);
    // 结构合法性：unpack 后 SN 必须落在 13bit 范围（解析正确的标志）
    if (it.sn >= 8192)
      `uvm_error("SCB", $sformatf("SN 超范围：%0d", it.sn))
    // 旁路行列号范围检查（服务层 4×4080 净荷区 / fgOTN 4×3824 开销区）
    if (it.sf_vld) begin
      if (it.sf_row < 1 || it.sf_row > 4)
        `uvm_error("SCB", $sformatf("服务层行号超范围：%0d", it.sf_row))
      if (it.sf_col < 17 || it.sf_col > 3824)
        `uvm_error("SCB", $sformatf("服务层列号超范围：%0d（应 17..3824）", it.sf_col))
      if (it.sf_frame_idx < 0)
        `uvm_error("SCB", $sformatf("服务层帧号非法：%0d", it.sf_frame_idx))
    end
    if (it.fg_vld) begin
      if (it.fg_row < 1 || it.fg_row > 4)
        `uvm_error("SCB", $sformatf("fgOTN 行号超范围：%0d", it.fg_row))
      if (!((it.fg_col >= 1 && it.fg_col <= 16) ||
            (it.fg_col >= 1905 && it.fg_col <= 1920)))
        `uvm_error("SCB", $sformatf("fgOTN 列号超范围：%0d（应 1..16 或 1905..1920）", it.fg_col))
      if (it.fg_frame_idx < 0)
        `uvm_error("SCB", $sformatf("fgOTN 帧号非法：%0d", it.fg_frame_idx))
    end
    ko_count++;
  endfunction

  function void check_phase(uvm_phase phase);
    real measured, expected_rate, err_pct;
    int expected;
    if (ko_count == 0) begin
      `uvm_error("SCB", "未收到任何 KO")
      return;
    end
    if (ko_count < 2) begin
      `uvm_info("SCB", $sformatf("KO 样本不足（仅 %0d 条），跳过速率校验", ko_count), UVM_MEDIUM)
      return;
    end
    // 期望 KO 总数（与序列同口径：所有通道、所有帧、所有开销区域的字节时刻 < 运行时长）
    expected = ko_pkg::g_tb_cfg.expected_ko_count();
    err_pct = 100.0 * (ko_count - expected) / expected;
    if (err_pct < 0) err_pct = -err_pct;
    // 实测速率：KO 数 / 运行时长（n_frames × T_sf）
    measured     = ko_count / (ko_pkg::g_tb_cfg.n_frames * ko_pkg::g_tb_cfg.sf_period_s());
    expected_rate = ko_pkg::g_tb_cfg.expected_ko_count() /
                    (ko_pkg::g_tb_cfg.n_frames * ko_pkg::g_tb_cfg.sf_period_s());
    `uvm_info("SCB", $sformatf("KO=%0d 期望KO=%0d 数量误差=%.2f%% 实测速率=%.3e KO/s 期望速率=%.3e KO/s",
             ko_count, expected, err_pct, measured, expected_rate), UVM_LOW)
    if (err_pct > ko_pkg::g_tb_cfg.rate_tolerance_pct)
      `uvm_error("SCB", $sformatf("KO 数量超出容差：误差 %.2f%% > %.1f%%（KO=%0d 期望=%0d）",
                 err_pct, ko_pkg::g_tb_cfg.rate_tolerance_pct, ko_count, expected))
  endfunction
endclass
