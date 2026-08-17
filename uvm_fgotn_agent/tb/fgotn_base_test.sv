//----------------------------------------------------------------------------
// fgotn_base_test.sv — 基础测试：例化 agent 并跑默认帧序列
//----------------------------------------------------------------------------
class fgotn_base_test extends uvm_test;

  fgotn_agent        agent;
  fgotn_agent_config cfg;
  fgotn_if           vif;

  `uvm_component_utils(fgotn_base_test)

  function new(string name = "fgotn_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual fgotn_if)::get(this, "", "vif", vif))
      `uvm_fatal(get_type_name(), "未在 config_db 中找到 virtual fgotn_if（vif）")
    cfg = fgotn_agent_config::type_id::create("cfg");
    cfg.vif          = vif;
    cfg.is_active    = UVM_ACTIVE;
    cfg.enable_coverage = 1;
    uvm_config_db#(fgotn_agent_config)::set(this, "agent", "fgotn_agent_config", cfg);
    agent = fgotn_agent::type_id::create("agent", this);
  endfunction

  task run_phase(uvm_phase phase);
    fgotn_default_frame_seq seq;
    phase.raise_objection(this);
    seq = fgotn_default_frame_seq::type_id::create("seq");
    seq.num_frames = 10;
    if (!seq.randomize())
      `uvm_fatal(get_type_name(), "sequence 随机化失败")
    seq.start(agent.sqr);
    #100;
    phase.drop_objection(this);
  endtask

endclass
