//----------------------------------------------------------------------------
// fgotn_agent.sv — fgODUflex 帧 UVM agent 封装
//----------------------------------------------------------------------------
// 结构：
//   fgotn_agent
//   ├── fgotn_sequencer（仅 active）
//   ├── fgotn_driver   （仅 active）
//   ├── fgotn_monitor  （active/passive 均例化）
//   ├── fgotn_coverage （可选，enable_coverage=1）
//   └── ap（分析端口，向外部测试/计分板输出采集到的帧）
//----------------------------------------------------------------------------
class fgotn_agent extends uvm_agent;

  fgotn_agent_config cfg;
  fgotn_driver       drv;
  fgotn_monitor      mon;
  fgotn_sequencer    sqr;
  fgotn_coverage     cov;
  uvm_analysis_port #(fgotn_frame_item) ap;

  `uvm_component_utils(fgotn_agent)

  function new(string name = "fgotn_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = fgotn_agent_config::get_config(this);
    ap  = new("ap", this);
    mon = fgotn_monitor::type_id::create("mon", this);
    if (cfg.enable_coverage)
      cov = fgotn_coverage::type_id::create("cov", this);
    if (cfg.is_active == UVM_ACTIVE) begin
      drv = fgotn_driver::type_id::create("drv", this);
      sqr = fgotn_sequencer::type_id::create("sqr", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    mon.ap.connect(ap);
    if (cov != null)
      mon.ap.connect(cov.analysis_export);
    if (drv != null)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

endclass
