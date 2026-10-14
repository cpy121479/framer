// ============================================================================
// scoreboard：DUT / RM 两侧事件**按 (tid, ts) 配对**后比对
//   · ts 边界：CSR 全表（0x00..0x59）+ RF 全表（256B = 64 槽）各自配对
//   · 出口 KO：按 tid 配对（一个线程一条），逐位比 384bit 报文
//   · EU 错误标志：两侧各自检查（本平台示例 EU 期望恒 0；两侧事件数也必须相等）
//   · 配对不依赖到达顺序：先到的一侧暂存，另一侧到达时当场比，再清表
//   · check_phase 检查"只到一侧"的残留事件，防止漏比
// ============================================================================
class poe_scoreboard extends uvm_scoreboard;
    localparam int N_THR_MAX = 64;   // 线程槽上限（key 表大小）
    localparam int TS_MAX    = 16;   // ts 上限（key 表大小）

    uvm_tlm_analysis_fifo #(poe_ev_item) csr_dut_fifo, csr_rm_fifo;
    uvm_tlm_analysis_fifo #(poe_ev_item) rf_dut_fifo,  rf_rm_fifo;
    uvm_tlm_analysis_fifo #(poe_ev_item) ko_dut_fifo,  ko_rm_fifo;
    uvm_tlm_analysis_fifo #(poe_ev_item) err_dut_fifo, err_rm_fifo;

    // key = tid*TS_MAX + ts：同一 (tid, ts) 的 DUT/RM 事件成对比
    bit [8*POE_CSR_BYTES-1:0] csr_dut_tab [N_THR_MAX*TS_MAX];
    bit [8*POE_CSR_BYTES-1:0] csr_rm_tab  [N_THR_MAX*TS_MAX];
    bit            csr_dut_vld [N_THR_MAX*TS_MAX];
    bit            csr_rm_vld  [N_THR_MAX*TS_MAX];
    bit [POE_RF_W-1:0] rf_dut_tab [N_THR_MAX*TS_MAX];
    bit [POE_RF_W-1:0] rf_rm_tab  [N_THR_MAX*TS_MAX];
    bit            rf_dut_vld  [N_THR_MAX*TS_MAX];
    bit            rf_rm_vld   [N_THR_MAX*TS_MAX];
    bit [383:0]    ko_dut_tab  [N_THR_MAX];
    bit [383:0]    ko_rm_tab   [N_THR_MAX];
    bit            ko_dut_vld  [N_THR_MAX];
    bit            ko_rm_vld   [N_THR_MAX];

    int csr_chk, csr_err, rf_chk, rf_err, ko_chk, ko_err;
    int err_chk_dut, err_chk_rm, err_err;   // EU 错误标志计数/错误数
    `uvm_component_utils(poe_scoreboard)

    function new(string name = "poe_scoreboard", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        csr_dut_fifo = new("csr_dut_fifo", this);
        csr_rm_fifo  = new("csr_rm_fifo", this);
        rf_dut_fifo  = new("rf_dut_fifo", this);
        rf_rm_fifo   = new("rf_rm_fifo", this);
        ko_dut_fifo  = new("ko_dut_fifo", this);
        ko_rm_fifo   = new("ko_rm_fifo", this);
        err_dut_fifo = new("err_dut_fifo", this);
        err_rm_fifo  = new("err_rm_fifo", this);
        foreach (csr_dut_vld[k]) begin csr_dut_vld[k] = 1'b0; csr_rm_vld[k] = 1'b0; end
        foreach (rf_dut_vld[k])  begin rf_dut_vld[k]  = 1'b0; rf_rm_vld[k]  = 1'b0; end
        foreach (ko_dut_vld[t])  begin ko_dut_vld[t]  = 1'b0; ko_rm_vld[t]  = 1'b0; end
    endfunction

    // DUT 侧 CSR/RF：先看 RM 有没有同 key，有就比，没有就暂存
    task automatic put_csr_dut(poe_ev_item d);
        int k = d.tid*TS_MAX + d.ts;
        if (csr_rm_vld[k]) begin
            csr_chk++;
            csr_rm_vld[k] = 1'b0;
            if (d.csr !== csr_rm_tab[k]) begin
                csr_err++;
                `uvm_error("CSR_CMP", $sformatf("ts=%0d tid=%0d CSR 不符", d.ts, d.tid))
                `uvm_info("CSR_CMP", $sformatf("  dut=%h", d.csr), UVM_LOW)
                `uvm_info("CSR_CMP", $sformatf("  rm =%h", csr_rm_tab[k]), UVM_LOW)
            end
        end else begin
            csr_dut_tab[k] = d.csr;
            csr_dut_vld[k] = 1'b1;
        end
    endtask

    task automatic put_csr_rm(poe_ev_item r);
        int k = r.tid*TS_MAX + r.ts;
        if (csr_dut_vld[k]) begin
            csr_chk++;
            csr_dut_vld[k] = 1'b0;
            if (csr_dut_tab[k] !== r.csr) begin
                csr_err++;
                `uvm_error("CSR_CMP", $sformatf("ts=%0d tid=%0d CSR 不符", r.ts, r.tid))
                `uvm_info("CSR_CMP", $sformatf("  dut=%h", csr_dut_tab[k]), UVM_LOW)
                `uvm_info("CSR_CMP", $sformatf("  rm =%h", r.csr), UVM_LOW)
            end
        end else begin
            csr_rm_tab[k] = r.csr;
            csr_rm_vld[k] = 1'b1;
        end
    endtask

    task automatic put_rf_dut(poe_ev_item d);
        int k = d.tid*TS_MAX + d.ts;
        if (rf_rm_vld[k]) begin
            rf_chk++;
            rf_rm_vld[k] = 1'b0;
            if (d.rf !== rf_rm_tab[k]) begin
                rf_err++;
                `uvm_error("RF_CMP", $sformatf("ts=%0d tid=%0d RF 不符", d.ts, d.tid))
                `uvm_info("RF_CMP", $sformatf("  dut=%h", d.rf), UVM_LOW)
                `uvm_info("RF_CMP", $sformatf("  rm =%h", rf_rm_tab[k]), UVM_LOW)
            end
        end else begin
            rf_dut_tab[k] = d.rf;
            rf_dut_vld[k] = 1'b1;
        end
    endtask

    task automatic put_rf_rm(poe_ev_item r);
        int k = r.tid*TS_MAX + r.ts;
        if (rf_dut_vld[k]) begin
            rf_chk++;
            rf_dut_vld[k] = 1'b0;
            if (rf_dut_tab[k] !== r.rf) begin
                rf_err++;
                `uvm_error("RF_CMP", $sformatf("ts=%0d tid=%0d RF 不符", r.ts, r.tid))
                `uvm_info("RF_CMP", $sformatf("  dut=%h", rf_dut_tab[k]), UVM_LOW)
                `uvm_info("RF_CMP", $sformatf("  rm =%h", r.rf), UVM_LOW)
            end
        end else begin
            rf_rm_tab[k] = r.rf;
            rf_rm_vld[k] = 1'b1;
        end
    endtask

    task automatic put_ko_dut(poe_ev_item d);
        if (ko_rm_vld[d.tid]) begin
            ko_chk++;
            ko_rm_vld[d.tid] = 1'b0;
            if (d.ko !== ko_rm_tab[d.tid]) begin
                ko_err++;
                `uvm_error("KO_CMP", $sformatf("出口 KO 不符 tid=%0d", d.tid))
                `uvm_info("KO_CMP", $sformatf("  dut=%h", d.ko), UVM_LOW)
                `uvm_info("KO_CMP", $sformatf("  rm =%h", ko_rm_tab[d.tid]), UVM_LOW)
            end
        end else begin
            ko_dut_tab[d.tid] = d.ko;
            ko_dut_vld[d.tid] = 1'b1;
        end
    endtask

    task automatic put_ko_rm(poe_ev_item r);
        if (ko_dut_vld[r.tid]) begin
            ko_chk++;
            ko_dut_vld[r.tid] = 1'b0;
            if (ko_dut_tab[r.tid] !== r.ko) begin
                ko_err++;
                `uvm_error("KO_CMP", $sformatf("出口 KO 不符 tid=%0d", r.tid))
                `uvm_info("KO_CMP", $sformatf("  dut=%h", ko_dut_tab[r.tid]), UVM_LOW)
                `uvm_info("KO_CMP", $sformatf("  rm =%h", r.ko), UVM_LOW)
            end
        end else begin
            ko_rm_tab[r.tid] = r.ko;
            ko_rm_vld[r.tid] = 1'b1;
        end
    endtask

    task run_phase(uvm_phase phase);
        poe_ev_item d, r;
        fork
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (csr_dut_fifo.try_get(d)) put_csr_dut(d);
            end
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (csr_rm_fifo.try_get(r)) put_csr_rm(r);
            end
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (rf_dut_fifo.try_get(d)) put_rf_dut(d);
            end
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (rf_rm_fifo.try_get(r)) put_rf_rm(r);
            end
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (ko_dut_fifo.try_get(d)) put_ko_dut(d);
            end
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (ko_rm_fifo.try_get(r)) put_ko_rm(r);
            end
            // ---- EU 错误标志（两侧各自检查；示例 EU 期望恒 0）----
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (err_dut_fifo.try_get(d)) begin
                    err_chk_dut++;
                    if (d.err !== 4'd0) begin
                        err_err++;
                        `uvm_error("ERR_CMP", $sformatf("DUT EU err_out 非 0：%b（tid=%0d）", d.err, d.tid))
                    end
                end
            end
            forever begin
                @(posedge poe_uvm_pkg::g_vif.clk);
                if (err_rm_fifo.try_get(r)) begin
                    err_chk_rm++;
                    if (r.err !== 4'd0) begin
                        err_err++;
                        `uvm_error("ERR_CMP", $sformatf("RM EU err_out 非 0：%b（tid=%0d）", r.err, r.tid))
                    end
                end
            end
        join
    endtask

    function void check_phase(uvm_phase phase);
        int csr_lone = 0, rf_lone = 0, ko_lone = 0;
        foreach (csr_dut_vld[k]) if (csr_dut_vld[k]) csr_lone++;
        foreach (csr_rm_vld[k])  if (csr_rm_vld[k])  csr_lone++;
        foreach (rf_dut_vld[k])  if (rf_dut_vld[k])  rf_lone++;
        foreach (rf_rm_vld[k])   if (rf_rm_vld[k])   rf_lone++;
        foreach (ko_dut_vld[t])  if (ko_dut_vld[t])  ko_lone++;
        foreach (ko_rm_vld[t])   if (ko_rm_vld[t])   ko_lone++;
        if (csr_lone != 0) `uvm_error("SCB", $sformatf("CSR 有 %0d 个 (tid,ts) 只到一侧", csr_lone))
        if (rf_lone  != 0) `uvm_error("SCB", $sformatf("RF  有 %0d 个 (tid,ts) 只到一侧", rf_lone))
        if (ko_lone  != 0) `uvm_error("SCB", $sformatf("出口 KO 有 %0d 个 tid 只到一侧", ko_lone))
        if (err_chk_dut != err_chk_rm) begin
            err_err++;
            `uvm_error("ERR_CMP", $sformatf("两侧 EU 错误标志事件数不等：dut=%0d rm=%0d",
                       err_chk_dut, err_chk_rm))
        end
        `uvm_info("SCB", $sformatf("CSR 比对 %0d 次错 %0d；RF 比对 %0d 次错 %0d；出口 KO 比对 %0d 次错 %0d；EU 错误标志 dut=%0d rm=%0d 次错 %0d",
                  csr_chk, csr_err, rf_chk, rf_err, ko_chk, ko_err,
                  err_chk_dut, err_chk_rm, err_err), UVM_LOW)
        if (csr_chk == 0) `uvm_error("SCB", "没有 CSR 事件，比对未执行")
        if (rf_chk == 0)  `uvm_error("SCB", "没有 RF 事件，比对未执行")
        if (ko_chk == 0)  `uvm_error("SCB", "没有出口 KO，KO 比对未执行")
        if (err_chk_dut == 0) `uvm_error("SCB", "没有 EU 错误标志事件，边界检查未执行")
    endfunction
endclass
