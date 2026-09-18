// DUT 侧 monitor：ts 边界两张表 + 线程结束 + 出口 KO
class poe_dut_monitor extends uvm_monitor;
    uvm_analysis_port #(poe_ev_item) ap_csr, ap_rf, ap_ko;   // CSR / RF 分开
    virtual poe_if vif;
    `uvm_component_utils(poe_dut_monitor)

    function new(string name = "poe_dut_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap_csr = new("ap_csr", this);
        ap_rf  = new("ap_rf", this);
        ap_ko  = new("ap_ko", this);
    endfunction

    task run_phase(uvm_phase phase);
        poe_ev_item it;
        vif = poe_uvm_pkg::g_vif;
        forever begin
            @(posedge vif.clk);
            if (vif.ts_done_vld) begin
                // ① CSR 事件（整份 CSR 按字节）
                it = poe_ev_item::type_id::create("csr_dut");
                it.kind = poe_ev_item::EV_CSR;
                it.tid  = int'(vif.ts_done_tid);
                it.ts   = int'(vif.ts_done_idx);
                it.csr  = vif.csr_dut[it.tid*POE_CSR_BYTES*8 +: POE_CSR_BYTES*8];
                ap_csr.write(it);
                // ② RF 事件（整份 RF）
                it = poe_ev_item::type_id::create("rf_dut");
                it.kind = poe_ev_item::EV_RF;
                it.tid  = int'(vif.ts_done_tid);
                it.ts   = int'(vif.ts_done_idx);
                it.rf   = vif.rf_dut[it.tid*POE_RF_W +: POE_RF_W];
                ap_rf.write(it);
            end
            if (vif.out_vld) begin
                it = poe_ev_item::type_id::create("ko_dut");
                it.kind = poe_ev_item::EV_KO;
                it.tid  = int'(vif.out_tid);
                it.ko   = vif.out_data;
                ap_ko.write(it);
            end
        end
    endtask
endclass

// RM 侧 monitor：同样的 ts 边界两张表 + 出口 KO（RM 的期望值）
class poe_rm_monitor extends uvm_monitor;
    uvm_analysis_port #(poe_ev_item) ap_csr, ap_rf, ap_ko;
    virtual poe_if vif;
    `uvm_component_utils(poe_rm_monitor)

    function new(string name = "poe_rm_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap_csr = new("ap_csr", this);
        ap_rf  = new("ap_rf", this);
        ap_ko  = new("ap_ko", this);
    endfunction

    task run_phase(uvm_phase phase);
        poe_ev_item it;
        vif = poe_uvm_pkg::g_vif;
        forever begin
            @(posedge vif.clk);
            if (vif.ts_done_vld_rm) begin
                it = poe_ev_item::type_id::create("csr_rm");
                it.kind = poe_ev_item::EV_CSR;
                it.tid  = int'(vif.ts_done_tid_rm);
                it.ts   = int'(vif.ts_done_idx_rm);
                it.csr  = vif.csr_rm[it.tid*POE_CSR_BYTES*8 +: POE_CSR_BYTES*8];
                ap_csr.write(it);
                it = poe_ev_item::type_id::create("rf_rm");
                it.kind = poe_ev_item::EV_RF;
                it.tid  = int'(vif.ts_done_tid_rm);
                it.ts   = int'(vif.ts_done_idx_rm);
                it.rf   = vif.rf_rm[it.tid*POE_RF_W +: POE_RF_W];
                ap_rf.write(it);
            end
            if (vif.out_vld_rm) begin
                it = poe_ev_item::type_id::create("ko_rm");
                it.kind = poe_ev_item::EV_KO;
                it.tid  = int'(vif.out_tid_rm);
                it.ko   = vif.out_data_rm;
                ap_ko.write(it);
            end
        end
    endtask
endclass
