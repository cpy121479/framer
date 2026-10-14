package poe_uvm_pkg;
`include "uvm_macros.svh"
    import uvm_pkg::*;
    import poe_pkg::*;

    // config_db 在 Verilator 下不可靠：接口走包级全局引用（与旧平台一致）
    virtual poe_if g_vif;

    // UVM 侧宽度常量（与 tb/poe_if.sv 的 localparam 保持一致）
    localparam int POE_RF_W      = 2048;   // 每线程 RF 位宽（256B = 64 槽 × 32bit）
    localparam int POE_CSR_BYTES = 90;     // 每线程 CSR 字节数（0x00..0x59）

`include "item/poe_item.sv"              // 事务：poe_ko_item（激励）/ poe_ev_item（观测）
`include "seq/poe_ko_seq.sv"             // 序列：poe_ko_seq
`include "agent/poe_agent.sv"            // agent：driver + sequencer
`include "agent/poe_monitors.sv"         // monitor：DUT 侧 / RM 侧
`include "scoreboard/poe_scoreboard.sv"  // scoreboard：TLM FIFO 对齐 + 比对
`include "env/poe_env.sv"                // env：组件装配 + connect_phase 连线
`include "tests/poe_base_test.sv"        // test：预载镜像 + 跑序列 + 收尾
endpackage
