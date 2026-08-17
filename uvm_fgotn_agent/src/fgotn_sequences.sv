//----------------------------------------------------------------------------
// fgotn_sequences.sv — 基础 sequence
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
    repeat (num_frames) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      assert(req.randomize());
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
    repeat (num_frames) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      assert(req.randomize());
      req.opu_pt  = pt;
      req.pm_stat = stat;
      if (da_en)  foreach (req.da[i]) req.da[i] = $urandom;
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
    repeat (num_frames) begin
      req = fgotn_frame_item::type_id::create("req");
      start_item(req);
      assert(req.randomize());
      req.inject_bad_fas     = bad_fas;
      req.inject_short_frame = short_frame;
      req.build_frame();
      finish_item(req);
    end
  endtask
endclass
