//----------------------------------------------------------------------------
// fgotn_smoke_test.sv - 冒烟测试：默认帧序列
//----------------------------------------------------------------------------
`include "uvm_macros.svh"
import uvm_pkg::*;
import fgotn_pkg::*;

class fgotn_smoke_test extends fgotn_base_test;

  `uvm_component_utils(fgotn_smoke_test)

  function new(string name = "fgotn_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_stimulus(uvm_phase phase);
    fgotn_default_frame_seq seq;
    seq = fgotn_default_frame_seq::type_id::create("seq");
    seq.num_frames = get_num_frames();
    seq.start(env.agent.sqr);
  endtask

endclass
