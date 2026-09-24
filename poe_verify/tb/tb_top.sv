// ============================================================================
// RTL 自检版 TB（不开 UVM，约 25 秒一轮）
//   · burst 指令存储是 ROM：程序镜像在 poe_burst_imem 内部 initial 拼好
//   · 这里只预载微指令 bank（EU 内部），发 2 个 KO（两个并发线程），等线程结束打印检查结果
// ============================================================================
`timescale 1ns/1ps
module tb_top;
    import poe_pkg::*;

    logic clk = 0, rst_n = 0;
    always #0.5ns clk = ~clk;      // 1GHz

    // ---- 激励 ----
    logic         ko_vld = 1'b0;
    logic         ko_rdy;
    logic [383:0] ko_data = '0;
    logic         pre_vld = 1'b0;      // csr 预发射口（1bit vld）
    logic [5:0]   pre_thid = '0;       // 预写哪个线程
    logic [3:0]   pre_strb = '0;       // 4 个表项各自一位
    logic [175:0] pre_data = '0;       // 4×44bit，表项 e = pre_data[e*44 +: 44]
    // ---- 微指令预载 ----
    logic         imem_we = 1'b0;
    logic [0:0]   imem_saddr = '0;
    logic [3:0]   imem_waddr = '0;
    logic [63:0]  imem_wdata = '0;
    // ---- MUX 指令预载 ----
    logic             mux_imem_we = 1'b0;
    logic [3:0]       mux_imem_waddr = '0;
    logic [351:0]     mux_imem_wdata = '0;
    // ---- 出口 / 观测 ----
    logic         out_vld;
    logic [383:0] out_data;
    logic [5:0]   out_tid;
    logic         ts_done_vld, thr_done_vld, busy;
    logic [5:0]   ts_done_tid, thr_done_tid;
    logic [3:0]   ts_done_idx;
    logic [7:0]   ct_skip_cnt;
    int           chk_cnt, err_cnt;
    logic [64*2048-1:0] rf_dut, rf_rm;
    logic [64*32-1:0]   ccr_dut, ccr_rm;
    logic [64*72*8-1:0] csr_dut;      // DUT 全表 CSR（看 CW 窗 = 预发射口写的低 4 项）
    int           ko_cnt, done_cnt;   // 出口 KO / 线程结束计数
    // 预发射口写入的 4×44bit（表项 0 在最低 44bit）
    localparam logic [175:0] PRE_DATA0 = {44'h05555AAAA55, 44'h0FEDCBA9876,
                                          44'h0ABCDEF1234, 44'h0123456789A};
    localparam logic [175:0] PRE_DATA1 = {44'h0AAAA55555, 44'h03333333333,
                                          44'h0CCCCCCCCCC, 44'h0DEADBEEF01};
    localparam int CW_BYTE = 28;      // CSR 0x1c = CW 窗起始字节

    poe_verify_top #(
        .N_THR(64), .TID_W(6), .RF_W(2048), .TS_MAX(16), .TS_W(4), .N_BURST(8)
    ) u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .ko_vld(ko_vld),
        .ko_rdy(ko_rdy),
        .ko_data(ko_data),
        .pre_vld(pre_vld),
        .pre_thid(pre_thid),
        .pre_strb(pre_strb),
        .pre_data(pre_data),
        .imem_we(imem_we),
        .imem_saddr(imem_saddr),
        .imem_waddr(imem_waddr),
        .imem_wdata(imem_wdata),
        .mux_imem_we(mux_imem_we),
        .mux_imem_waddr(mux_imem_waddr),
        .mux_imem_wdata(mux_imem_wdata),
        .out_vld(out_vld),
        .out_data(out_data),
        .out_tid(out_tid),
        .ts_done_vld(ts_done_vld),
        .ts_done_tid(ts_done_tid),
        .ts_done_idx(ts_done_idx),
        .thr_done_vld(thr_done_vld),
        .thr_done_tid(thr_done_tid),
        .busy(busy),
        .ct_skip_cnt(ct_skip_cnt),
        .csr_dut_flat(csr_dut),
        .chk_cnt(chk_cnt),
        .err_cnt(err_cnt),
        .rf_dut_flat(rf_dut),
        .rf_rm_flat(rf_rm),
        .ccr_dut_flat(ccr_dut),
        .ccr_rm_flat(ccr_rm)
    );

    // ---- 指令编码小工具（微指令画像用）----
    function automatic logic [31:0] ADD(input int rd, input int rs1, input int rs2);
        ADD = (rs2<<20)|(rs1<<15)|(rd<<7)|32'h33;                  // ADD rd,rs1,rs2
    endfunction
    function automatic logic [31:0] ADDI(input int rd, input int imm);
        ADDI = ((imm & 12'hFFF)<<20)|(rd<<7)|32'h13;               // ADDI rd,x0,imm
    endfunction
    function automatic logic [31:0] SW(input int rs2, input int rs1, input int imm);
        SW = (((imm>>5)&7'h7F)<<25)|(rs2<<20)|(rs1<<15)|(3'b010<<12)|((imm&5'h1F)<<7)|32'h23;
    endfunction
    function automatic logic [31:0] CSRRW(input int rd, input logic [11:0] csr, input int rs1);
        CSRRW = (csr<<20)|(rs1<<15)|(3'b001<<12)|(rd<<7)|32'h73;   // CSRRW rd,csr,rs1
    endfunction

    // 微指令画像：两级 bank 各 4 行（burst 的 sub_pc 0..3 指向它们）
    logic [63:0] s0_row [4];
    logic [63:0] s1_row [4];

    initial begin
        // s0：lane0 = R 型（ADD），lane1 = I 型（ADDI）
        s0_row[0] = {ADD(10,8,9),  ADDI(8, 5)};                    // x10 = x8+x9 ; x8 = 5
        s0_row[1] = {ADD(11,8,9),  ADDI(9, 7)};                    // x11 = x8+x9 ; x9 = 7
        s0_row[2] = {ADD(12,8,9),  ADDI(14, 12'h11)};              // x12 = x8+x9 ; x14 = 0x11
        s0_row[3] = {ADD(13,8,9),  ADDI(15, 12'h22)};              // x13 = x8+x9 ; x15 = 0x22
        // s1：lane0 = store 型（用 SW 空转），lane1 = csr 型（把 x8 写进 mstatus → CCR）
        for (int i = 0; i < 4; i++)
            s1_row[i] = {SW(0,0,0), CSRRW(20, 12'h300, 8)};
    end

    // ---- 预载微指令 bank（复位释放后）----
    task automatic preload_imem();
        for (int r = 0; r < 4; r++) begin
            imem_we = 1'b1; imem_saddr = 1'b0; imem_waddr = r[3:0]; imem_wdata = s0_row[r];
            @(posedge clk); #1;
        end
        for (int r = 0; r < 4; r++) begin
            imem_we = 1'b1; imem_saddr = 1'b1; imem_waddr = r[3:0]; imem_wdata = s1_row[r];
            @(posedge clk); #1;
        end
        imem_we = 1'b0;
    endtask

    // ---- 预载 MUX 指令存储（与微指令画像配套）----
    //   打包序按 mux_shift_conv 规格：fetcher 0 = 窗口最高 16bit；示例画像要让窗口
    //   word(15-r) = RF 表的 x_r（字节 252-4r..255-4r），推出 fetcher k ← RF[254-2k]（mvld=2）。
    //   这样示例 EU 从窗口看到的就是 x0..x15（与之前直连 RF 高位视图等价）。
    task automatic preload_mux_imem();
        logic [351:0] row_img;
        row_img = '0;
        for (int k = 0; k < 32; k++)
            row_img[11*k +: 11] = {1'b1, 2'd2, 8'(254 - 2*k)};   // i=1, mvld=2, off=254-2k
        for (int r = 0; r < 16; r++) begin
            mux_imem_we = 1'b1; mux_imem_waddr = r[3:0]; mux_imem_wdata = row_img;
            @(posedge clk); #1;
        end
        mux_imem_we = 1'b0;
    endtask

    // ---- 出口 KO / 线程结束计数 ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ko_cnt   <= 0;
            done_cnt <= 0;
        end else begin
            if (out_vld)       ko_cnt   <= ko_cnt + 1;
            if (thr_done_vld)  done_cnt <= done_cnt + 1;
        end
    end

    // ---- CW 窗表项读口（自检用）：tid 线程的第 e 项（CSR 0x1c 起，每项 44bit）----
    function automatic logic [43:0] cw_entry(input int tid, input int e);
        cw_entry = csr_dut[tid*576 + CW_BYTE*8 + e*44 +: 44];
    endfunction

    // ---- 发一个 KO（程序基址固定 ts 行 0；同拍带 csr 预发射口）----
    task automatic send_ko(input logic [2:0] pri, input logic [7:0] da,
                           input logic [5:0] thid, input logic [3:0] strb,
                           input logic [175:0] pdata);
        logic [63:0] row0;
        row0 = {da, 8'h00, 8'hB2, 8'h00, 8'h00, pri, 5'd0, 8'h34, 8'h00};
        wait (ko_rdy);
        @(negedge clk);                 // 低电平驱动，避开 posedge 竞争
        ko_data  = {row0, 32'h0, 32'h0, 256'h0};
        ko_vld   = 1'b1;
        pre_vld  = 1'b1;                // csr 预发射口：与 KO 建线程同拍
        pre_thid = thid;
        pre_strb = strb;
        pre_data = pdata;
        @(negedge clk);                 // 中间跨一个 posedge：池正好受理一次
        ko_vld   = 1'b0;
        pre_vld  = 1'b0;
    endtask

    // ---- 主流程 ----
    initial begin
        bit pre_ok;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        preload_imem();
        preload_mux_imem();

        // 2 个 KO = 2 个并发线程；第 2 个优先级更高（1 < 3），用来跑多线程调度
        // 预发射口：tid0 写全部 4 项；tid1 只写第 0/2 项（strb=0101，其余项应保持 0）
        send_ko(3'd3, 8'hA1, 6'd0, 4'hF,   PRE_DATA0);
        send_ko(3'd1, 8'hA2, 6'd1, 4'b0101, PRE_DATA1);

        wait (done_cnt == 2);          // 两个线程都结束
        repeat (4) @(posedge clk);

        $display("---- 结果 ----");
        $display("CHK ts 边界=%0d  err=%0d  出口KO=%0d  线程结束=%0d（ts 粒度：RF 逐槽 + CCR；出口 KO：DUT vs RM）",
                 chk_cnt, err_cnt, ko_cnt, done_cnt);
        $display("c_task 跳过数=%0d", ct_skip_cnt);
        $display("tid0 CW 低4项 = %h %h %h %h", cw_entry(0,0), cw_entry(0,1), cw_entry(0,2), cw_entry(0,3));
        $display("tid1 CW 低4项 = %h %h %h %h", cw_entry(1,0), cw_entry(1,1), cw_entry(1,2), cw_entry(1,3));
        $display("tid0 CCR dut=%h rm=%h", ccr_dut[0*32 +: 32], ccr_rm[0*32 +: 32]);
        $display("tid1 CCR dut=%h rm=%h", ccr_dut[1*32 +: 32], ccr_rm[1*32 +: 32]);
        pre_ok = (cw_entry(0,0) === PRE_DATA0[0*44 +: 44]) &&
                 (cw_entry(0,1) === PRE_DATA0[1*44 +: 44]) &&
                 (cw_entry(0,2) === PRE_DATA0[2*44 +: 44]) &&
                 (cw_entry(0,3) === PRE_DATA0[3*44 +: 44]) &&
                 (cw_entry(1,0) === PRE_DATA1[0*44 +: 44]) &&
                 (cw_entry(1,1) === 44'd0) &&      // strb=0 的项保持清零
                 (cw_entry(1,2) === PRE_DATA1[2*44 +: 44]) &&
                 (cw_entry(1,3) === 44'd0);
        if (err_cnt == 0 && chk_cnt >= 4 && ko_cnt == 2 && done_cnt == 2 && pre_ok)
            $display("SMOKE PASS");
        else $display("SMOKE FAIL (chk=%0d err=%0d ko=%0d done=%0d pre_ok=%0b)",
                      chk_cnt, err_cnt, ko_cnt, done_cnt, pre_ok);
        $finish;
    end

    // 兜底超时
    initial begin
        #20000;
        $display("TIMEOUT: busy=%0b chk=%0d err=%0d", busy, chk_cnt, err_cnt);
        $finish;
    end
endmodule
