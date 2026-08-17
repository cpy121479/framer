//----------------------------------------------------------------------------
// fgotn_pkg.sv — fgOTN UVM agent 包（统一编译入口）
//----------------------------------------------------------------------------
package fgotn_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "fgotn_frame_item.sv"
  `include "fgotn_agent_config.sv"
  `include "fgotn_sequencer.sv"
  `include "fgotn_driver.sv"
  `include "fgotn_monitor.sv"
  `include "fgotn_coverage.sv"
  `include "fgotn_sequences.sv"
  `include "fgotn_agent.sv"

endpackage
