// DUT 侧 monitor：观测事件总线（ts_done 快照）+ 出口 KO + EU 错误标志
class poe_dut_monitor extends uvm_monitor;
    uvm_analysis_port #(poe_ev_item) ap_csr, ap_rf, ap_ko, ap_err;  // CSR / RF / KO / ERR 分开
    virtual poe_if vif;
    `uvm_component_utils(poe_dut_monitor)

    function new(string name = "poe_dut_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap_csr = new("ap_csr", this);
        ap_rf  = new("ap_rf", this);
        ap_ko  = new("ap_ko", this);
        ap_err = new("ap_err", this);
    endfunction

    task run_phase(uvm_phase phase);
        poe_ev_item it;
        vif = poe_uvm_pkg::g_vif;
        forever begin
            @(posedge vif.clk);
            // 平台在 ts_done 后一拍给出观测快照（该线程整份 RF/CSR）
            if (vif.obs_vld) begin
                // ① CSR 事件（整份 CSR 按字节）
                it = poe_ev_item::type_id::create("csr_dut");
                it.kind = poe_ev_item::EV_CSR;
                it.tid  = int'(vif.obs_tid);
                it.ts   = int'(vif.obs_ts);
                it.csr  = vif.obs_csr;
                ap_csr.write(it);
                // ② RF 事件（整份 RF）
                it = poe_ev_item::type_id::create("rf_dut");
                it.kind = poe_ev_item::EV_RF;
                it.tid  = int'(vif.obs_tid);
                it.ts   = int'(vif.obs_ts);
                it.rf   = vif.obs_rf;
                ap_rf.write(it);
            end
            if (vif.out_vld) begin
                it = poe_ev_item::type_id::create("ko_dut");
                it.kind = poe_ev_item::EV_KO;
                it.tid  = int'(vif.out_tid);
                it.ko   = vif.out_data;
                ap_ko.write(it);
            end
            // EU 错误标志（随结果拍有效）
            if (vif.eu_err_vld) begin
                it = poe_ev_item::type_id::create("err_dut");
                it.kind = poe_ev_item::EV_ERR;
                it.tid  = int'(vif.eu_err_tid);
                it.err  = vif.eu_err;
                ap_err.write(it);
            end
        end
    endtask
endclass

// RM 侧 monitor：同样的观测事件总线 + 出口 KO（RM 的期望值）
class poe_rm_monitor extends uvm_monitor;
    uvm_analysis_port #(poe_ev_item) ap_csr, ap_rf, ap_ko, ap_err;
    virtual poe_if vif;
    `uvm_component_utils(poe_rm_monitor)

    function new(string name = "poe_rm_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap_csr = new("ap_csr", this);
        ap_rf  = new("ap_rf", this);
        ap_ko  = new("ap_ko", this);
        ap_err = new("ap_err", this);
    endfunction

    task run_phase(uvm_phase phase);
        poe_ev_item it;
        vif = poe_uvm_pkg::g_vif;
        forever begin
            @(posedge vif.clk);
            if (vif.obs_vld_rm) begin
                it = poe_ev_item::type_id::create("csr_rm");
                it.kind = poe_ev_item::EV_CSR;
                it.tid  = int'(vif.obs_tid_rm);
                it.ts   = int'(vif.obs_ts_rm);
                it.csr  = vif.obs_csr_rm;
                ap_csr.write(it);
                it = poe_ev_item::type_id::create("rf_rm");
                it.kind = poe_ev_item::EV_RF;
                it.tid  = int'(vif.obs_tid_rm);
                it.ts   = int'(vif.obs_ts_rm);
                it.rf   = vif.obs_rf_rm;
                ap_rf.write(it);
            end
            if (vif.out_vld_rm) begin
                it = poe_ev_item::type_id::create("ko_rm");
                it.kind = poe_ev_item::EV_KO;
                it.tid  = int'(vif.out_tid_rm);
                it.ko   = vif.out_data_rm;
                ap_ko.write(it);
            end
            if (vif.eu_err_vld_rm) begin
                it = poe_ev_item::type_id::create("err_rm");
                it.kind = poe_ev_item::EV_ERR;
                it.tid  = int'(vif.eu_err_tid_rm);
                it.err  = vif.eu_err_rm;
                ap_err.write(it);
            end
        end
    endtask
endclass
