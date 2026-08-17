//----------------------------------------------------------------------------
// fgotn_sequences.sv - 基础激励序列
// 说明：Verilator 的 randomize() 恒返回 0，因此序列对自身随机字段做保守
// 回退（取默认值），事务统一走 fgotn_frame_item::sv_randomize()。
//----------------------------------------------------------------------------

// 默认帧序列：连续发送 num_frames 帧
class fgotn_default_frame_seq extends uvm_sequence #(fgotn_frame_item);
  rand int unsigned num_frames = 10;
  constraint c_num { num_frames inside {[1:1000]}; }

  `uvm_object_utils(fgotn_default_frame_seq)

  function new(string name = "fgotn_default_frame_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned n;
    n = num_frames;
    repeat (n) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      req.sv_randomize();
      finish_item(req);
    end
  endtask
endclass

// 开销聚焦序列：约束特定开销字段（PT 码点、STAT、DA、TCM 层级）
class fgotn_overhead_focus_seq extends uvm_sequence #(fgotn_frame_item);
  rand bit [5:0] pt;
  rand bit [2:0] stat;
  rand bit       da_en;
  rand bit       tcm_en;
  rand int unsigned num_frames = 5;

  constraint c_pt   { pt inside {6'h02, 6'h03, 6'h05, 6'h3E}; }
  constraint c_stat { stat inside {[0:7]}; }
  constraint c_num  { num_frames inside {[1:20]}; }

  `uvm_object_utils(fgotn_overhead_focus_seq)

  function new(string name = "fgotn_overhead_focus_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned n;
    if (!(pt inside {6'h02, 6'h03, 6'h05, 6'h3E})) pt = 6'h02;
    if (!(stat inside {[0:7]})) stat = 3'b000;
    n = (num_frames inside {[1:20]}) ? num_frames : 5;
    repeat (n) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      req.sv_randomize();
      req.opu_pt  = pt;
      req.pm_stat = stat;
      if (da_en)  foreach (req.da[i]) req.da[i] = 24'h12_34_56;
      if (tcm_en) begin
        req.tcm1_bip8 = 8'hFF;
        req.tcm2_bip8 = 8'hAA;
      end
      req.build_frame();
      finish_item(req);
    end
  endtask
endclass

// 错误注入序列：坏 FAS / 短帧
class fgotn_error_injection_seq extends uvm_sequence #(fgotn_frame_item);
  rand int unsigned num_frames = 3;
  rand bit bad_fas;
  rand bit short_frame;

  constraint c_num { num_frames inside {[1:10]}; }

  `uvm_object_utils(fgotn_error_injection_seq)

  function new(string name = "fgotn_error_injection_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned n;
    n = (num_frames inside {[1:10]}) ? num_frames : 3;
    repeat (n) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      req.sv_randomize();
      req.inject_bad_fas     = bad_fas;
      req.inject_short_frame = short_frame;
      req.build_frame();
      finish_item(req);
    end
  endtask
endclass

// MFAS 复帧序列：mfas 0→255 循环，验证 256 帧复帧连续性
class fgotn_mfas_ramp_seq extends uvm_sequence #(fgotn_frame_item);
  rand int unsigned num_frames = 266;          // 256 复帧 + 10
  constraint c_num { num_frames inside {[1:1000]}; }

  `uvm_object_utils(fgotn_mfas_ramp_seq)

  function new(string name = "fgotn_mfas_ramp_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned n;
    n = num_frames;
    for (int i = 0; i < n; i++) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      req.sv_randomize();
      req.mfas = i[7:0];                       // 0~255 循环
      req.build_frame();
      finish_item(req);
    end
  endtask
endclass

// PRBS 测试信号序列：PT = 0x3E，净荷为 LFSR 伪随机序列（确定性）
class fgotn_prbs_seq extends uvm_sequence #(fgotn_frame_item);
  rand int unsigned num_frames = 10;
  constraint c_num { num_frames inside {[1:100]}; }

  `uvm_object_utils(fgotn_prbs_seq)

  function new(string name = "fgotn_prbs_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned n;
    bit [7:0] lfsr = 8'hA5;
    n = num_frames;
    repeat (n) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      req.sv_randomize();
      req.opu_pt = 6'h3E;
      foreach (req.payload[i]) begin
        req.payload[i] = lfsr;
        lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
      end
      req.build_frame();
      finish_item(req);
    end
  endtask
endclass
