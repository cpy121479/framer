class ko_driver extends uvm_driver #(ko_item);
  `uvm_component_utils(ko_driver)

  function new(string name = "ko_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    ko_item req;
    forever begin
      seq_item_port.get_next_item(req);
      while (!ko_pkg::g_reset_done) @(posedge ko_pkg::g_tb_cfg.vif.clk);
      if (ko_pkg::g_tb_cfg.use_tready) begin
        @(ko_pkg::g_tb_cfg.vif.cb);
        ko_pkg::g_tb_cfg.vif.cb.vld    <= 1'b1;
        ko_pkg::g_tb_cfg.vif.cb.ko_data <= req.pack();
        ko_pkg::g_tb_cfg.vif.cb.ko_chan_id <= req.chan_id[6:0];
        ko_pkg::g_tb_cfg.vif.cb.sf_vld <= 1'b1;
        ko_pkg::g_tb_cfg.vif.cb.sf_row <= req.sf_row[2:0];
        ko_pkg::g_tb_cfg.vif.cb.sf_col <= req.sf_col[11:0];
        ko_pkg::g_tb_cfg.vif.cb.sf_frame_idx <= req.sf_frame_idx[15:0];
        ko_pkg::g_tb_cfg.vif.cb.fg_vld <= 1'b1;
        ko_pkg::g_tb_cfg.vif.cb.fg_row <= req.fg_row[2:0];
        ko_pkg::g_tb_cfg.vif.cb.fg_col <= req.fg_col[11:0];
        ko_pkg::g_tb_cfg.vif.cb.fg_frame_idx <= req.fg_frame_idx[15:0];
        // 标准 valid/ready 握手：vld 保持到 tready 拉高
        do @(ko_pkg::g_tb_cfg.vif.cb); while (ko_pkg::g_tb_cfg.vif.cb.tready !== 1'b1);
        ko_pkg::g_tb_cfg.vif.cb.vld <= 1'b0;
        ko_pkg::g_tb_cfg.vif.cb.sf_vld <= 1'b0;
        ko_pkg::g_tb_cfg.vif.cb.fg_vld <= 1'b0;
      end else begin
        @(ko_pkg::g_tb_cfg.vif.cb);
        ko_pkg::g_tb_cfg.vif.cb.vld    <= 1'b1;
        ko_pkg::g_tb_cfg.vif.cb.ko_data <= req.pack();
        ko_pkg::g_tb_cfg.vif.cb.ko_chan_id <= req.chan_id[6:0];
        ko_pkg::g_tb_cfg.vif.cb.sf_vld <= 1'b1;
        ko_pkg::g_tb_cfg.vif.cb.sf_row <= req.sf_row[2:0];
        ko_pkg::g_tb_cfg.vif.cb.sf_col <= req.sf_col[11:0];
        ko_pkg::g_tb_cfg.vif.cb.sf_frame_idx <= req.sf_frame_idx[15:0];
        ko_pkg::g_tb_cfg.vif.cb.fg_vld <= 1'b1;
        ko_pkg::g_tb_cfg.vif.cb.fg_row <= req.fg_row[2:0];
        ko_pkg::g_tb_cfg.vif.cb.fg_col <= req.fg_col[11:0];
        ko_pkg::g_tb_cfg.vif.cb.fg_frame_idx <= req.fg_frame_idx[15:0];
        @(ko_pkg::g_tb_cfg.vif.cb);
        ko_pkg::g_tb_cfg.vif.cb.vld <= 1'b0;
        ko_pkg::g_tb_cfg.vif.cb.sf_vld <= 1'b0;
        ko_pkg::g_tb_cfg.vif.cb.fg_vld <= 1'b0;
      end
      seq_item_port.item_done();
      @(ko_pkg::g_tb_cfg.vif.cb);   // 一拍间隔，避免信号残留
    end
  endtask
endclass
