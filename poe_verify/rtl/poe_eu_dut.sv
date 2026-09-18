// ============================================================================
// EU DUT 边界壳 —— **接真实 EU RTL 时的唯一替换点**
//
// 替换清单（只动本文件）：
//   1) 删掉下面的 `sa_core u_eu (...)`，改为例化真实 EU RTL
//   2) 按本文件的端口逐条对齐（位宽由 RF_W/TID_W 参数给定）
//   3) 其余文件（线程/存储/CSR/RF/检查器/TB）全都不动
//
// 今天的实情（写在文档里，别误解）：
//   真实 EU RTL 还没接，这里**暂时例化同一份 sa-studio 参考模型**，
//   目的是先把"KO → 线程 → ts → burst → sub_pc → EU → 回刷 → 校验"这条路打通。
//   所以今天的 DUT 与 RM 相同 ⇒ 比对通过只是**自洽**，不是验证。
//   真正的验证从换成真实 RTL 那一刻开始（那时平台侧零改动）。
// ============================================================================
module poe_eu_dut #(
    parameter int RF_W  = 1024,
    parameter int TID_W = 3
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             task_vld,
    input  logic [TID_W-1:0] task_tid,
    input  logic [3:0]       task_sub_pc,
    output logic             task_rdy,
    input  logic [RF_W-1:0]  rf_in,
    output logic [RF_W-1:0]  rf_out,
    output logic             rf_we,
    input  logic [127:0]     rmw_in,
    output logic [127:0]     rmw_out,
    input  logic [63:0]      ro_regs,
    output logic [31:0]      wo_out,
    output logic [0:0]       wo_fwe,
    output logic [3:0]       err_out,
    output logic             done,
    output logic [TID_W-1:0] done_tid,
    input  logic             imem_we,
    input  logic [0:0]       imem_saddr,
    input  logic [3:0]       imem_waddr,
    input  logic [63:0]      imem_wdata
);
    logic             busy;
    logic             in_valid;
    logic [7:0]       in_tid;
    logic [3:0]       in_pc;
    logic [RF_W-1:0]  out_regs;
    logic             out_valid;
    logic [7:0]       out_tid;
    logic [3:0]       out_pc;

    assign task_rdy = ~busy;
    assign in_valid = task_vld & ~busy;
    assign in_tid   = {5'b0, task_tid};
    assign in_pc    = task_sub_pc;

    assign rf_out   = out_regs;
    assign rf_we    = out_valid;
    assign done     = out_valid;
    assign done_tid = out_tid[TID_W-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        busy <= 1'b0;
        else if (in_valid) busy <= 1'b1;
        else if (out_valid) busy <= 1'b0;
    end

    // ---- ↓↓↓ 替换点：真实 EU RTL 放在这里 ↓↓↓ ----
    sa_core u_eu (
        .clk(clk),
        .rst_n(rst_n),
        .en(1'b1),
        .in_regs(rf_in),
        .out_regs(out_regs),
        .in_valid(in_valid),
        .out_valid(out_valid),
        .in_tid(in_tid),
        .out_tid(out_tid),
        .in_pc(in_pc),
        .out_pc(out_pc),
        .rmw_in(rmw_in),
        .rmw_out(rmw_out),
        .ro_regs(ro_regs),
        .wo_out(wo_out),
        .wo_fwe(wo_fwe),
        .err_out(err_out),
        .imem_we(imem_we),
        .imem_saddr(imem_saddr),
        .imem_waddr(imem_waddr),
        .imem_wdata(imem_wdata)
    );
endmodule
