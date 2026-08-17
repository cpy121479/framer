// KO 带宽激励序列（字节序 GMP 映射 + 多通道）：
// - 每 fgOTN 帧 8 个开销区域（4 行 × 每行左/右 2 区），每区域一条 48B KO
// - 字节时刻：第 g 个 fgOTN 字节的时刻 t = g × T_fg / 15296；T_fg 按通道 p 推导
// - 单通道：n_channels=1，p=n_slots（如 119 时隙单业务）
// - 多通道：n_channels=N（如 119 条单时隙业务，p_per_chan=1），
//   各通道帧起始相位均匀错开 delta = T_fg / n_channels（帧头打散）
// - 所有通道的 KO 事件按时间排序后依次发射；vld 与开销区域位置对应
// - 旁路：服务层（行,列,帧号）+ fgOTN（行,列,帧号）+ 通道号
class ko_bandwidth_seq extends uvm_sequence #(ko_item);
  `uvm_object_utils(ko_bandwidth_seq)

  function new(string name = "ko_bandwidth_seq");
    super.new(name);
  endfunction

  task body();
    ko_tb_config cfg;
    real sf_period_s, sf_interval_clks, run_s;
    real t_fg_c, delta, cursor;
    int  n_ch, p_c, n_ev;

    real t_arr[];
    int  chan_arr[], k_arr[], nfg_arr[], off_arr[];

    cfg = ko_pkg::g_tb_cfg;
    while (!ko_pkg::g_reset_done) @(posedge cfg.vif.clk);

    sf_period_s      = cfg.otu_frame_bytes * 8.0 / cfg.otu_rate_bps;
    sf_interval_clks = sf_period_s * cfg.clk_freq_hz;
    run_s            = cfg.n_frames * sf_period_s;
    n_ch             = (cfg.n_channels > 0) ? cfg.n_channels : 1;
    p_c              = (cfg.p_per_chan > 0) ? cfg.p_per_chan : cfg.n_slots;
    t_fg_c           = cfg.chan_frame_period_us(p_c) * 1e-6;
    delta            = cfg.chan_skew ? (t_fg_c / n_ch) : 0.0;   // 帧头错开/集中
    cursor           = 0.0;
    n_ev             = 0;

    `uvm_info("SEQ", $sformatf("通道: %0d 路 × p=%0d（帧周期=%.2f us），帧头相位%s %.2f us",
             n_ch, p_c, t_fg_c*1e6,
             cfg.chan_skew ? "错开" : "集中", delta*1e6), UVM_LOW)
    `uvm_info("SEQ", $sformatf("服务层: ODU 帧周期=%.3f us（%.1f clk），运行时长=%.3f us",
             sf_period_s*1e6, sf_interval_clks, run_s*1e6), UVM_LOW)

    // ---- 收集所有通道的 KO 事件（通道 c 帧 N 区域 k，字节时刻 + 通道相位） ----
    for (int c = 0; c < n_ch; c++) begin
      for (int N = 0; ; N++) begin
        int added = 0;
        for (int k = 0; k < cfg.oh_pos_per_frame; k++) begin
          int off = cfg.overhead_offset(k);
          real t = c * delta + (N * cfg.fg_frame_bytes + off) * t_fg_c / cfg.fg_frame_bytes;
          if (t >= run_s) break;
          t_arr  = new[t_arr.size() + 1](t_arr);
          chan_arr = new[chan_arr.size() + 1](chan_arr);
          k_arr    = new[k_arr.size() + 1](k_arr);
          nfg_arr  = new[nfg_arr.size() + 1](nfg_arr);
          off_arr  = new[off_arr.size() + 1](off_arr);
          t_arr[t_arr.size()-1]   = t;
          chan_arr[chan_arr.size()-1] = c;
          k_arr[k_arr.size()-1]       = k;
          nfg_arr[nfg_arr.size()-1]   = N;
          off_arr[off_arr.size()-1]   = off;
          added++;
        end
        if (added == 0) break;
      end
    end
    n_ev = t_arr.size();

    // ---- 按字节时刻排序（插入排序，事件量小） ----
    for (int i = 1; i < n_ev; i++) begin
      real tv = t_arr[i];
      int cv = chan_arr[i], kv = k_arr[i], nv = nfg_arr[i], ov = off_arr[i];
      int j = i - 1;
      while (j >= 0 && t_arr[j] > tv) begin
        t_arr[j+1]   = t_arr[j];
        chan_arr[j+1] = chan_arr[j];
        k_arr[j+1]    = k_arr[j];
        nfg_arr[j+1]  = nfg_arr[j];
        off_arr[j+1]  = off_arr[j];
        j--;
      end
      t_arr[j+1]   = tv;
      chan_arr[j+1] = cv;
      k_arr[j+1]    = kv;
      nfg_arr[j+1]  = nv;
      off_arr[j+1]  = ov;
    end
    `uvm_info("SEQ", $sformatf("共 %0d 条 KO，期望 %0d 条（总 KO 速率=%.3e 条/s）",
             n_ev, cfg.expected_ko_count(),
             n_ch * cfg.oh_pos_per_frame / t_fg_c), UVM_LOW)

    // ---- 按序发射 ----
    for (int i = 0; i < n_ev; i++) begin
      real t_clks;
      real frac;
      int  sf_idx, fg_row, fg_col, sf_row, sf_col;
      t_clks = t_arr[i] * cfg.clk_freq_hz;
      if (t_clks < cursor + 1.0) t_clks = cursor + 1.0;
      while (cursor < t_clks) begin
        @(posedge cfg.vif.clk);
        cursor += 1.0;
      end

      // 服务层位置：KO 绝对时刻在 ODU 帧内的比例
      sf_idx = $rtoi(t_arr[i] / sf_period_s);
      frac   = t_arr[i] / sf_period_s - sf_idx;
      if (frac < 0.0) frac += 1.0;
      cfg.sf_frac_to_rc(frac, sf_row, sf_col);
      // fgOTN 位置：该通道帧扫描序上的开销区域
      cfg.fg_byte_to_rc(off_arr[i], fg_row, fg_col);

      begin
        ko_item it = ko_item::type_id::create("it");
        it.randomize_payload();
        it.chan_id      = chan_arr[i];
        it.sf_vld       = 1'b1;
        it.sf_row       = sf_row;
        it.sf_col       = sf_col;
        it.sf_frame_idx = sf_idx;
        it.fg_vld       = 1'b1;
        it.fg_row       = fg_row;
        it.fg_col       = fg_col;
        it.fg_pos_idx   = k_arr[i];
        it.fg_frame_idx = nfg_arr[i];
        start_item(it);
        finish_item(it);
      end

      `uvm_info("SEQ", $sformatf("KO#%0d 通道%0d: sf帧%0d(r%0d,c%0d) | fg帧%0d 位置%0d → (r%0d,c%0d) @%.3f us",
               i, chan_arr[i], sf_idx, sf_row, sf_col, nfg_arr[i], k_arr[i],
               fg_row, fg_col, t_arr[i]*1e6), UVM_HIGH)
    end
  endtask
endclass
