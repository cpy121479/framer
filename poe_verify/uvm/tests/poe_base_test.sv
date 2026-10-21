// ============================================================================
// test：预载微指令 bank + 发 2 个 KO（两个并发线程）+ 等线程排空
//   · burst 指令存储是 ROM（poe_burst_imem 内部 initial 拼镜像），test 不再写它
//   · 微指令 bank 在 EU 内部，仍由 test 预载（等复位释放后再写）
// ============================================================================
class poe_base_test extends uvm_test;
    poe_env env;
    `uvm_component_utils(poe_base_test)

    function new(string name = "poe_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = poe_env::type_id::create("env", this);
    endfunction

    // ---- 微指令编码小工具 ----
    function bit [31:0] ADD(input int rd, input int rs1, input int rs2);
        ADD = (rs2<<20)|(rs1<<15)|(rd<<7)|32'h33;                  // ADD rd,rs1,rs2
    endfunction
    function bit [31:0] ADDI(input int rd, input int imm);
        ADDI = ((imm & 12'hFFF)<<20)|(rd<<7)|32'h13;               // ADDI rd,x0,imm
    endfunction
    function bit [31:0] SW(input int rs2, input int rs1, input int imm);
        SW = (((imm>>5)&7'h7F)<<25)|(rs2<<20)|(rs1<<15)|(3'b010<<12)|((imm&5'h1F)<<7)|32'h23;
    endfunction
    function bit [31:0] CSRRW(input int rd, input bit [11:0] csr, input int rs1);
        CSRRW = (csr<<20)|(rs1<<15)|(3'b001<<12)|(rd<<7)|32'h73;   // CSRRW rd,csr,rs1
    endfunction

    // 预载微指令：两级 bank 各 4 行
    task load_imem();
        virtual poe_if vif = poe_uvm_pkg::g_vif;
        bit [63:0] s0_row [4];
        bit [63:0] s1_row [4];

        // 等复位释放：bank 在复位期间会被清（生成模型的 load 口在复位时被门掉）
        wait (vif.rst_n === 1'b1);
        repeat (2) @(posedge vif.clk);

        // s0：lane0 = R 型，lane1 = I 型
        s0_row[0] = {ADD(10,8,9),  ADDI(8, 5)};                    // x10 = x8+x9 ; x8 = 5
        s0_row[1] = {ADD(11,8,9),  ADDI(9, 7)};                    // x11 = x8+x9 ; x9 = 7
        s0_row[2] = {ADD(12,8,9),  ADDI(14, 12'h11)};              // x12 = x8+x9 ; x14 = 0x11
        s0_row[3] = {ADD(13,8,9),  ADDI(15, 12'h22)};              // x13 = x8+x9 ; x15 = 0x22
        // s1：lane0 = store 型（SW 空转），lane1 = csr 型（x8 → mstatus，即线程 CCR）
        for (int i = 0; i < 4; i++)
            s1_row[i] = {SW(0,0,0), CSRRW(20, 12'h300, 8)};

        for (int r = 0; r < 4; r++) begin
            @(posedge vif.clk);
            vif.imem_we    <= 1'b1;
            vif.imem_saddr <= 1'b0;
            vif.imem_waddr <= r[3:0];
            vif.imem_wdata <= s0_row[r];
        end
        for (int r = 0; r < 4; r++) begin
            @(posedge vif.clk);
            vif.imem_we    <= 1'b1;
            vif.imem_saddr <= 1'b1;
            vif.imem_waddr <= r[3:0];
            vif.imem_wdata <= s1_row[r];
        end
        @(posedge vif.clk);
        vif.imem_we <= 1'b0;
        @(posedge vif.clk);
    endtask

    // ---- MUX 画像：KO 回流路径（与微指令画像配套）----
    //   bank 建线程时把 48B 入口 KO 放到 RF[128..175]（高字节在前）。
    //     ① 取数组：前 16 条（KO 高 32B / 2B）← RF[128+2k, 129+2k]（i=1、mvld=2）；
    //        其余 16 槽 mvld=0；② 移位组全 0 = 直通（KO 原样进窗口）
    //     ③ MXCC：CCR[0]→高字节、CCR[1]→低字节
    //     ④/⑤ O 路：O 窗第 m 个 2B ← 64B 窗字节 (2m, 2m+1)（EU 处理后的 KO 高 32B），直通
    function bit [MUX_ROW_W-1:0] mux_row_img();
        bit [MUX_ROW_W-1:0] r;
        r = '0;
        // ① 取数：KO 高 32B = RF[128..159] → 窗口 slot 0..15
        for (int k = 0; k < O_INS_N; k++) begin
            r[MF_FET_LSB + MUX_INS_W*k +: MUX_INS_W] = mux_fetch_pack(1'b1, 2'd2, 8'(KO_RF_BASE + 2*k));
            r[MF_MXS_LSB + MXS_W*k +: MXS_W]         = '0;             // 直通
        end
        r[MF_MXCC_LSB +: MXCC_W]          = 5'd0;                      // 高字节 ← CCR 表第 0 字节
        r[MF_MXCC_LSB + MXCC_W +: MXCC_W] = 5'd1;                      // 低字节 ← CCR 表第 1 字节
        // ④/⑤ O 路：窗口 slot 0..15（EU 处理后的 KO 高 32B）→ O 窗
        for (int m = 0; m < O_INS_N; m++) begin
            r[MF_OFET_LSB + MUX_INS_W*m +: MUX_INS_W] = mux_fetch_pack(1'b1, 2'd2, 8'(2*m));
            r[MF_OMXS_LSB + MXS_W*m +: MXS_W]         = '0;            // 直通
        end
        return r;
    endfunction

    task load_mux_imem();
        virtual poe_if vif = poe_uvm_pkg::g_vif;
        bit [MUX_ROW_W-1:0] row_img;
        wait (vif.rst_n === 1'b1);
        row_img = mux_row_img();
        for (int r = 0; r < 16; r++) begin
            @(posedge vif.clk);
            vif.mux_imem_we    <= 1'b1;
            vif.mux_imem_waddr <= r[3:0];
            vif.mux_imem_wdata <= row_img;
        end
        @(posedge vif.clk);
        vif.mux_imem_we <= 1'b0;
        @(posedge vif.clk);
    endtask

    task run_phase(uvm_phase phase);
        poe_ko_seq seq;
        int done_cnt = 0;
        // 平台按 ts_done 事件给快照；这里按 tid 存最后一份，供 CW/CCR 自检
        bit [POE_CSR_BYTES*8-1:0] csr_obs [64];
        phase.raise_objection(this);
        load_imem();
        load_mux_imem();
        seq = poe_ko_seq::type_id::create("seq");
        seq.n_ko = 2;              // 本版先发 2 个 KO（两个并发线程）
        seq.head = 32'd0;          // 程序基址 = burst 指令存储第 0 行
        fork
            seq.start(env.agent.sqr);
        join_none
        // 等 2 个线程都结束（thr_done 是单拍脉冲，边沿计数）
        while (done_cnt < 2) begin
            @(posedge poe_uvm_pkg::g_vif.clk);
            if (poe_uvm_pkg::g_vif.obs_vld)
                csr_obs[poe_uvm_pkg::g_vif.obs_tid] = poe_uvm_pkg::g_vif.obs_csr;
            if (poe_uvm_pkg::g_vif.thr_done_vld) done_cnt++;
        end
        repeat (20) @(posedge poe_uvm_pkg::g_vif.clk);
        // csr 预发射口：核对 CW 窗低 4 项（strb=1 的项应等于发出的 44bit 数据）
        for (int i = 0; i < int'(seq.n_ko); i++)
            for (int e = 0; e < 4; e++)
                if (seq.pre_strb_q[i][e])
                    if (csr_obs[seq.pre_thid_q[i]][int'(A_CW_CMD)*8 + e*44 +: 44]
                        !== seq.pre_data_q[i][e*44 +: 44])
                        `uvm_error("PRE_CW", $sformatf("tid=%0d CW 表项%0d 不符",
                                   seq.pre_thid_q[i], e))
        `uvm_info("PRE_CW", $sformatf("预发射口核对 %0d 个 KO 的 CW 窗完成", seq.n_ko), UVM_LOW)
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("TEST", "poe_base_test 结束（检查见 scoreboard 汇总）", UVM_LOW)
    endfunction
endclass
