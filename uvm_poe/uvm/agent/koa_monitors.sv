// 多流输入 monitor：每拍在 posedge 后读 KOA 的接收确认（ack_vld + ack_*），
// 按流上报。ack 由 KOA 在入队拍寄存输出（沿后稳定），与 DUT 实际接收 100% 一致，
// 不依赖 vld/rdy 握手采样时刻（避免并发多流时的采样歧义）。
// 反压统计仍用各流 vld && !rdy（仅统计，不影响 scoreboard）。
class koa_in_monitor extends uvm_monitor;
  uvm_analysis_port #(koa_item) ap;
  `uvm_component_utils(koa_in_monitor)

  function new(string name = "koa_in_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  task run_phase(uvm_phase phase);
    int n_oh  = (ko_pkg::g_tb_cfg.n_oh_planes > 0)  ? ko_pkg::g_tb_cfg.n_oh_planes  : 1;
    int n_x2x = (ko_pkg::g_tb_cfg.n_x2x_planes > 0) ? ko_pkg::g_tb_cfg.n_x2x_planes : 1;
    forever begin
      @(posedge ko_pkg::g_tb_cfg.vif.clk);
      #1;
      // 反压统计：vld 有效但 rdy=0
      begin
        bit bp[7];
        bp[0] = (|ko_pkg::g_tb_cfg.vif.oh_e_vld)   && !ko_pkg::g_tb_cfg.vif.oh_e_rdy[0];
        bp[1] = (|ko_pkg::g_tb_cfg.vif.oh_i_vld)   && !ko_pkg::g_tb_cfg.vif.oh_i_rdy[0];
        bp[2] = (|ko_pkg::g_tb_cfg.vif.aps_e_vld)  && !ko_pkg::g_tb_cfg.vif.aps_e_rdy[0];
        bp[3] = (|ko_pkg::g_tb_cfg.vif.aps_i_vld)  && !ko_pkg::g_tb_cfg.vif.aps_i_rdy[0];
        bp[4] = (|ko_pkg::g_tb_cfg.vif.alm_vld)    && !ko_pkg::g_tb_cfg.vif.alm_rdy[0];
        bp[5] = ko_pkg::g_tb_cfg.vif.u_e_vld && !ko_pkg::g_tb_cfg.vif.u_e_rdy;
        bp[6] = ko_pkg::g_tb_cfg.vif.u_i_vld && !ko_pkg::g_tb_cfg.vif.u_i_rdy;
        for (int f = 0; f < 7; f++) begin
          if (bp[f]) begin
            ko_pkg::g_tb_cfg.bp_clks[f]++;
            if (!ko_pkg::g_tb_cfg.bp_prev[f]) ko_pkg::g_tb_cfg.bp_events[f]++;
          end
          ko_pkg::g_tb_cfg.bp_prev[f] = bp[f];
        end
      end
      // 接收事件：KOA 实际入队（ack 寄存输出，沿后稳定）
      if (ko_pkg::g_tb_cfg.vif.ack_vld)
        sample(koa_stream_t'(ko_pkg::g_tb_cfg.vif.ack_stream), 0,
               ko_pkg::g_tb_cfg.vif.ack_pri,
               ko_pkg::g_tb_cfg.vif.ack_data,
               ko_pkg::g_tb_cfg.vif.ack_cid,
               ko_pkg::g_tb_cfg.vif.ack_pos);
    end
  endtask

  function void sample(koa_stream_t s, int pl, logic [2:0] pri,
                       logic [383:0] data, logic [16:0] cid, logic [2:0] pos);
    koa_item it = koa_item::type_id::create("it");
    it.stream  = s;
    it.plane   = pl;
    it.cid     = cid;
    it.pos     = pos;
    it.pri     = pri;
    it.ko_data = data;
    it.ev_time = $time - 1;   // ack 在沿后 #1 采样，-1 对齐 KOA 入队沿（与 out 基准一致）
    it.is_out  = 1'b0;
    ap.write(it);
  endfunction
endclass

// 输出 monitor：采样 out_vld，携带 out_src（0=EXT 1=INS 2=ALM 3=UART_EXT 4=UART_INS）
class koa_out_monitor extends uvm_monitor;
  uvm_analysis_port #(koa_item) ap;
  `uvm_component_utils(koa_out_monitor)

  function new(string name = "koa_out_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge ko_pkg::g_tb_cfg.vif.clk);
      #1;
      if (ko_pkg::g_tb_cfg.vif.out_vld) begin
        koa_item it = koa_item::type_id::create("it");
        it.sbuf    = ko_pkg::g_tb_cfg.vif.out_src;
        it.plane   = 0;
        it.ev_time = $time - 1;   // 输出寄存器在沿更新，对齐 DUT 输出拍
        it.is_out  = 1'b1;
        it.pri     = ko_pkg::g_tb_cfg.vif.out_pri;
        it.ko_data = ko_pkg::g_tb_cfg.vif.out_data;
        ap.write(it);
      end
    end
  endtask
endclass
