// 单元验证：poe_dma_ctrl 的 loc（未命中/命中）/free（转交）/资源收支
`timescale 1ns/1ps
module tb_dma_ctrl;
    import poe_types_pkg::*;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic emit_dma_vld, emit_dma_pre, dma_ack;
    logic [5:0] emit_dma_tid;
    logic [31:0] emit_dma_burst;
    logic [511:0] csr_dma_c;
    logic [24575:0] csr_cw;
    logic [383:0] thread_curts;
    logic cw_upd_vld;
    logic [5:0] cw_upd_tid;
    logic [2:0] cw_upd_ind;
    logic [47:0] cw_upd_data;
    logic th_rel_vld, dma_done_vld;
    logic [5:0] th_rel_tid, dma_done_tid;
    logic [9:0] cw_fifo_cnt;
    logic [127:0] th_res_n;

    poe_dma_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .emit_dma_vld(emit_dma_vld), .emit_dma_tid(emit_dma_tid),
        .emit_dma_burst(emit_dma_burst), .emit_dma_pre(emit_dma_pre),
        .dma_ack(dma_ack),
        .csr_dma_c(csr_dma_c), .csr_cw(csr_cw),
        .thread_curts(thread_curts),
        .cw_upd_vld(cw_upd_vld), .cw_upd_tid(cw_upd_tid),
        .cw_upd_ind(cw_upd_ind), .cw_upd_data(cw_upd_data),
        .th_rel_vld(th_rel_vld), .th_rel_tid(th_rel_tid),
        .cw_fifo_cnt(cw_fifo_cnt), .th_res_n(th_res_n),
        .dma_done_vld(dma_done_vld), .dma_done_tid(dma_done_tid)
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
        th_rel_vld = 0; th_rel_tid = 0; thread_curts = 0;
        csr_dma_c = 0; csr_cw = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        // 线程0：dma_id0 = loc(tag=0x12345)，dma_id1 = free(tag=0x12345)
        cw0 = {20'h12345, 1'b0, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // loc
        cw1 = {20'h12345, 1'b1, 1'b0, 1'b0, 8'd0, 8'd0, 8'd0, 1'b0}; // free
        csr_dma_c[7:0] = 8'h03; // dma_id0/1 有效
        csr_cw[47:0] = cw0;
        csr_cw[95:48] = cw1;
        @(posedge clk);

        $display("== 1) loc 未命中（dma_id0）==");
        send_burst(mk_burst(1'b1, 3'd0, 8'd3));
        if (dut.f_cnt != 255) begin
            $display("FAIL: loc 后 f_cnt=%0d (期望255)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 1) begin
            $display("FAIL: loc 后 th_res_n[0]=%0d (期望1)", dut.th_res_n_r[0]);
            errors++;
        end
        if (!dut.c_wnd[0].o || (dut.c_wnd[0].tag !== 20'h12345)) begin
            $display("FAIL: C窗[0] 未正确申请 (o=%0d tag=%h)", dut.c_wnd[0].o, dut.c_wnd[0].tag);
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d C窗[0].o=%0d tag=%h r=%0d",
                 dut.f_cnt, dut.th_res_n_r[0], dut.c_wnd[0].o, dut.c_wnd[0].tag, dut.c_wnd[0].r);

        $display("== 2) loc 命中（同 tag，应存预存、不申请）==");
        send_burst(mk_burst(1'b1, 3'd0, 8'd3));
        if (dut.f_cnt != 255) begin
            $display("FAIL: loc 命中后 f_cnt=%0d (期望255，不申请)", dut.f_cnt);
            errors++;
        end
        if (!dut.pre_mem[0][35]) begin
            $display("FAIL: 预存未写入 (pre_mem[0]=%h)", dut.pre_mem[0]);
            errors++;
        end
        $display("OK: f_cnt=%0d 预存[0]=%h", dut.f_cnt, dut.pre_mem[0]);

        $display("== 3) free（dma_id1，同 tag，应转交预存 loc）==");
        send_burst(mk_burst(1'b1, 3'd1, 8'd1));
        if (dut.f_cnt != 255) begin
            $display("FAIL: free 转交后 f_cnt=%0d (期望255，资源直接转移不入队)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 1) begin
            $display("FAIL: free 转交后 th_res_n[0]=%0d (期望1，同线程转交净0)", dut.th_res_n_r[0]);
            errors++;
        end
        if (!dut.c_wnd[0].o) begin
            $display("FAIL: 转交后 C窗[0].o=%0d (期望1，预存接管)", dut.c_wnd[0].o);
            errors++;
        end
        if (dut.pre_mem[0][35]) begin
            $display("FAIL: 转交后预存未清空");
            errors++;
        end
        $display("OK: f_cnt=%0d th_res_n[0]=%0d C窗[0].o=%0d 预存清空=%0d",
                 dut.f_cnt, dut.th_res_n_r[0], dut.c_wnd[0].o, ~dut.pre_mem[0][35]);

        $display("== 4) 线程结束兜底（应释放残留资源）==");
        // 手动占 1 个资源再触发 th_rel
        // 直接触发 th_rel（当前 th_res_n[0]=1）
        @(posedge clk);
        th_rel_vld = 1'b1;
        th_rel_tid = 6'd0;
        @(posedge clk);
        th_rel_vld = 1'b0;
        @(posedge clk);
        if (dut.f_cnt != 256) begin
            $display("FAIL: th_rel 后 f_cnt=%0d (期望256)", dut.f_cnt);
            errors++;
        end
        if (dut.th_res_n_r[0] != 0) begin
            $display("FAIL: th_rel 后 th_res_n[0]=%0d (期望0)", dut.th_res_n_r[0]);
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
