//----------------------------------------------------------------------------
// fgotn_monitor.sv - 帧监视器（active/passive 均例化）
// 按 tstart/tend 采集一帧字节流，重建 fgotn_frame_item 并解析开销字段，
// 通过 ap 送出；同时做基本完整性检查（帧长、FAS 对齐，可配置开关）。
//----------------------------------------------------------------------------
class fgotn_monitor extends uvm_monitor;

  fgotn_agent_config cfg;
  virtual fgotn_if vif;
  uvm_analysis_port #(fgotn_frame_item) ap;

  `uvm_component_utils(fgotn_monitor)

  function new(string name = "fgotn_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap  = new("ap", this);
    cfg = fgotn_agent_config::get_config(this);
    if (cfg == null) cfg = fgotn_pkg::g_tb_cfg;
    if (cfg == null)
      `uvm_fatal("CFG", $sformatf("%s: 未找到 fgotn_agent_config", get_full_name()))
    vif = cfg.vif;
    if (vif == null)
      `uvm_fatal("VIF", $sformatf("%s: 配置中 virtual fgotn_if 为空", get_full_name()))
  endfunction

  task run_phase(uvm_phase phase);
    fgotn_frame_item item;
    bit [7:0] bytes[$];
    bit in_frame;

    forever begin
      @(vif.mon_cb);
      if (vif.mon_cb.tvalid && vif.mon_cb.tready) begin
        if (vif.mon_cb.tstart) begin
          bytes.delete();
          in_frame = 1;
        end
        if (in_frame) begin
          bytes.push_back(vif.mon_cb.tdata);
          if (vif.mon_cb.tend) begin
            in_frame = 0;
            item = fgotn_frame_item::type_id::create("item");
            item.frame_bytes = new[bytes.size()];
            foreach (bytes[i]) item.frame_bytes[i] = bytes[i];
            item.parse_frame();
            check_frame(item);
            ap.write(item);
          end
        end else if (vif.mon_cb.tstart) begin
          `uvm_warning(get_type_name(), "收到 tstart 但上一帧未结束")
        end
      end
    end
  endtask

  function void check_frame(fgotn_frame_item item);
    if (!cfg.check_protocol) return;           // 错误注入测试可关闭协议检查
    if (item.frame_bytes.size() != fgotn_frame_item::FRAME_BYTES)
      `uvm_error(get_type_name(), $sformatf("帧长错误：%0d（期望 %0d）", item.frame_bytes.size(), fgotn_frame_item::FRAME_BYTES))
    if (item.fas[0][31:24] !== 8'hF6 || item.fas[0][23:8] !== 16'h2828)
      `uvm_error(get_type_name(), $sformatf("FAS 对齐错误：%h", item.fas[0]))
  endfunction

endclass
