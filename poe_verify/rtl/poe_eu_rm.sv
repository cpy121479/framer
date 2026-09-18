// ============================================================================
// EU 参考模型（RM）—— 平台的期望值来源，只接检查侧，**不参与控制流**
//
// 内部就是 sa-studio 生成的 rv32i 参考模型（rtl/eu/*，与
// D:\EU核\sa-studio\rv32i.zip 逐字节一致，不需要重新生成）。
// 这一层只做两件事：① 把 task 握手变成 sa_core 的 in_valid 波前；
// ② 把 sa_core 的出口（out_regs/rmw_out/wo_out/err_out）暴露成平台契约。
//
// 边界契约（DUT 与 RM 必须完全一致）：
//   task_vld/task_tid/task_sub_pc → task_rdy    一条 burst = 一个 task
//   rf_in → rf_out + rf_we                       RF 外置（平台侧每线程一份）
//   rmw_in(128b={mcause,mepc,mtvec,mstatus}) ↔ rmw_out（读改写 CSR）
//   ro_regs(64b={mcycle,minstret}) → EU 只读；wo_out/wo_fwe → EU 只写
//   done + done_tid                             结果有效拍（rf_out/rmw_out 同拍有效）
//   imem_we/saddr/waddr/wdata                   EU 内微指令存储（两级 bank）预载
// ============================================================================
module poe_eu_rm #(
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
    // 只发一拍：busy 在下拍拉高，task_rdy 随即为 0
    assign in_valid = task_vld & ~busy;
    assign in_tid   = {5'b0, task_tid};
    assign in_pc    = task_sub_pc;          // sub_pc 就是 EU 内微指令存储地址

    assign rf_out   = out_regs;
    assign rf_we    = out_valid;
    assign done     = out_valid;            // 结果拍：rf_out/rmw_out/wo_out 同拍有效
    assign done_tid = out_tid[TID_W-1:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)      busy <= 1'b0;
        else if (in_valid) busy <= 1'b1;
        else if (out_valid) busy <= 1'b0;
    end

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
