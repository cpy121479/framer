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

    // 预载 MUX 指令存储：fetcher k ← RF[254-2k]（mvld=2），使窗口 word(15-r) = 表 x_r
    task load_mux_imem();
        virtual poe_if vif = poe_uvm_pkg::g_vif;
        bit [351:0] row_img;
        wait (vif.rst_n === 1'b1);
        row_img = '0;
        for (int k = 0; k < 32; k++)
            row_img[11*k +: 11] = {1'b1, 2'd2, 8'(254 - 2*k)};   // i=1, mvld=2, off=254-2k
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
            if (poe_uvm_pkg::g_vif.thr_done_vld) done_cnt++;
        end
        repeat (20) @(posedge poe_uvm_pkg::g_vif.clk);
        // csr 预发射口：核对 CW 窗低 4 项（strb=1 的项应等于发出的 44bit 数据）
        for (int i = 0; i < int'(seq.n_ko); i++)
            for (int e = 0; e < 4; e++)
                if (seq.pre_strb_q[i][e])
                    if (poe_uvm_pkg::g_vif.csr_dut[(int'(seq.pre_thid_q[i])*72 + 28)*8 + e*44 +: 44]
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
