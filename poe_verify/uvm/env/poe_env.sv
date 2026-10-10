class poe_env extends uvm_env;
    poe_ko_agent     agent;
    poe_dut_monitor  dut_mon;
    poe_rm_monitor   rm_mon;
    poe_scoreboard   scb;
    `uvm_component_utils(poe_env)

    function new(string name = "poe_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent   = poe_ko_agent::type_id::create("agent", this);
        dut_mon = poe_dut_monitor::type_id::create("dut_mon", this);
        rm_mon  = poe_rm_monitor::type_id::create("rm_mon", this);
        scb     = poe_scoreboard::type_id::create("scb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // 一个 driver（激励在顶层分叉给两套平台），两侧 monitor 各自入 FIFO
        dut_mon.ap_csr.connect(scb.csr_dut_fifo.analysis_export);
        rm_mon.ap_csr.connect(scb.csr_rm_fifo.analysis_export);
        dut_mon.ap_rf.connect(scb.rf_dut_fifo.analysis_export);
        rm_mon.ap_rf.connect(scb.rf_rm_fifo.analysis_export);
        dut_mon.ap_ko.connect(scb.ko_dut_fifo.analysis_export);
        rm_mon.ap_ko.connect(scb.ko_rm_fifo.analysis_export);
        dut_mon.ap_err.connect(scb.err_dut_fifo.analysis_export);
        rm_mon.ap_err.connect(scb.err_rm_fifo.analysis_export);
    endfunction
endclass
