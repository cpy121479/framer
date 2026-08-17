//----------------------------------------------------------------------------
// fgotn_scoreboard.sv - 帧级比分板
// exp_imp 接收 driver 实际发出的事务（期望），act_imp 接收 monitor 采集的
// 事务（实际）。逐字节比对 frame_bytes，并对完整帧做 BIP-8 自洽校验；
// check_phase 检查期望队列已清空。
//----------------------------------------------------------------------------
`uvm_analysis_imp_decl(_exp)
`uvm_analysis_imp_decl(_act)

class fgotn_scoreboard extends uvm_scoreboard;

  `uvm_component_utils(fgotn_scoreboard)

  uvm_analysis_imp_exp #(fgotn_frame_item, fgotn_scoreboard) exp_imp;
  uvm_analysis_imp_act #(fgotn_frame_item, fgotn_scoreboard) act_imp;

  fgotn_frame_item expected[$];
  int unsigned matched_frames    = 0;
  int unsigned mismatched_frames = 0;
  int unsigned bip8_errors       = 0;

  function new(string name = "fgotn_scoreboard", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    exp_imp = new("exp_imp", this);
    act_imp = new("act_imp", this);
  endfunction

  function void write_exp(fgotn_frame_item t);
    fgotn_frame_item exp_ref;
    exp_ref = fgotn_frame_item::type_id::create("exp_ref");
    exp_ref.copy(t);
    expected.push_back(exp_ref);
  endfunction

  function void write_act(fgotn_frame_item t);
    fgotn_frame_item exp_ref;
    if (expected.size() == 0) begin
      `uvm_error(get_type_name(), "收到采集帧但没有对应的激励帧（expected 队列为空）")
      return;
    end
    exp_ref = expected.pop_front();
    compare_frames(exp_ref, t);
  endfunction

  function void compare_frames(fgotn_frame_item exp_ref, fgotn_frame_item act);
    bit [7:0] b;
    if (exp_ref.frame_bytes.size() != act.frame_bytes.size()) begin
      `uvm_error(get_type_name(), $sformatf("帧长不匹配：激励 %0d / 采集 %0d",
                 exp_ref.frame_bytes.size(), act.frame_bytes.size()))
      mismatched_frames++;
      return;
    end
    foreach (exp_ref.frame_bytes[i]) begin
      if (exp_ref.frame_bytes[i] !== act.frame_bytes[i]) begin
        `uvm_error(get_type_name(), $sformatf("字节 %0d 不匹配：激励 %02x / 采集 %02x",
                   i, exp_ref.frame_bytes[i], act.frame_bytes[i]))
        mismatched_frames++;
        return;
      end
    end
    // BIP-8 自洽校验（仅对完整帧）
    if (act.frame_bytes.size() == fgotn_frame_item::FRAME_BYTES) begin
      b = 8'h00;
      for (int r = 1; r <= 4; r++) begin
        for (int c = 15; c <= 1904; c++) b ^= act.frame_bytes[act.idx(r,c)];
        for (int c = 1919; c <= 3824; c++) b ^= act.frame_bytes[act.idx(r,c)];
      end
      if (b !== act.pm_bip8) begin
        `uvm_error(get_type_name(), $sformatf("BIP-8 自洽检查失败：重算 %02x / 帧内 %02x", b, act.pm_bip8))
        bip8_errors++;
      end
    end
    matched_frames++;
    `uvm_info(get_type_name(), $sformatf("帧比对通过：%0d 字节（mfas=%02x pt=%02x）",
               act.frame_bytes.size(), act.mfas, act.opu_pt), UVM_MEDIUM)
  endfunction

  function void check_phase(uvm_phase phase);
    if (expected.size() != 0)
      `uvm_error(get_type_name(), $sformatf("check_phase：expected 队列仍有 %0d 帧未比对", expected.size()))
    `uvm_info(get_type_name(), $sformatf("比分板汇总：匹配 %0d 帧 / 失配 %0d 帧 / BIP-8 错误 %0d",
               matched_frames, mismatched_frames, bip8_errors), UVM_LOW)
  endfunction

endclass
