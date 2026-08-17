//----------------------------------------------------------------------------
// fgotn_env.sv - 顶层环境：agent + scoreboard
//   agent.ap    -> sb.act_imp（实际：monitor 采集）
//   agent.drv_ap-> sb.exp_imp（期望：driver 实际发出）
//----------------------------------------------------------------------------
class fgotn_env extends uvm_env;

  fgotn_agent agent;
  fgotn_scoreboard sb;

  `uvm_component_utils(fgotn_env)

  function new(string name = "fgotn_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    agent = fgotn_agent::type_id::create("agent", this);
    sb    = fgotn_scoreboard::type_id::create("sb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.ap.connect(sb.act_imp);
    agent.drv_ap.connect(sb.exp_imp);
  endfunction

endclass
