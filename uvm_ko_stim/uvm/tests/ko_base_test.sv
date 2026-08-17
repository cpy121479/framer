class ko_base_test extends uvm_test;
  ko_env env;
  `uvm_component_utils(ko_base_test)

  function new(string name = "ko_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    env = ko_env::type_id::create("env", this);
    parse_plusargs();
  endfunction

  // 从命令行读取带宽/服务层配置（+ODU_TYPE/+ODU_RATE/+OH_POS/+FRAME_PERIOD_US/...）
  function void parse_plusargs();
    string odu_type;
    real   rv;
    int    iv;
    if ($value$plusargs("ODU_TYPE=%s", odu_type)) begin
      case (odu_type)
        "ODU0": ko_pkg::g_tb_cfg.otu_rate_bps = 1.24416e9;
        "ODU1": ko_pkg::g_tb_cfg.otu_rate_bps = 2.498775126e9;
        "ODU2": ko_pkg::g_tb_cfg.otu_rate_bps = 10.037273924e9;
        default: `uvm_warning("CFG", $sformatf("未知 ODU_TYPE=%s，保持默认（ODU2）", odu_type))
      endcase
    end
    if ($value$plusargs("ODU_RATE=%e", rv)) ko_pkg::g_tb_cfg.otu_rate_bps = rv;
    if ($value$plusargs("OH_POS=%d", iv)) ko_pkg::g_tb_cfg.oh_pos_per_frame = iv;
    else if ($value$plusargs("OH_BYTES=%d", iv)) ko_pkg::g_tb_cfg.oh_pos_per_frame = iv;
    if ($value$plusargs("FRAME_PERIOD_US=%e", rv)) ko_pkg::g_tb_cfg.frame_period_us = rv;
    if ($value$plusargs("NUM_FRAMES=%d", iv)) ko_pkg::g_tb_cfg.n_frames = iv;
    if ($value$plusargs("JITTER_PCT=%d", iv)) ko_pkg::g_tb_cfg.jitter_pct = iv;
    if ($value$plusargs("USE_TREADY=%d", iv)) ko_pkg::g_tb_cfg.use_tready = iv[0];
    if ($value$plusargs("N_SLOTS=%d", iv)) ko_pkg::g_tb_cfg.n_slots = iv;
    if ($value$plusargs("N_CHAN=%d", iv)) ko_pkg::g_tb_cfg.n_channels = iv;
    if ($value$plusargs("P_PER_CHAN=%d", iv)) ko_pkg::g_tb_cfg.p_per_chan = iv;
    if ($value$plusargs("CHAN_SKEW=%d", iv)) ko_pkg::g_tb_cfg.chan_skew = iv[0];
  endfunction

  task run_phase(uvm_phase phase);
    ko_bandwidth_seq seq;
    phase.raise_objection(this);
    while (!ko_pkg::g_reset_done) @(posedge ko_pkg::g_tb_cfg.vif.clk);
    seq = ko_bandwidth_seq::type_id::create("seq");
    seq.start(env.agent.sqr);
    #100ns;
    phase.drop_objection(this);
  endtask
endclass
