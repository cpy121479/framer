// 单元验证：poe_dma_ctrl 的 loc/free 直接执行（互斥锁保证无冲突，无扫描/预存/转交）
`timescale 1ns/1ps
module tb_dma_ctrl;
    import poe_types_pkg::*;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic emit_dma_vld, emit_dma_pre, dma_ack;
    logic [5:0] emit_dma_tid;
    logic [3:0] emit_dma_tidx;
    logic [31:0] emit_dma_burst;
    logic [511:0] csr_dma_c;
    logic [24575:0] csr_cw;
    logic [383:0] thread_curts;
    logic cw_upd_vld;
    logic [5:0] cw_upd_tid;
    logic [2:0] cw_upd_ind;
    logic [47:0] cw_upd_data;
    logic dma_done_vld;
    logic [5:0] dma_done_tid;
    logic [3:0] dma_done_tidx;
    logic [9:0] cw_fifo_cnt;
    logic [191:0] th_res_n;
    logic [3:0] pre_op_vld;
    logic [23:0] pre_op_tid;
    logic [79:0] pre_op_addr;
    logic [3:0] pre_op_type;
    logic pre_op_ack;

    poe_dma_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .emit_dma_vld(emit_dma_vld), .emit_dma_tid(emit_dma_tid),
        .emit_dma_tidx(emit_dma_tidx), .emit_dma_burst(emit_dma_burst), .emit_dma_pre(emit_dma_pre),
        .dma_ack(dma_ack),
        .csr_dma_c(csr_dma_c), .csr_cw(csr_cw),
        .thread_curts(thread_curts),
        .cw_upd_vld(cw_upd_vld), .cw_upd_tid(cw_upd_tid),
        .cw_upd_ind(cw_upd_ind), .cw_upd_data(cw_upd_data),
        .cw_fifo_cnt(cw_fifo_cnt), .th_res_n(th_res_n),
        .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid), .dma_done_tidx(dma_done_tidx)
        ,.pre_op_vld(pre_op_vld), .pre_op_tid(pre_op_tid),
        .pre_op_addr(pre_op_addr), .pre_op_type(pre_op_type),
        .pre_op_ack(pre_op_ack)
    );

    // 模拟 THM：应用 dma_ctrl 的 cw 回写
    always @(posedge clk) begin
        if (cw_upd_vld)
            csr_cw[cw_upd_tid*384 +: 384][cw_upd_ind*48 +: 48] <= cw_upd_data;
    end

    function automatic logic [31:0] mk_burst(input logic c0, input logic [2:0] d0,
                                             input logic [7:0] occ0);
        burst_c_t b;
        b.st = 1'b1;
        b.tr = 1'b0;
        b.rev = 4'd0;
        b.burst_type = 1'b1;
        b.vld_cu = 1'b0; // 单任务
        b.dma_id0 = d0;
        b.c0 = c0;
        b.dma_id1 = 3'd0;
        b.c1 = 1'b0;
        b.occ_ts0 = occ0;
        b.occ_ts1 = 8'd1;
        mk_burst = b;
    endfunction

    integer errors;
    logic [47:0] cw0, cw1;

    task send_burst(input logic [31:0] b);
        @(posedge clk);
        emit_dma_vld = 1'b1;
        emit_dma_tid = 6'd0;
        emit_dma_tidx = 4'd0;
        emit_dma_burst = b;
        emit_dma_pre = 1'b0;
        @(posedge clk);
        emit_dma_vld = 1'b0;
        // 等待执行完成（S_DONE 回 done）
        while (!dma_done_vld) @(posedge clk);
        @(posedge clk);
    endtask

    initial begin
        errors = 0;
        emit_dma_vld = 0; emit_dma_pre = 0; emit_dma_tid = 0; emit_dma_burst = 0;
        emit_dma_tidx = 0;
        thread_curts = 0;
        pre_op_vld = 0; pre_op_tid = 0; pre_op_addr = 0; pre_op_type = 0;
        csr_dma_c = 0; csr_cw = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        // 线程0 cw 布局（8 项全有效）：前 4 独享半区 / 后 4 共享半区
        //   cw[4]=loc(A) cw[5]=free(A)  cw[6]=loc(B) cw[7]=free(B)
        //   cw[0]=loc(C) cw[1]=free(C)
        cw0 = {20'h12345, 1'b0, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // cw[0] loc C
        cw1 = {20'h12345, 1'b1, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // cw[1] free C
        csr_dma_c[7:0] = 8'hFF; // 8 项 dma_id 全有效
        csr_cw[47:0] = cw0; // cw[0]
        csr_cw[95:48] = cw1; // cw[1]
        csr_cw[239:192] = {20'hAAAAA, 1'b0, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // cw[4] loc A
        csr_cw[287:240] = {20'hAAAAA, 1'b1, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // cw[5] free A
        csr_cw[335:288] = {20'hBBBBB, 1'b0, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // cw[6] loc B
        csr_cw[383:336] = {20'hBBBBB, 1'b1, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // cw[7] free B
        @(posedge clk);

        $display("== 1) 共享 loc 未命中（dma_id4，tag A）==");
        send_burst(mk_burst(1'b1, 3'd4, 8'd3));
        if (dut.f_cnt != 255) begin
            $display("FAIL: 共享 loc 后 f_cnt=%0d (期望255)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 1) begin
            $display("FAIL: 共享 loc 后 th_res_n[0]=%0d (期望1)", dut.th_res_n_r[0]);
            errors++;
        end
        if (!dut.c_wnd_shr[0].o || (dut.c_wnd_shr[0].tag !== 20'hAAAAA)) begin
            $display("FAIL: 共享窗[0] 未正确申请 (o=%0d tag=%h)",
                     dut.c_wnd_shr[0].o, dut.c_wnd_shr[0].tag);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d 共享窗[0].o=%0d tag=%h r=%0d",
                 dut.f_cnt, dut.th_res_n_r[0],
                 dut.c_wnd_shr[0].o, dut.c_wnd_shr[0].tag, dut.c_wnd_shr[0].r);

        $display("== 2) 共享 free（dma_id5，tag A，直接释放回 SMC）==");
        send_burst(mk_burst(1'b1, 3'd5, 8'd1));
        if (dut.f_cnt != 256) begin
            $display("FAIL: free 后 f_cnt=%0d (期望256，资源归还)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 0) begin
            $display("FAIL: free 后 th_res_n[0]=%0d (期望0)", dut.th_res_n_r[0]);
            errors++;
        end
        if (dut.c_wnd_shr[0].o) begin
            $display("FAIL: free 后 共享窗[0].o=%0d (期望0，已释放)", dut.c_wnd_shr[0].o);
            errors++;
        end
        if (dut.smc_mem[20'hAAAAA & 8'hFF] !== 128'd0) begin
            $display("FAIL: free 后 SMC[%h] 未写回 (=%h)", 20'hAAAAA & 8'hFF,
                     dut.smc_mem[20'hAAAAA & 8'hFF]);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d 共享窗[0].o=%0d SMC 已写回",
                 dut.f_cnt, dut.th_res_n_r[0], dut.c_wnd_shr[0].o);

        $display("== 3) 共享 loc（dma_id6，tag B，申请共享资源）==");
        send_burst(mk_burst(1'b1, 3'd6, 8'd2));
        if (dut.f_cnt != 255) begin
            $display("FAIL: loc B 后 f_cnt=%0d (期望255)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 1) begin
            $display("FAIL: loc B 后 th_res_n[0]=%0d (期望1)", dut.th_res_n_r[0]);
            errors++;
        end
        if (!dut.c_wnd_shr[1].o || (dut.c_wnd_shr[1].tag !== 20'hBBBBB)) begin
            $display("FAIL: 共享窗[1] 未正确申请 (o=%0d tag=%h)",
                     dut.c_wnd_shr[1].o, dut.c_wnd_shr[1].tag);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d 共享窗[1].o=%0d tag=%h",
                 dut.f_cnt, dut.th_res_n_r[0], dut.c_wnd_shr[1].o, dut.c_wnd_shr[1].tag);

        $display("== 4) 共享 free（dma_id7，tag B，应归还）==");
        send_burst(mk_burst(1'b1, 3'd7, 8'd1));
        if (dut.f_cnt != 256) begin
            $display("FAIL: free B 后 f_cnt=%0d (期望256)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 0) begin
            $display("FAIL: free B 后 th_res_n[0]=%0d (期望0)", dut.th_res_n_r[0]);
            errors++;
        end
        if (dut.c_wnd_shr[1].o) begin
            $display("FAIL: free B 后 共享窗[1].o=%0d (期望0，已释放)", dut.c_wnd_shr[1].o);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d 共享窗[1].o=%0d", dut.f_cnt, dut.th_res_n_r[0], dut.c_wnd_shr[1].o);

        $display("== 5) 独享 loc（dma_id0，tag C，固定位置不占 FIFO）==");
        send_burst(mk_burst(1'b1, 3'd0, 8'd3));
        if (dut.f_cnt != 256) begin
            $display("FAIL: 独享 loc 后 f_cnt=%0d (期望256，不占共享池)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 0) begin
            $display("FAIL: 独享 loc 后 th_res_n[0]=%0d (期望0，不变)", dut.th_res_n_r[0]);
            errors++;
        end
        if (!dut.c_wnd_excl[0][0].o || (dut.c_wnd_excl[0][0].tag !== 20'h12345)) begin
            $display("FAIL: 独享窗[0][0] 未正确申请 (o=%0d tag=%h)",
                     dut.c_wnd_excl[0][0].o, dut.c_wnd_excl[0][0].tag);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d 独享窗[0][0].o=%0d tag=%h r=%0d",
                 dut.f_cnt, dut.th_res_n_r[0],
                 dut.c_wnd_excl[0][0].o, dut.c_wnd_excl[0][0].tag, dut.c_wnd_excl[0][0].r);

        $display("== 6) 独享 free（dma_id1，tag C，固定位置释放不入 FIFO）==");
        send_burst(mk_burst(1'b1, 3'd1, 8'd1));
        if (dut.f_cnt != 256) begin
            $display("FAIL: 独享 free 后 f_cnt=%0d (期望256，不入共享池)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 0) begin
            $display("FAIL: 独享 free 后 th_res_n[0]=%0d (期望0，不变)", dut.th_res_n_r[0]);
            errors++;
        end
        if (dut.c_wnd_excl[0][0].o) begin
            $display("FAIL: 独享 free 后 独享窗[0][0].o=%0d (期望0，已释放)", dut.c_wnd_excl[0][0].o);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d 独享窗[0][0].o=%0d", dut.f_cnt, dut.th_res_n_r[0], dut.c_wnd_excl[0][0].o);

        $display("== 7) 共享往返完整性（loc dma6 + free dma7，重复执行）==");
        send_burst(mk_burst(1'b1, 3'd6, 8'd2));
        send_burst(mk_burst(1'b1, 3'd7, 8'd1));
        if (dut.f_cnt != 256) begin
            $display("FAIL: 往返后 f_cnt=%0d (期望256，全部归还)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 0) begin
            $display("FAIL: 往返后 th_res_n[0]=%0d (期望0)", dut.th_res_n_r[0]);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d", dut.f_cnt, dut.th_res_n_r[0]);

        if (errors == 0)
            $display("PASS: 全部检查通过");
        else
            $display("FAIL: %0d 项检查失败", errors);
        $finish;
    end
endmodule
