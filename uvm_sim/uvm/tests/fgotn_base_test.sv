//----------------------------------------------------------------------------
// fgotn_base_test.sv - 基础测试：env 装配 + 复位握手 + 激励入口
// 子类通过重写 run_stimulus() 指定要跑的 sequence。
//----------------------------------------------------------------------------
`include "uvm_macros.svh"
import uvm_pkg::*;
import fgotn_pkg::*;

class fgotn_base_test extends uvm_test;

  fgotn_env env;
  fgotn_agent_config cfg;
  virtual fgotn_if vif;

  `uvm_component_utils(fgotn_base_test)

  function new(string name = "fgotn_base_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // config_db 优先；Verilator 下取不到时回退到 tb_top 填充的 g_tb_cfg
    if (!uvm_config_db#(virtual fgotn_if)::get(this, "", "vif", vif)) begin
      if (fgotn_pkg::g_tb_cfg != null && fgotn_pkg::g_tb_cfg.vif != null) begin
        vif = fgotn_pkg::g_tb_cfg.vif;
        `uvm_info(get_type_name(), "config_db 未找到 vif，回退到全局握手对象 g_tb_cfg", UVM_LOW)
      end else begin
        `uvm_fatal(get_type_name(), "未在 config_db / g_tb_cfg 中找到 virtual fgotn_if")
      end
    end
    cfg = fgotn_agent_config::type_id::create("cfg");
    cfg.vif             = vif;
    cfg.is_active       = UVM_ACTIVE;
    cfg.enable_coverage = 1;
    cfg.check_protocol  = 1;
    // 必须先 set 再 create 子组件（子组件 build_phase 立即执行）
    uvm_config_db#(fgotn_agent_config)::set(this, "env.agent", "fgotn_agent_config", cfg);
    // 同步到全局握手对象（Verilator 回退路径）
    fgotn_pkg::g_tb_cfg = cfg;
    env = fgotn_env::type_id::create("env", this);
  endfunction

  // 从命令行 +NUM_FRAMES=NN 读取帧数，缺省 10
  function int get_num_frames();
    string s;
    if (uvm_cmdline_processor::get_inst().get_arg_value("+NUM_FRAMES=", s))
      return s.atoi();
    return 10;
  endfunction

  virtual task run_stimulus(uvm_phase phase);
    fgotn_default_frame_seq seq;
    seq = fgotn_default_frame_seq::type_id::create("seq");
    seq.num_frames = get_num_frames();
    seq.start(env.agent.sqr);
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);               // 必须先 objection 再等待/启动
    wait (fgotn_pkg::g_reset_done);            // 等复位完成握手
    run_stimulus(phase);
    #100;                                      // 让最后一帧完成采集与比对
    phase.drop_objection(this);
  endtask

endclass
