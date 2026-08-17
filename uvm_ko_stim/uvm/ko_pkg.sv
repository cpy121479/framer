package ko_pkg;
  `include "uvm_macros.svh"
  import uvm_pkg::*;

  // 包级全局握手对象（Verilator 下 config_db 不可靠，走全局引用）
  bit g_reset_done;

  `include "ko_item.sv"
  `include "ko_agent_cfg.sv"
  `include "agent/ko_driver.sv"
  `include "agent/ko_monitor.sv"
  `include "agent/ko_agent.sv"
  `include "scoreboard/ko_scoreboard.sv"
  `include "env/ko_env.sv"
  `include "ko_seq.sv"
  `include "tests/ko_base_test.sv"
  `include "tests/ko_smoke_test.sv"

  ko_tb_config g_tb_cfg = new;
endpackage
