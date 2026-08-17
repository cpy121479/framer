class koa_env extends uvm_env;
  koa_agent      agent;
  koa_scoreboard scb;
  `uvm_component_utils(koa_env)

  function new(string name = "koa_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = koa_agent::type_id::create("agent", this);
    scb   = koa_scoreboard::type_id::create("scb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.ap.connect(scb.in_imp);
    agent.ap.connect(scb.out_imp);
  endfunction
endclass
