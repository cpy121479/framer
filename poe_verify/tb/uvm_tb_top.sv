// ============================================================================
// UVM 版 TB 顶层：接口 + 两套平台（DUT / RM），检查全部在 UVM scoreboard 里
//   · 一个 driver 驱动 poe_if，激励在**顶层直接分叉**给 DUT 与 RM
//   · burst 指令存储是 ROM（模块内部 initial 拼镜像），两侧各一份、内容相同
// ============================================================================
`timescale 1ns/1ps
module uvm_tb_top;
    import uvm_pkg::*;
    import poe_uvm_pkg::*;

    // 下面这些宽度**必须与 poe_if 里的 localparam 保持一致**（interface 不做参数化）
    localparam int N_THR   = 64;     // 线程数（= 池子槽位数）
    localparam int TID_W   = 6;      // 线程号位宽
    localparam int RF_W    = 2048;   // 每线程 RF 位宽（256B = 64 槽 × 32bit）
    localparam int TS_MAX  = 16;     // burst 指令存储行数
    localparam int TS_W    = 4;      // ts 行号位宽
    localparam int N_BURST = 8;      // 每 ts 最多 burst 数

    logic clk = 0, rst_n = 0;
    always #0.5ns clk = ~clk;

    // 激励/观测接口（driver 与两个 monitor 都通过它）
    poe_if u_if (.clk(clk), .rst_n(rst_n));

    logic ko_rdy_dut, ko_rdy_rm;   // 两侧各自的 ready，顶层取与后给 driver

    // ---- DUT 平台（内部 EU = poe_eu_dut，真实 RTL 的替换点）----
    poe_platform #(
        .IS_RM(1'b0), .N_THR(N_THR), .TID_W(TID_W), .RF_W(RF_W),
        .TS_MAX(TS_MAX), .TS_W(TS_W), .N_BURST(N_BURST)
    ) u_plat_dut (
        .clk(clk),                                        // 时钟
        .rst_n(rst_n),                                    // 复位
        .ko_vld(u_if.ko_vld),                             // 激励：KO 有效
        .ko_rdy(ko_rdy_dut),                              //       平台 ready（见下面的取与）
        .ko_data(u_if.ko_data),                           //       48B 报文
        .pre_vld(u_if.pre_vld),                           // csr 预发射口（1+6+4+176）：与 KO 同拍
        .pre_thid(u_if.pre_thid),
        .pre_strb(u_if.pre_strb),
        .pre_data(u_if.pre_data),
        .imem_we(u_if.imem_we),                           // 微指令 bank 预载
        .imem_saddr(u_if.imem_saddr),                     //   选级
        .imem_waddr(u_if.imem_waddr),                     //   行号
        .imem_wdata(u_if.imem_wdata),                     //   内容
        .mux_imem_we(u_if.mux_imem_we),                   // MUX 指令存储预载
        .mux_imem_waddr(u_if.mux_imem_waddr),
        .mux_imem_wdata(u_if.mux_imem_wdata),
        .out_vld(u_if.out_vld),                           // 出口 KO（被验对象）
        .out_data(u_if.out_data),
        .out_tid(u_if.out_tid),
        .ts_done_vld(u_if.ts_done_vld),                   // ts 边界事件（校验点）
        .ts_done_tid(u_if.ts_done_tid),
        .ts_done_idx(u_if.ts_done_idx),
        .thr_done_vld(u_if.thr_done_vld),                 // 线程结束
        .thr_done_tid(u_if.thr_done_tid),
        .busy(u_if.busy),                                 // 观测
        .ct_skip_cnt(u_if.ct_skip_cnt),
        .err_out(u_if.eu_err),                            // EU 错误标志（随结果拍有效）
        .eu_err_vld(u_if.eu_err_vld),
        .eu_err_tid(u_if.eu_err_tid),
        .rf_flat(u_if.rf_dut),                            // 两张表快照
        .csr_flat(u_if.csr_dut),                          //   CSR 全表（按字节）
        .ccr_flat(u_if.ccr_dut),
        .th_stat_flat(),                                  // 本版不采
        .cur_ts_flat()
    );

    // ---- RM 平台（内部 EU = poe_eu_rm；同一个激励，只回刷自己的表）----
    poe_platform #(
        .IS_RM(1'b1), .N_THR(N_THR), .TID_W(TID_W), .RF_W(RF_W),
        .TS_MAX(TS_MAX), .TS_W(TS_W), .N_BURST(N_BURST)
    ) u_plat_rm (
        .clk(clk),
        .rst_n(rst_n),
        .ko_vld(u_if.ko_vld),                             // 与 DUT 同一个 KO
        .ko_rdy(ko_rdy_rm),                               // RM 侧 ready（与 DUT 侧取与）
        .ko_data(u_if.ko_data),
        .pre_vld(u_if.pre_vld),                           // 与 DUT 同一组预发射
        .pre_thid(u_if.pre_thid),
        .pre_strb(u_if.pre_strb),
        .pre_data(u_if.pre_data),
        .imem_we(u_if.imem_we),
        .imem_saddr(u_if.imem_saddr),
        .imem_waddr(u_if.imem_waddr),
        .imem_wdata(u_if.imem_wdata),
        .mux_imem_we(u_if.mux_imem_we),
        .mux_imem_waddr(u_if.mux_imem_waddr),
        .mux_imem_wdata(u_if.mux_imem_wdata),
        .out_vld(u_if.out_vld_rm),                        // RM 出口 KO（期望值）
        .out_data(u_if.out_data_rm),
        .out_tid(u_if.out_tid_rm),
        .ts_done_vld(u_if.ts_done_vld_rm),                // RM 侧 ts 边界
        .ts_done_tid(u_if.ts_done_tid_rm),
        .ts_done_idx(u_if.ts_done_idx_rm),
        .thr_done_vld(),
        .thr_done_tid(),
        .busy(),
        .ct_skip_cnt(),
        .err_out(u_if.eu_err_rm),
        .eu_err_vld(u_if.eu_err_vld_rm),
        .eu_err_tid(u_if.eu_err_tid_rm),
        .rf_flat(u_if.rf_rm),                             // RM 侧两张表
        .csr_flat(u_if.csr_rm),
        .ccr_flat(u_if.ccr_rm),
        .th_stat_flat(),
        .cur_ts_flat()
    );

    // ---- 两侧 ready 取与：两侧都 ready 才算能收 ----
    assign u_if.ko_rdy = ko_rdy_dut & ko_rdy_rm;

    // ---- 接口初值（driver 起来之前保持安静）----
    initial begin
        u_if.ko_vld       = 1'b0;
        u_if.ko_data      = '0;
        u_if.pre_vld      = 1'b0;
        u_if.pre_thid     = '0;
        u_if.pre_strb     = '0;
        u_if.pre_data     = '0;
        u_if.imem_we      = 1'b0;
        u_if.imem_saddr   = '0;
        u_if.imem_waddr   = '0;
        u_if.imem_wdata   = '0;
        u_if.mux_imem_we    = 1'b0;
        u_if.mux_imem_waddr = '0;
        u_if.mux_imem_wdata = '0;
    end

    // ---- 复位 + 把接口交给 UVM ----
    initial begin
        poe_uvm_pkg::g_vif = u_if;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- 跑 UVM（+UVM_TESTNAME=poe_base_test）----
    initial begin
        void'(poe_base_test::type_id::get());
        run_test();
    end

    // 兜底超时
    initial begin
        #500000;
        $display("TB TIMEOUT");
        $finish;
    end
endmodule
