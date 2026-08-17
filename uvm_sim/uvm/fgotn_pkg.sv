//----------------------------------------------------------------------------
// fgotn_pkg.sv - fgOTN UVM 平台统一包入口
// 编译顺序：config -> item -> sequencer/driver/monitor/coverage ->
//           sequences -> scoreboard -> agent -> env
//----------------------------------------------------------------------------
package fgotn_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // 复位完成握手标志：tb_top 复位结束后置 1，test 的 run_phase 等待
  bit g_reset_done = 1'b0;

  `include "agent/fgotn_agent_config.sv"

  // 全局握手对象（Verilator 兼容）：tb_top 填充 vif，test 填充完整配置，
  // 组件在 config_db 取不到时回退读取。
  fgotn_agent_config g_tb_cfg;

  `include "seq/fgotn_frame_item.sv"
  `include "agent/fgotn_sequencer.sv"
  `include "agent/fgotn_driver.sv"
  `include "agent/fgotn_monitor.sv"
  `include "agent/fgotn_coverage.sv"
  `include "seq/fgotn_sequences.sv"
  `include "scoreboard/fgotn_scoreboard.sv"
  `include "agent/fgotn_agent.sv"
  `include "env/fgotn_env.sv"

endpackage
