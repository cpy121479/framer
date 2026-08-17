//----------------------------------------------------------------------------
// fgotn_agent_config.sv - agent 配置对象
//----------------------------------------------------------------------------
class fgotn_agent_config extends uvm_object;

  virtual fgotn_if vif;                         // 接口句柄（tb 层赋值）
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  int unsigned         inter_frame_gap = 1;     // 帧间空闲周期数
  bit                  enable_coverage = 1;     // 是否实例化覆盖率组件
  bit                  check_protocol  = 1;     // monitor 是否做帧长/FAS 协议检查

  `uvm_object_utils_begin(fgotn_agent_config)
    `uvm_field_enum(uvm_active_passive_enum, is_active, UVM_ALL_ON)
    `uvm_field_int(inter_frame_gap, UVM_ALL_ON)
    `uvm_field_int(enable_coverage, UVM_ALL_ON)
    `uvm_field_int(check_protocol, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "fgotn_agent_config");
    super.new(name);
  endfunction

  // 从 config_db 取配置；取不到返回 null，由组件回退到全局握手对象 g_tb_cfg
  static function fgotn_agent_config get_config(uvm_component comp);
    fgotn_agent_config cfg;
    if (!uvm_config_db#(fgotn_agent_config)::get(comp, "", "fgotn_agent_config", cfg)) begin
      `uvm_info("CFG", $sformatf("%s: config_db 未找到 fgotn_agent_config，将回退到 g_tb_cfg", comp.get_full_name()), UVM_LOW)
      return null;
    end
    return cfg;
  endfunction

endclass
