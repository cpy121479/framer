class koa_base_test extends uvm_test;
    koa_env env;
    `uvm_component_utils(koa_base_test)

    function new(string name = "koa_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = koa_env::type_id::create("env", this);
        parse_plusargs();
    endfunction

    function void parse_plusargs();
        real rv;
        int iv;
        if ($value$plusargs("RUN_US=%e", rv)) ko_pkg::g_tb_cfg.run_us = rv;
        if ($value$plusargs("N_OH_PLANES=%d", iv)) ko_pkg::g_tb_cfg.n_oh_planes = iv;
        if ($value$plusargs("OH_SLOTS=%d", iv)) ko_pkg::g_tb_cfg.oh_slots_total = iv;
        if ($value$plusargs("OH_PLANE_SKEW=%d", iv)) ko_pkg::g_tb_cfg.oh_plane_skew = iv[0];
        if ($value$plusargs("N_X2X_PLANES=%d", iv)) ko_pkg::g_tb_cfg.n_x2x_planes = iv;
        if ($value$plusargs("X2X_SLOTS=%d", iv)) ko_pkg::g_tb_cfg.x2x_slots_total = iv;
        if ($value$plusargs("X2X_PLANE_SKEW=%d", iv)) ko_pkg::g_tb_cfg.x2x_plane_skew = iv[0];
        if ($value$plusargs("N_CH=%d", iv)) ko_pkg::g_tb_cfg.n_ch_per_plane = iv;
        if ($value$plusargs("UART_MPPS=%e", rv)) ko_pkg::g_tb_cfg.uart_mpps = rv;
    endfunction

    task run_phase(uvm_phase phase);
        koa_oh_seq oh_e_seq, oh_i_seq;
        koa_x2x_seq aps_e_seq, aps_i_seq, alm_seq;
        koa_uart_seq u_e_seq, u_i_seq;
        phase.raise_objection(this);
        while (!ko_pkg::g_reset_done) @(posedge ko_pkg::g_tb_cfg.vif.clk);

        oh_e_seq = koa_oh_seq::type_id::create("oh_e_seq"); oh_e_seq.dir = 0;
        oh_i_seq = koa_oh_seq::type_id::create("oh_i_seq"); oh_i_seq.dir = 1;
        aps_e_seq = koa_x2x_seq::type_id::create("aps_e_seq"); aps_e_seq.kind = 0;
        aps_i_seq = koa_x2x_seq::type_id::create("aps_i_seq"); aps_i_seq.kind = 1;
        alm_seq = koa_x2x_seq::type_id::create("alm_seq"); alm_seq.kind = 2;
        u_e_seq = koa_uart_seq::type_id::create("u_e_seq"); u_e_seq.dir = 0;
        u_i_seq = koa_uart_seq::type_id::create("u_i_seq"); u_i_seq.dir = 1;
        fork
            // 3 个业务源独立（最大 3 路并发）；同源多流共享 sequencer（item 串行，不独立）
            fork
                oh_e_seq.start(env.agent.sqr[0]); // fgOTN 开销源
                oh_i_seq.start(env.agent.sqr[0]);
            join
            fork
                aps_e_seq.start(env.agent.sqr[1]); // X2X 源
                aps_i_seq.start(env.agent.sqr[1]);
                alm_seq.start(env.agent.sqr[1]);
            join
            fork
                u_e_seq.start(env.agent.sqr[2]); // 串口源
                u_i_seq.start(env.agent.sqr[2]);
            join
        join_none
        // 运行窗口 + 输出 drain 裕量
        #(ko_pkg::g_tb_cfg.run_us * 1000.0 + 20000.0);
        phase.drop_objection(this);
    endtask
endclass
