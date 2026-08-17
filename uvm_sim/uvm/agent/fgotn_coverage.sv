//----------------------------------------------------------------------------
// fgotn_coverage.sv - 开销字段功能覆盖率
// 兼容说明：Verilator 不支持 covergroup（忽略并告警），商业仿真器可用。
//----------------------------------------------------------------------------
class fgotn_coverage extends uvm_subscriber #(fgotn_frame_item);

  `uvm_component_utils(fgotn_coverage)

  covergroup frame_cg;
    option.per_instance = 1;

    cp_mfas : coverpoint mfas {
      bins zero  = {0};
      bins mid   = {[1:127]};
      bins high  = {[128:255]};
    }

    cp_pt : coverpoint opu_pt {
      bins exp  = {6'h01};
      bins pkt  = {6'h02};
      bins cbr  = {6'h03};
      bins vc12 = {6'h05};
      bins vc3  = {6'h07};
      bins vc4  = {6'h08};
      bins e1   = {6'h09};
      bins prbs = {6'h3E};
    }

    cp_stat : coverpoint pm_stat {
      bins normal = {0};
      bins lck    = {[1:3]};
      bins oci    = {[4:5]};
      bins ais    = {[6:7]};
    }

    cp_len : coverpoint frame_size {
      bins ok    = {fgotn_frame_item::FRAME_BYTES};
      bins other = default;
    }

    cp_oh_present : coverpoint oh_present {
      bins none   = {0};
      bins da     = {1};
      bins tcm    = {2};
      bins both   = {3};
    }
  endgroup

  int mfas;
  bit [5:0] opu_pt;
  bit [2:0] pm_stat;
  int frame_size;
  bit [1:0] oh_present;

  function new(string name = "fgotn_coverage", uvm_component parent = null);
    super.new(name, parent);
    frame_cg = new();
  endfunction

  function void write(fgotn_frame_item t);
    mfas       = t.mfas;
    opu_pt     = t.opu_pt;
    pm_stat    = t.pm_stat;
    frame_size = t.frame_bytes.size();
    oh_present = {t.da[0] != 0, (t.tcm1_bip8 != 0 || t.tcm2_bip8 != 0)};
    frame_cg.sample();
  endfunction

endclass
