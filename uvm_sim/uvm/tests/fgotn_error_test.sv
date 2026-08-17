//----------------------------------------------------------------------------
// fgotn_error_test.sv - 错误注入测试：坏 FAS + 短帧
// 关闭 monitor 的协议检查，由 scoreboard 逐字节比对确认错误按预期注入。
//----------------------------------------------------------------------------
`include "uvm_macros.svh"
import uvm_pkg::*;
import fgotn_pkg::*;

class fgotn_error_test extends fgotn_base_test;

  `uvm_component_utils(fgotn_error_test)

  function new(string name = "fgotn_error_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg.check_protocol = 0;                    // 注入错误帧时关闭协议检查
  endfunction

  task run_stimulus(uvm_phase phase);
    fgotn_error_injection_seq seq;
    seq = fgotn_error_injection_seq::type_id::create("seq");
    seq.bad_fas     = 1;
    seq.short_frame = 1;
    seq.num_frames  = get_num_frames();
    seq.start(env.agent.sqr);
  endtask

endclass
