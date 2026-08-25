// 来源模板库自检（独立小 top，不依赖 UVM 平台）：
// - 每个 (stream,pos) 采样 tpl_src 400 次，统计每线程 c_task 数均值 vs 实测目标
// - 打印样例的每 ts c_task 分布（验证 U 形：首尾多、中间少）
// 运行：cd sim && make -f Makefile_tpl（或 verilator --binary 直接编译本文件 + 两个 pkg）
module tb_tpl_check;
    import poe_types_pkg::*;
    import poe_thread_tpl_pkg::*;

    function automatic int count_ct(input thread_tpl_t t);
        count_ct = 0;
        for (int k = 0; k < 16; k++)
            for (int m = 0; m < 8; m++) begin
                automatic burst_c_t cb =
                    t.burst_seq[(k*8 + m)*BURST_W +: BURST_W];
                if (m < t.ts_bs[k*4 +: 4] && cb.burst_type && cb.c0)
                    count_ct++;
            end
    endfunction

    function automatic int ct_at_ts(input thread_tpl_t t, input int k);
        ct_at_ts = 0;
        for (int m = 0; m < 8; m++) begin
            automatic burst_c_t cb =
                t.burst_seq[(k*8 + m)*BURST_W +: BURST_W];
            if (m < t.ts_bs[k*4 +: 4] && cb.burst_type)
                ct_at_ts++;
        end
    endfunction

    function automatic int count_jumps(input thread_tpl_t t);
        count_jumps = 0;
        for (int k = 1; k < 16; k++)
            if (t.ts_id[k*6 +: 6] != t.ts_id[(k-1)*6 +: 6] + 6'd1)
                count_jumps++;
    endfunction

    // iv 约束：ts0 = 1 条 i_task；ts1..15 iv ∈ [1, 8-c]；iv+c ≤ 8；首 burst 为 iv
    function automatic int check_iv(input thread_tpl_t t);
        check_iv = 0;
        for (int k = 0; k < 16; k++) begin
            automatic int bs = t.ts_bs[k*4 +: 4];
            automatic int iv = 0;
            automatic burst_iv_t b0 = t.burst_seq[(k*8)*BURST_W +: BURST_W];
            if (b0.burst_type) check_iv++; // 首 burst 必须 iv
            if (bs > 8) check_iv++;
            for (int m = 0; m < bs; m++) begin
                automatic burst_c_t cb =
                    t.burst_seq[(k*8 + m)*BURST_W +: BURST_W];
                if (!cb.burst_type) iv++;
            end
            if (k == 0 && iv != 1) check_iv++;
            if (k > 0 && (iv < 1 || iv > 8 - ct_at_ts(t, k))) check_iv++;
        end
    endfunction

    initial begin
        int bad, iv_bad, jmp_tot, ns_tot;
        bad = 0; iv_bad = 0; jmp_tot = 0; ns_tot = 0;
        for (int st = 0; st < 7; st++)
            for (int pos = 0; pos < 8; pos++) begin
                automatic int tot = 0;
                automatic int ns = 400;
                if (src_ct_avg(st, pos) < 0) continue;
                for (int i = 0; i < ns; i++) begin
                    automatic thread_tpl_t t = tpl_src(st, pos);
                    tot += count_ct(t);
                    iv_bad += check_iv(t);
                    jmp_tot += count_jumps(t);
                    ns_tot++;
                end
                if (st >= 2 && pos > 0) continue; // 单值来源只报一次
                $display("SRC st=%0d pos=%0d avg=%7.3f target=%0d %s",
                         st, pos, 1.0 * tot / ns, src_ct_avg(st, pos),
                         ((1.0*tot/ns - src_ct_avg(st,pos)) ** 2 > 0.25) ? "BAD" : "ok");
                if ((1.0*tot/ns - src_ct_avg(st,pos)) ** 2 > 0.25) bad++;
            end
        // 跳变率：4 变体中 1 个不跳转 + 3 个各 3 跳 → 期望均值 2.25/线程
        $display("JUMP avg/template=%7.3f (expect 2.25, i.e. 75%%x20%%)",
                 1.0 * jmp_tot / ns_tot);
        if ((1.0*jmp_tot/ns_tot - 2.25) ** 2 > 0.09) bad++;
        if (iv_bad != 0) begin
            $display("IV constraint violations: %0d", iv_bad);
            bad++;
        end else
            $display("IV constraints ok (ts0=1, ts1..15 iv in [1,8-c])");
        for (int st = 0; st < 7; st += 2) begin
            automatic thread_tpl_t t = tpl_src(st, st < 2 ? 2 : 0);
            $write("SHAPE st=%0d (C=%0d, jumps=%0d) c/ts:", st, count_ct(t),
                   count_jumps(t));
            for (int k = 0; k < 16; k++)
                $write(" %0d", ct_at_ts(t, k));
            $write("\n      ts_id:");
            for (int k = 0; k < 16; k++)
                $write(" %0d", t.ts_id[k*6 +: 6]);
            $display;
        end
        if (bad == 0) $display("TPL_SRC_CHECK PASS");
        else $display("TPL_SRC_CHECK FAIL bad=%0d", bad);
        $finish;
    end
endmodule
