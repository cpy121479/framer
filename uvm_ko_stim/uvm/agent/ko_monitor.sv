class ko_monitor extends uvm_monitor;
  uvm_analysis_port #(ko_item) ap;
  `uvm_component_utils(ko_monitor)

  function new(string name = "ko_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(ko_pkg::g_tb_cfg.vif.mon_cb);
      if (ko_pkg::g_tb_cfg.vif.mon_cb.vld === 1'b1 &&
          (!ko_pkg::g_tb_cfg.use_tready || ko_pkg::g_tb_cfg.vif.mon_cb.tready === 1'b1)) begin
        ko_item it = ko_item::type_id::create("it");
        it.unpack(ko_pkg::g_tb_cfg.vif.mon_cb.ko_data);
        it.chan_id = ko_pkg::g_tb_cfg.vif.mon_cb.ko_chan_id;
        it.sf_vld = ko_pkg::g_tb_cfg.vif.mon_cb.sf_vld;
        it.sf_row = ko_pkg::g_tb_cfg.vif.mon_cb.sf_row;
        it.sf_col = ko_pkg::g_tb_cfg.vif.mon_cb.sf_col;
        it.sf_frame_idx = ko_pkg::g_tb_cfg.vif.mon_cb.sf_frame_idx;
        it.fg_vld = ko_pkg::g_tb_cfg.vif.mon_cb.fg_vld;
        it.fg_row = ko_pkg::g_tb_cfg.vif.mon_cb.fg_row;
        it.fg_col = ko_pkg::g_tb_cfg.vif.mon_cb.fg_col;
        it.fg_frame_idx = ko_pkg::g_tb_cfg.vif.mon_cb.fg_frame_idx;
        ap.write(it);
      end
    end
  endtask
endclass
