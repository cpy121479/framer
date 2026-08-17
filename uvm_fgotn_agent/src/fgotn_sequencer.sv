//----------------------------------------------------------------------------
// fgotn_sequencer.sv — 帧事务定序器
//----------------------------------------------------------------------------
class fgotn_sequencer extends uvm_sequencer #(fgotn_frame_item);
  `uvm_component_utils(fgotn_sequencer)

  function new(string name = "fgotn_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass
