//----------------------------------------------------------------------------
// fgotn_multiframe_test.sv - MFAS 复帧测试：0→255 循环
//----------------------------------------------------------------------------
`include "uvm_macros.svh"
import uvm_pkg::*;
import fgotn_pkg::*;

class fgotn_multiframe_test extends fgotn_base_test;

  `uvm_component_utils(fgotn_multiframe_test)

  function new(string name = "fgotn_multiframe_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_stimulus(uvm_phase phase);
    fgotn_mfas_ramp_seq seq;
    seq = fgotn_mfas_ramp_seq::type_id::create("seq");
    seq.num_frames = 266;
    seq.start(env.agent.sqr);
  endtask

endclass
