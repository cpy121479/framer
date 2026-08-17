class ko_agent extends uvm_agent;
  ko_driver    drv;
  ko_monitor   mon;
  uvm_sequencer #(ko_item) sqr;
  ko_agent_cfg acfg;
  `uvm_component_utils(ko_agent)

  function new(string name = "ko_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(ko_agent_cfg)::get(this, "", "acfg", acfg))
      acfg = ko_agent_cfg::type_id::create("acfg");
    drv  = ko_driver::type_id::create("drv", this);
    mon  = ko_monitor::type_id::create("mon", this);
    sqr  = uvm_sequencer #(ko_item)::type_id::create("sqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
