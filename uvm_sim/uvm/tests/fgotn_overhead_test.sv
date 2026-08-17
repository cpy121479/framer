//----------------------------------------------------------------------------
// fgotn_overhead_test.sv - 开销聚焦测试：PT/STAT/DA/TCM 字段
//----------------------------------------------------------------------------
`include "uvm_macros.svh"
import uvm_pkg::*;
import fgotn_pkg::*;

class fgotn_overhead_test extends fgotn_base_test;

  `uvm_component_utils(fgotn_overhead_test)

  function new(string name = "fgotn_overhead_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_stimulus(uvm_phase phase);
    fgotn_overhead_focus_seq seq;
    seq = fgotn_overhead_focus_seq::type_id::create("seq");
    seq.pt         = 6'h02;                    // 分组映射
    seq.stat       = 3'b000;
    seq.da_en      = 1;
    seq.tcm_en     = 1;
    seq.num_frames = get_num_frames();
    seq.start(env.agent.sqr);
  endtask

endclass
