class ko_env extends uvm_env;
  ko_agent      agent;
  ko_scoreboard scb;
  `uvm_component_utils(ko_env)

  function new(string name = "ko_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = ko_agent::type_id::create("agent", this);
    scb   = ko_scoreboard::type_id::create("scb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agent.mon.ap.connect(scb.ap_imp);
  endfunction
endclass
