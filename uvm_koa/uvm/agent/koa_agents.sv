// 单一 KOA agent：多流 driver + 输入/输出 monitor + 共享 sequencer
class koa_agent extends uvm_agent;
  koa_driver                   drv;
  koa_in_monitor               in_mon;
  koa_out_monitor              out_mon;
  uvm_sequencer #(koa_item)    sqr;
  uvm_analysis_port #(koa_item) ap;
  `uvm_component_utils(koa_agent)

  function new(string name = "koa_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv     = koa_driver::type_id::create("drv", this);
    in_mon  = koa_in_monitor::type_id::create("in_mon", this);
    out_mon = koa_out_monitor::type_id::create("out_mon", this);
    sqr     = uvm_sequencer#(koa_item)::type_id::create("sqr", this);
    ap      = new("ap", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
    in_mon.ap.connect(ap);
    out_mon.ap.connect(ap);
  endfunction
endclass
