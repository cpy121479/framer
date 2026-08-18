// ============================================================================
// ko_pkg：KOA UVM 验证平台公共包
// - 包含：item / tb_config / 7 路输入激励 seq（fgOTN/X2X/串口）/
//   agent（driver/monitor）/ scoreboard（8 组优先级参考模型）/ env / tests
// - 全局对象：g_reset_done（复位握手）、g_tb_cfg（接口等，Verilator 下 config_db
//   不可靠，走全局引用）
// - 激励数据流：seq 按时隙表/速率模型产生 KO 报文 → driver 驱动 koa_if →
//   KOA dut → THM/th_sch/burst_sch/CU/dma_ctrl（tb_top 内联）→ monitor 采集
// ============================================================================
package ko_pkg;
`include "uvm_macros.svh"
    import uvm_pkg::*;

    // 包级全局握手对象（Verilator 下 config_db 不可靠，走全局引用）
    bit g_reset_done;

`include "koa_item.sv"
`include "koa_tb_config.sv"
`include "seq/koa_oh_seq.sv"
`include "seq/koa_x2x_seq.sv"
`include "seq/koa_uart_seq.sv"
`include "agent/koa_drivers.sv"
`include "agent/koa_monitors.sv"
`include "agent/koa_agents.sv"
`include "scoreboard/koa_scoreboard.sv"
`include "env/koa_env.sv"
`include "tests/koa_base_test.sv"
`include "tests/koa_smoke_test.sv"

    koa_tb_config g_tb_cfg = new;
endpackage
