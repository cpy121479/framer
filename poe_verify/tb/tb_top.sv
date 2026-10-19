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
    logic [MUX_ROW_W-1:0] mux_imem_wdata = '0;   // 一行 = 五组字段（1280bit，见 poe_pkg ⑤）
    // ---- 出口 / 观测 ----
    logic         out_vld;
    logic [383:0] out_data;
    logic [5:0]   out_tid;
    logic         ts_done_vld, thr_done_vld, busy;
    logic [5:0]   ts_done_tid, thr_done_tid;
    logic [3:0]   ts_done_idx;
    logic [7:0]   ct_skip_cnt;
    int           chk_cnt, err_cnt, err_chk;
    // DUT 侧观测事件总线（ts_done 后一拍锁存该线程的快照）
    logic             obs_vld;
    logic [5:0]       obs_tid;
    logic [3:0]       obs_ts;
    logic [2047:0]    obs_rf;
    logic [CSRB*8-1:0] obs_csr;
    logic [CSRB*8-1:0] csr_obs [64];  // 每线程最后一次 ts_done 的 CSR 快照（自检 CW/CCR 用）
    int           ko_cnt, done_cnt;   // 出口 KO / 线程结束计数
    // 预发射口写入的 4×44bit（表项 0 在最低 44bit）
    localparam logic [175:0] PRE_DATA0 = {44'h05555AAAA55, 44'h0FEDCBA9876,
                                          44'h0ABCDEF1234, 44'h0123456789A};
    localparam logic [175:0] PRE_DATA1 = {44'h0AAAA55555, 44'h03333333333,
                                          44'h0CCCCCCCCCC, 44'h0DEADBEEF01};
    localparam int CW_BYTE = int'(A_CW_CMD);   // CSR 0x2e = CW 窗起始字节

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
        .chk_cnt(chk_cnt),
        .err_chk(err_chk),
        .err_cnt(err_cnt),
        .obs_vld(obs_vld),
        .obs_tid(obs_tid),
        .obs_ts(obs_ts),
        .obs_rf(obs_rf),
        .obs_csr(obs_csr)
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

    // ---- MUX 画像（与微指令画像配套）----
    //   一行 = 五组字段（布局见 poe_pkg 的 ⑤ 节）：
    //     ① 取数组：第 k 条 → 窗口第 k 个 2B 槽（slot 0 最高）← RF 字节 (2k, 2k+1)（i=1、mvld=2）
    //     ② 移位组：**真实移位**，每槽都用设计给的例子：
    //          bits0=5 lr0=0 shift0=1 + bits1=7 lr1=1 shift1=1
    //          期望：lane[15:11]=raw[14:10]、lane[10:8]=0、lane[7:1]=raw[7:1]、lane[0]=0
    //          （raw=0xABCD 时 lane=0x50CC；DMUX 逆变换的掩码 = 0x7CFE）
    //     ③ MXCC：CCR 表第 0 字节 → 高字节、第 1 字节 → 低字节（EU 的 2B CSR）
    //     ④/⑤ O 路：O 窗第 m 个 2B ← 64B 窗字节 (2m, 2m+1)，用同一套 MXS（真实移位）
    //   整窗 32 组（取数+移位）全部填满，方便逐槽打印 raw → lane → 回填掩码；
    //   真实画像只填用到的槽即可（空槽 mvld=0 = 不取数）。
    function automatic logic [MUX_ROW_W-1:0] mux_row_img();
        logic [MUX_ROW_W-1:0] r;
        logic [MXS_W-1:0]     mxs_shift;
        r = '0;
        // 设计给的移位例子：取 raw 的 [14:10] 和 [7:1]，分别左对齐到槽的 bit15/bit7 起
        mxs_shift = mux_mxs_pack(4'd5, 1'b0, 3'd1, 3'd7, 1'b1, 3'd1);
        for (int k = 0; k < MUX_INS_N; k++) begin
            r[MF_FET_LSB + MUX_INS_W*k +: MUX_INS_W] = mux_fetch_pack(1'b1, 2'd2, 8'(2*k));
            r[MF_MXS_LSB + MXS_W*k +: MXS_W]         = mxs_shift;      // 真实移位
        end
        r[MF_MXCC_LSB +: MXCC_W]          = 5'd0;                      // 高字节 ← CCR 表第 0 字节
        r[MF_MXCC_LSB + MXCC_W +: MXCC_W] = 5'd1;                      // 低字节 ← CCR 表第 1 字节
        for (int m = 0; m < O_INS_N; m++) begin
            r[MF_OFET_LSB + MUX_INS_W*m +: MUX_INS_W] = mux_fetch_pack(1'b1, 2'd2, 8'(2*m));
            r[MF_OMXS_LSB + MXS_W*m +: MXS_W]         = mxs_shift;     // 真实移位
        end
        return r;
    endfunction

    task automatic preload_mux_imem();
        logic [MUX_ROW_W-1:0] row_img;
        row_img = mux_row_img();
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

    // ---- 每个 ts_done 事件抓一份该线程的 CSR 快照（最小的实现：每 tid 存最后一份）----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int t = 0; t < 64; t++) csr_obs[t] <= '0;
        end else if (obs_vld) begin
            csr_obs[obs_tid] <= obs_csr;
        end
    end

    // ---- CW 窗表项读口（自检用）：tid 线程的第 e 项（CSR 0x2e 起，每项 44bit）----
    function automatic logic [43:0] cw_entry(input int tid, input int e);
        cw_entry = csr_obs[tid][CW_BYTE*8 + e*44 +: 44];
    endfunction
    // ---- CCR 读口（自检用）：CSR 0x2 的 16bit 镜像 ----
    function automatic logic [15:0] ccr_entry(input int tid);
        ccr_entry = csr_obs[tid][8*int'(A_CCR) +: 16];
    endfunction

    // ---- MXS 语义自检（MUX 取值 ↔ DMUX 回填的往返一致性）----
    //   ① 先核对设计给的例子：源 0xABCD、bits0=5 lr0=0 shift0=1 + bits1=7 lr1=1 shift1=1 → 0x50CC
    //   ② 再穷举 bits0/lr0/shift0/bits1/lr1/shift1 的全部组合，验证"取出来的字段能原位放回去"：
    //        mxs_unshift( mxs_align(src, mxs) ) 命中掩码的位 == src 的同名位
    //      （DMUX 的掩码回填就是靠这条性质：只回填被指令搬过的位，其余位保持 RF 原值）
    task automatic mxs_selftest(output bit ok);
        logic [15:0] src [2];
        logic [15:0] lane, val, msk;
        logic [14:0] mxs;
        int          n_case;
        ok = 1'b1;
        n_case = 0;
        src[0] = 16'hABCD;
        src[1] = 16'h1357;
        lane = mxs_align(16'hABCD, mux_mxs_pack(4'd5, 1'b0, 3'd1, 3'd7, 1'b1, 3'd1));
        if (lane !== 16'h50CC) begin
            ok = 1'b0;
            $display("MXS_SELFTEST 例子不符：lane=%h（期望 50CC）", lane);
        end
        for (int i = 0; i < 2; i++)
            for (int b0 = 0; b0 < 16; b0++)
                for (int lr0 = 0; lr0 < 2; lr0++)
                    for (int s0 = 0; s0 < 8; s0++)
                        for (int b1 = 0; b1 < 8; b1++)
                            for (int lr1 = 0; lr1 < 2; lr1++)
                                for (int s1 = 0; s1 < 8; s1++) begin
                                    mxs = mux_mxs_pack(b0[3:0], lr0[0], s0[2:0], b1[2:0], lr1[0], s1[2:0]);
                                    lane = mxs_align(src[i], mxs);
                                    mxs_unshift(lane, mxs, val, msk);
                                    n_case++;
                                    if ((val & msk) !== (src[i] & msk)) begin
                                        ok = 1'b0;
                                        if (n_case < 8)
                                            $display("MXS_SELFTEST 往返不符：src=%h mxs=%h val&msk=%h src&msk=%h",
                                                     src[i], mxs, val & msk, src[i] & msk);
                                    end
                                end
        $display("MXS_SELFTEST %0d 组往返 %s（例子 0xABCD→%h）", n_case, ok ? "OK" : "FAIL",
                 mxs_align(16'hABCD, mux_mxs_pack(4'd5, 1'b0, 3'd1, 3'd7, 1'b1, 3'd1)));
    endtask

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
        bit mxs_ok;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        mxs_selftest(mxs_ok);          // MXS 取值/回填语义自检（不依赖平台时序）
        preload_imem();
        preload_mux_imem();

        // 2 个 KO = 2 个并发线程；第 2 个优先级更高（1 < 3），用来跑多线程调度
        // 预发射口：tid0 写全部 4 项；tid1 只写第 0/2 项（strb=0101，其余项应保持 0）
        send_ko(3'd3, 8'hA1, 6'd0, 4'hF,   PRE_DATA0);
        send_ko(3'd1, 8'hA2, 6'd1, 4'b0101, PRE_DATA1);

        wait (done_cnt == 2);          // 两个线程都结束
        repeat (4) @(posedge clk);

        $display("---- 结果 ----");
        $display("CHK ts 边界=%0d  err=%0d  出口KO=%0d  线程结束=%0d（ts 粒度：RF 逐槽 + CSR 整表；出口 KO：DUT vs RM）",
                 chk_cnt, err_cnt, ko_cnt, done_cnt);
        $display("c_task 跳过数=%0d", ct_skip_cnt);
        $display("EU err 检查 %0d 次（示例模型期望全 0）", err_chk);
        $display("tid0 CW 低4项 = %h %h %h %h", cw_entry(0,0), cw_entry(0,1), cw_entry(0,2), cw_entry(0,3));
        $display("tid1 CW 低4项 = %h %h %h %h", cw_entry(1,0), cw_entry(1,1), cw_entry(1,2), cw_entry(1,3));
        // CCR 的 DUT/RM 比对在 checker 里按整份 CSR 做，这里只打印 DUT 侧便于对照
        $display("tid0 CCR=%h", ccr_entry(0));
        $display("tid1 CCR=%h", ccr_entry(1));
        pre_ok = (cw_entry(0,0) === PRE_DATA0[0*44 +: 44]) &&
                 (cw_entry(0,1) === PRE_DATA0[1*44 +: 44]) &&
                 (cw_entry(0,2) === PRE_DATA0[2*44 +: 44]) &&
                 (cw_entry(0,3) === PRE_DATA0[3*44 +: 44]) &&
                 (cw_entry(1,0) === PRE_DATA1[0*44 +: 44]) &&
                 (cw_entry(1,1) === 44'd0) &&      // strb=0 的项保持清零
                 (cw_entry(1,2) === PRE_DATA1[2*44 +: 44]) &&
                 (cw_entry(1,3) === 44'd0);
        if (err_cnt == 0 && chk_cnt >= 4 && ko_cnt == 2 && done_cnt == 2 && pre_ok && mxs_ok)
            $display("SMOKE PASS");
        else $display("SMOKE FAIL (chk=%0d err=%0d ko=%0d done=%0d pre_ok=%0b mxs_ok=%0b)",
                      chk_cnt, err_cnt, ko_cnt, done_cnt, pre_ok, mxs_ok);
        $finish;
    end

    // 兜底超时
    initial begin
        #20000;
        $display("TIMEOUT: busy=%0b chk=%0d err=%0d", busy, chk_cnt, err_cnt);
        $finish;
    end
endmodule
