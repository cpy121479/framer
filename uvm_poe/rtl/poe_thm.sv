// ============================================================================
// POE THM（线程管理器）行为模型 v5
// - 线程 = 若干 ts，每个 ts = 若干 burst；burst 为 38bit 一种结构两种类型
//   （burst_iv_t / burst_c_t，burst_type 区分，字段重叠复用，见 poe_types_pkg）
// - 保序在 THM：新 KO 报文查自身线程池，同 (stream,cid,pos) 活跃线程（非 IDLE）则
//   存入 8 深报文缓存等待；前序线程释放后按 FIFO 放行；不能建线程且缓存满才反压 ko_rdy
// - 线程状态机：IDLE→READY→ISSUED→DONE（WAIT 并入 ISSUED 打拍）
//   READY ≠ 回 IDLE：回 READY 后可发射下一个 burst（不限同一 ts），bs_pc 跨 ts 连续推进；
//   跳转边界（ts 末条 burst + 下一 ts 编号不连续）发射后等待 4+t 拍（1+3+t）；
//   cur_ts 仅由 eu_done/dma_done 统计推进，一级队列可含 cur_ts 及更靠后 ts 的 burst；
//   ts 完成判据 = done 事件数 ≥ 预期值 th_dneed（i/v burst 计 1、c_task burst 按有效
//   task 数计，空 c_task burst 计 0、不占 DSE 发射机会），th_dneed=0 的 ts 无事件，
//   由每拍兜底检查推进；occ_ts 门控：c_task 占据 ts..ts+occ-1（occ 随机 1-8 偏大分布，rw_occ_pick），
//   cur_ts 越过 ts+occ 需其读写完成（dma_ctrl rw_done，70~75 拍），T_DONE 前全部
//   读写须完成
// - 建线程时同步生成 CSR 表项（csr_t，th_id 6bit、cw 8×6B），th_stat/cur_ts 与状态机
//   同步；dma_c/cw 暴露给 th_sch（解析 c_task 时按 dma_id 查询，只读）
// - pre_read 转发：带预读 KO 建线程时同拍把 4 组 {vld, tid, dma_addr, op} 转发给
//   burst_sch 的 8 深 pre_buf（占位吸收，不执行/不回 done）；pre_buf 快满时
//   pre_buf_rdy=0，带预读 KO 反压（ko_rdy=0）
// - C 窗类型保留定义、RTL 未实例化；dma_ctrl 只做 4 个 c_task FIFO 缓冲，
//   RBA 为独立读写机会计数；锁（ts 级）仅用于一级发射互斥，状态只在此维护
// ============================================================================
module poe_thm #(
    parameter int MAX_THREADS = 64,
    parameter int MAX_TS = 16,
    parameter int MAX_BURST = 8, // 每 ts 最多 burst 数（8）
    parameter int TS_ID_W = 6, // ts 编号位宽（0..63，容纳跳转）
    parameter int CID_W = 17,
    parameter int BUF_DEPTH = 8
    ) (
    input logic clk,
    input logic rst_n,
    // ---- KOA 输入（有效信息：保序键 + 预读；线程描述由模板池随机） ----
    input logic ko_vld,
    input logic [2:0] ko_stream, // 来源流 0..6
    input logic [CID_W-1:0] ko_cid,
    input logic [2:0] ko_pos,
    input logic [2:0] ko_pri, // KO 报文优先级（线程优先级继承此值，0 最高）
    input logic [3:0] ko_pre_vld, // 预读入口指示（4 组，随 KO 报文）
    input logic [79:0] ko_dma_addr, // 预读入口 smc 地址（4×20bit）
    input logic [3:0] ko_pre_op, // 预读入口操作类型（4×1bit）
    output logic ko_rdy,
    // ---- th_sch：ready_mask / 发射 burst 的 ts / cur_ts / burst ----
    output logic [MAX_THREADS-1:0] ready_mask, // READY 且未到头线程位图
    output logic [MAX_THREADS*3-1:0] ready_pri, // 每线程 burst 优先级
    output logic [MAX_THREADS*TS_ID_W-1:0] ready_burst_ts, // 发射 burst 所属 ts 编号（由 bs_pc 推导）
    output logic [MAX_THREADS*4-1:0] ready_burst_tidx, // 发射 burst 所属 ts 序号（done 归属用）
    output logic [MAX_THREADS*TS_ID_W-1:0] ready_curts, // 当前 ts 编号（cu_done/dma_done 推进）
    output logic [MAX_THREADS*BURST_W-1:0] ready_burst, // 发射 burst（bs_pc 索引，38bit）
    input logic iss_vld0,
    input logic [5:0] iss_tid0,
    input logic iss_vld1,
    input logic [5:0] iss_tid1,
    // ---- EU（2 个）/ dma_ctrl（4 个 DSE 单元）完成：cur_ts 推进依赖完成统计 ----
    input logic eu_done_vld0,
    input logic [5:0] eu_done_tid0,
    input logic [3:0] eu_done_tidx0,
    input logic eu_done_vld1,
    input logic [5:0] eu_done_tid1,
    input logic [3:0] eu_done_tidx1,
    input logic [3:0] dma_done_vld, // 4 个 DSE 单元
    input logic [23:0] dma_done_tid, // 4×6
    input logic [15:0] dma_done_tidx, // 4×4
    // ---- dma_ctrl 读写完成（FIFO 出队后 70~75 拍，每 DSE 每拍 ≤1）：
    //      occ_ts 门控——cur_ts 越过 ts+occ_ts 前需该 ts 未完成 c_task 清空 ----
    input logic [3:0] rw_done_vld,
    input logic [23:0] rw_done_tid,
    input logic [15:0] rw_done_tidx,
    input logic [11:0] rw_done_dma,
    input logic [1:0] rw_mode, // 读写返回模式（0=SMC/1=L1/2=按优先级，pre_read 查表用）
    // ---- burst_sch 二级发射通知（打拍起点，占位） ----
    input logic emit_vld,
    input logic [5:0] emit_tid,
    // ---- pre_read 预读转发（线程创建同拍 → burst_sch，4 组） ----
    input logic pre_buf_rdy, // 二级发射预读缓存有空间（满反压带预读 KO 建线程）
    output logic [3:0] pre_vld,
    output logic [23:0] pre_tid, // 4×6bit（= 新建线程 tid）
    output logic [79:0] pre_dma_addr,
    output logic [3:0] pre_op,
    // ---- CSR 暴露（th_sch 解析 c_task 用）：dma_c 任务掩码 / cw 操作表（只读） ----
    output logic [MAX_THREADS*8-1:0] csr_dma_c,
    output logic [MAX_THREADS*384-1:0] csr_cw
    );

    import poe_types_pkg::*;
    import poe_thread_tpl_pkg::*;

    typedef enum logic [1:0] { T_IDLE, T_READY, T_ISSUED, T_DONE } state_t;

    // pre_read：带预读 KO 建线程时转发给 burst_sch pre_buf（占位吸收，无线程归属/无 done）

    state_t th_state [MAX_THREADS];
    logic [TS_W-1:0] th_ts_n [MAX_THREADS];
    logic [2:0] th_pri_r [MAX_THREADS];
    logic [BURST_W-1:0] th_burst_r [MAX_THREADS][MAX_TS][MAX_BURST]; // 每 ts 独立 burst 模式
    logic [2:0] th_stream [MAX_THREADS];
    logic [CID_W-1:0] th_cid [MAX_THREADS];
    logic [2:0] th_pos [MAX_THREADS];
    logic [7:0] th_bs_pc [MAX_THREADS]; // 应执行 burst 全局流水序号（跨 ts，最大 16×8=128）
    logic [TS_ID_W-1:0] th_cur_ts [MAX_THREADS]; // 当前 ts 编号（done 统计推进，按 ts_id 跳转）
    logic [3:0] th_ts_idx [MAX_THREADS]; // 当前在第几个 ts（序号 0..n-1）
    logic [TS_ID_W-1:0] th_ts_id_r [MAX_THREADS][MAX_TS]; // 每 ts 编号（递增可跳转）
    logic [7:0] th_wait [MAX_THREADS];
    logic [3:0] th_done_acc [MAX_THREADS][MAX_TS]; // 每 ts 已累计 done 事件数（i/v burst 1、c_task 按有效 task 数）
    logic [3:0] th_need [MAX_THREADS][MAX_TS]; // 每 ts 实际执行 burst 数（= ts_bs，≤8）
    logic [4:0] th_dneed [MAX_THREADS][MAX_TS]; // 每 ts 预期 done 事件数（i/v=1 / c=有效 task 数，空 c_task=0）
    logic [7:0] th_rw_m [MAX_THREADS][MAX_TS]; // 每 ts 未完成读写位图（bit0..6=dma_id，bit7=pre_read）
    logic [23:0] th_occ_r [MAX_THREADS][MAX_TS]; // 每 ts 各 id 的 occ-1（8×3bit；nibble7=pre_read）
    logic [7:0] th_pre_cnt [MAX_THREADS]; // pre_read 读写完成倒计时（模式/op 延迟）

    // ---- pre_read 占据 ts 数：参数化（plusarg PRE_OCC，默认 3，范围 1..8）。
    //      带预读线程的 cur_ts 越过 ts0+PRE_OCC 需预读写完成（同 c_task occ 门控）----
    int pre_occ_ts;
    initial begin
        pre_occ_ts = 3;
        void'($value$plusargs("PRE_OCC=%d", pre_occ_ts));
        if (pre_occ_ts < 1) pre_occ_ts = 1;
        if (pre_occ_ts > 8) pre_occ_ts = 8;
    end
    logic [7:0] th_off [MAX_THREADS][MAX_TS+1]; // 每 ts 起始累计偏移（off[k]=前 k 个 ts 的 need 和）
    logic [3:0] th_sel_ts [MAX_THREADS]; // bs_pc 所属 ts 序号（组合推导）
    logic [2:0] th_sel_idx [MAX_THREADS]; // bs_pc 在所属 ts 内的 burst 序号（组合推导）
    csr_t csr [MAX_THREADS];
    logic [47:0] sys_ts_cnt; // 系统时戳计数（1GHz 拍，48bit）

    // ---- 线程级互斥锁表（16 个锁，锁 ID 独立编号；FREE=63 表示空闲） ----
    localparam int N_LOCK = 16;
    localparam logic [5:0] LOCK_FREE = 6'd63;
    logic [5:0] lock_owner [N_LOCK]; // 持锁线程 tid；LOCK_FREE=空闲

    // ---- benchmark 场景控制：TPL_MASK（plusarg，默认全开）限定可选模板集合，
    // 建线程时从掩码内均匀随机选取（bit i 对应模板 Ti；掩码为 0 时回退全开） ----
    int tpl_mask;
    initial begin
        tpl_mask = (1 << N_TPL) - 1;
        void'($value$plusargs("TPL_MASK=%d", tpl_mask));
        if ((tpl_mask & ((1 << N_TPL) - 1)) == 0)
            tpl_mask = (1 << N_TPL) - 1;
    end

    function automatic int tpl_pick();
        automatic int m = tpl_mask & ((1 << N_TPL) - 1);
        automatic int r = $urandom % $countones(m);
        for (int b = 0; b < N_TPL; b++)
            if ((m >> b) & 1) begin
                if (r == 0) return b;
                r--;
            end
        return 0;
    endfunction

    function automatic logic tpl_mask_is_full();
        tpl_mask_is_full = (tpl_mask & ((1 << N_TPL) - 1)) == ((1 << N_TPL) - 1);
    endfunction

    // ---- c_task 读写占用门控（occ_ts 语义）：ts k 的 c_task 占据 [k, k+occ-1]，
    // cur_ts 越过 k+occ 前需其读写完成（dma_ctrl rw_done）；同 ts 多个未完成
    // task 取剩余者的最小 occ（最紧的屏障）----
    function automatic logic [3:0] rw_occ_min(input int i, input int k);
        automatic logic [3:0] mn = 4'd9;
        for (int b = 0; b < 8; b++)
            if (th_rw_m[i][k][b]) begin
                automatic logic [3:0] o = {1'b0, th_occ_r[i][k][b*3 +: 3]} + 4'd1;
                if (o < mn) mn = o;
            end
        rw_occ_min = (mn == 4'd9) ? 4'd8 : mn; // 空 mask 不被调用（rw_blk 已判非空）
    endfunction

    // 从 nts 跨入 nts+1 是否被未完成读写阻挡：∃ k，pending(k)≠0 且 k+occ_min(k) ≤ nts
    function automatic logic rw_blk(input int i, input logic [3:0] nts);
        rw_blk = 1'b0;
        for (int k = 0; k < MAX_TS; k++)
            if (th_rw_m[i][k] != 8'b0 && (k + rw_occ_min(i, k) <= nts))
                rw_blk = 1'b1;
    endfunction

    function automatic logic rw_empty(input int i);
        rw_empty = 1'b1;
        for (int k = 0; k < MAX_TS; k++)
            if (th_rw_m[i][k] != 8'b0) rw_empty = 1'b0;
    endfunction

    // ---- 8 深保序缓存（只存有效信息：预读 + 保序键；线程描述由模板池随机） ----
    localparam int ST_W = 3;
    localparam int TS_W = $clog2(MAX_TS + 1); // ts 数位宽（16 → 4bit）
    localparam int TS_ID_VEC_W = MAX_TS * TS_ID_W; // 每 ts 编号向量
    localparam int BS_W = MAX_TS * 4; // 每 ts burst 数向量（16×4bit，0..8）
    localparam int PR_W = 3;
    localparam int BURST_PAT_W = MAX_TS * MAX_BURST * BURST_W; // 16×8×38bit
    localparam int DMA_C_W = 8;
    localparam int CW_W = 384;
    // 预读字段（随报文缓存）：{pre_vld(4), dma_addr(80), op(4)}
    localparam int PRE_VEC_W = 88;
    localparam int PKG_W = PRE_VEC_W + ST_W + CID_W + 3 + 3; // 88+3+17+3+3 = 114
    localparam int PRE_VLD_MSB = PKG_W - 1;
    localparam int PRE_ADDR_MSB = PKG_W - 5;
    localparam int PRE_OP_MSB = PKG_W - 85;
    localparam int ST_MSB = PKG_W - 89;
    localparam int CID_MSB = ST_MSB - ST_W;
    localparam int POS_MSB = CID_MSB - CID_W;
    logic [PKG_W-1:0] buf_mem [BUF_DEPTH];
    logic [2:0] buf_head, buf_tail;
    logic [3:0] buf_cnt;

    // ---- 组合辅助 ----
    function automatic logic key_active(logic [2:0] s, logic [CID_W-1:0] c, logic [2:0] p);
        for (int i = 0; i < MAX_THREADS; i++)
            if (th_state[i] != T_IDLE && th_stream[i] == s && th_cid[i] == c && th_pos[i] == p)
                return 1'b1;
        return 1'b0;
    endfunction

    function automatic int find_idle();
        for (int i = 0; i < MAX_THREADS; i++)
            if (th_state[i] == T_IDLE) return i;
        return -1;
    endfunction

    int busy_cnt;
    logic all_busy;
    logic buf_full, buf_empty;
    logic can_accept;
    logic buf_ok; // 缓存队头可放行

    always_comb begin
        busy_cnt = 0;
        for (int i = 0; i < MAX_THREADS; i++)
            if (th_state[i] != T_IDLE) busy_cnt++;
        all_busy = (busy_cnt == MAX_THREADS);
    end
    assign buf_full = (buf_cnt == BUF_DEPTH);
    assign buf_empty = (buf_cnt == 0);
    // 反压：能建线程/入缓存 且 非缓存放行拍 且（带预读 KO 需预读缓存空间）。
    // 缓存放行拍（buf_ok=1）本拍专用于缓存报文建线程，对 KOA 拉 1 拍反压，
    // 让新报文 vld 保持、下一拍再处理；多个保序阻塞连续解除时连续反压多拍。
    assign ko_rdy = can_accept && !buf_ok && (!(|ko_pre_vld) || pre_buf_rdy);

    // 新报文可接受：能建线程（有空槽且同 key 无活跃）或能入缓存（未满）
    always_comb begin
        can_accept = 1'b0;
        if (!all_busy && !key_active(ko_stream, ko_cid, ko_pos)) can_accept = 1'b1;
        if (!buf_full) can_accept = 1'b1;
    end

    // 缓存队头可放行：非空 && 队头 key 无活跃 && 有空槽
    always_comb begin
        buf_ok = 1'b0;
        if (!buf_empty && !all_busy) begin
            if (!key_active(buf_mem[buf_head][ST_MSB -: ST_W],
                buf_mem[buf_head][CID_MSB -: CID_W],
                buf_mem[buf_head][POS_MSB -: 3]))
                buf_ok = 1'b1;
        end
    end

    // ---- pre_read 预读转发：线程创建成立的那一拍，把预读信息（含新建 tid）送给 burst_sch ----
    logic thread_cre_ok;
    logic [3:0] src_pre_vld; // 预读来源：缓存放行用缓存条目，否则用 KOA 输入
    logic [79:0] src_pre_addr;
    logic [3:0] src_pre_op;
    always_comb begin
        thread_cre_ok = (find_idle() >= 0) &&
                        (buf_ok || (ko_vld && ko_rdy &&
                         !key_active(ko_stream, ko_cid, ko_pos)));
        if (buf_ok) begin
            src_pre_vld = buf_mem[buf_head][PRE_VLD_MSB -: 4];
            src_pre_addr = buf_mem[buf_head][PRE_ADDR_MSB -: 80];
            src_pre_op = buf_mem[buf_head][PRE_OP_MSB -: 4];
        end else begin
            src_pre_vld = ko_pre_vld;
            src_pre_addr = ko_dma_addr;
            src_pre_op = ko_pre_op;
        end
    end
    assign pre_vld = thread_cre_ok ? src_pre_vld : 4'd0;
    assign pre_tid = thread_cre_ok ? {4{find_idle()[5:0]}} : 24'd0;
    assign pre_dma_addr = thread_cre_ok ? src_pre_addr : 80'd0;
    assign pre_op = thread_cre_ok ? src_pre_op : 4'd0;

    // ---- CSR 暴露（th_sch 按 tid+dma_id 查询） ----
    always_comb begin
        for (int i = 0; i < MAX_THREADS; i++) begin
            csr_dma_c[i*8 +: 8] = csr[i].dma_c;
            csr_cw[i*384 +: 384] = csr[i].cw;
        end
    end

    // ---- 完成事件聚合：eu0/eu1/dma0..3 六路 done 按 (tid,tidx) 合并（同 tid 同拍累加） ----
    logic [2:0] done_n; // 本拍 done 事件数（0..6）
    logic [5:0] done_tid_l [6];
    logic [3:0] done_tidx_l [6];
    logic [2:0] done_cnt_l [6]; // 同 (tid,tidx) 同拍合并计数（最多 6）
    always_comb begin
        done_n = 3'd0;
        if (eu_done_vld0) begin
            automatic int f = -1;
            for (int k = 0; k < 6; k++)
                if ((k < done_n) && (done_tid_l[k] == eu_done_tid0) &&
                    (done_tidx_l[k] == eu_done_tidx0)) f = k;
            if (f >= 0) done_cnt_l[f] = done_cnt_l[f] + 1'b1;
            else begin
                done_tid_l[done_n] = eu_done_tid0;
                done_tidx_l[done_n] = eu_done_tidx0;
                done_cnt_l[done_n] = 3'd1;
                done_n = done_n + 1'b1;
            end
        end
        if (eu_done_vld1) begin
            automatic int f = -1;
            for (int k = 0; k < 6; k++)
                if ((k < done_n) && (done_tid_l[k] == eu_done_tid1) &&
                    (done_tidx_l[k] == eu_done_tidx1)) f = k;
            if (f >= 0) done_cnt_l[f] = done_cnt_l[f] + 1'b1;
            else begin
                done_tid_l[done_n] = eu_done_tid1;
                done_tidx_l[done_n] = eu_done_tidx1;
                done_cnt_l[done_n] = 3'd1;
                done_n = done_n + 1'b1;
            end
        end
        for (int d = 0; d < 4; d++)
            if (dma_done_vld[d]) begin
                automatic logic [5:0] dt = dma_done_tid[d*6 +: 6];
                automatic logic [3:0] dti = dma_done_tidx[d*4 +: 4];
                if (dt < MAX_THREADS) begin
                    automatic int f = -1;
                    for (int k = 0; k < 6; k++)
                        if ((k < done_n) && (done_tid_l[k] == dt) &&
                            (done_tidx_l[k] == dti)) f = k;
                    if (f >= 0) done_cnt_l[f] = done_cnt_l[f] + 1'b1;
                    else begin
                        done_tid_l[done_n] = dt;
                        done_tidx_l[done_n] = dti;
                        done_cnt_l[done_n] = 3'd1;
                        done_n = done_n + 1'b1;
                    end
                end
            end
    end

    // ---- 每 ts 起始累计偏移（off[k] = 前 k 个 ts 的 need 和；bs_pc 只推进到需执行的
    // burst，映射与 th_burst_r 物理槽位一致）----
    always_comb begin
        for (int i = 0; i < MAX_THREADS; i++) begin
            th_off[i][0] = 8'd0;
            for (int k = 0; k < MAX_TS; k++)
                th_off[i][k+1] = th_off[i][k] + th_need[i][k];
        end
    end

    // ---- bs_pc → (所属 ts, 段内 burst 序号) 组合映射 ----
    always_comb begin
        for (int i = 0; i < MAX_THREADS; i++) begin
            automatic logic [3:0] ts = 4'd0;
            for (int k = 1; k < MAX_TS; k++)
                if (th_bs_pc[i] >= th_off[i][k]) ts = k[3:0];
            th_sel_ts[i] = ts;
            th_sel_idx[i] = th_bs_pc[i] - th_off[i][ts];
        end
    end

    // ---- 跳转边界判定：当前 burst 为所属 ts 末条、存在下一 ts 且下一 ts 编号不连续
    // （ts_id 跳变 = 真实跳转标记，br 为预留）。该 burst 发射后等待 4+t 拍：
    // 1 拍基础 + 3 拍完成反馈（跳转后须等 cur_ts 推进才能发下一 ts 的 burst）
    // + 随机竞争 t = $urandom % (jump_cnt+1)，jump_cnt = 当拍 READY 线程中
    // 当前 burst 处于跳转边界的个数 ----
    function automatic logic is_jump_burst(input int i);
        automatic logic [3:0] k = th_sel_ts[i];
        is_jump_burst = (k + 4'd1 < {1'b0, th_ts_n[i]}) &&
            (th_need[i][k] != 4'd0) &&
            ({1'b0, th_sel_idx[i]} + 4'd1 == {1'b0, th_need[i][k]}) &&
            (th_ts_id_r[i][k+1] != th_ts_id_r[i][k] + 1'b1);
    endfunction

    int jump_cnt;
    always_comb begin
        jump_cnt = 0;
        for (int i = 0; i < MAX_THREADS; i++)
            if (th_state[i] == T_READY &&
                th_bs_pc[i] < th_off[i][th_ts_n[i]] && // 上界 = 本线程流水末（非 MAX_TS）
                is_jump_burst(i))
                jump_cnt++;
    end

    // ---- 可发射 / 调度辅助 ----
    always_comb begin
        for (int i = 0; i < MAX_THREADS; i++) begin
            // 可发射：READY 且总流水未到头；只发射当前 ts 或下一个 ts 的 burst
            // （提前过多会在 burst_sch 条件① q.ts==cur_ts 下卡住共享队列队头）；
            // ts 级互斥锁：当前 burst 若为 ts 首个（st=1）且声明加锁（lock_req=1），
            // 仅当锁空闲或本线程已持有时可发射；同锁其他线程阻塞到锁释放
            automatic burst_iv_t rb = th_burst_r[i][th_sel_ts[i]][th_sel_idx[i]];
            ready_mask[i] = (th_state[i] == T_READY) &&
                (th_bs_pc[i] < th_off[i][th_ts_n[i]]) &&
                (th_sel_ts[i] >= th_ts_idx[i]) &&
                (th_sel_ts[i] <= th_ts_idx[i] + 1) &&
                !(rb.st && rb.lock_req &&
                  lock_owner[rb.lock_id] != i[5:0] &&
                  lock_owner[rb.lock_id] != LOCK_FREE);
            ready_pri[i*3 +: 3] = th_pri_r[i];
            ready_burst_ts[i*TS_ID_W +: TS_ID_W] = th_ts_id_r[i][th_sel_ts[i]]; // 输出 ts 编号
            ready_burst_tidx[i*4 +: 4] = th_sel_ts[i]; // 输出 ts 序号（done 归属）
            ready_curts[i*TS_ID_W +: TS_ID_W] = th_cur_ts[i];
            ready_burst[i*BURST_W +: BURST_W] =
                th_burst_r[i][th_sel_ts[i]][th_sel_idx[i]];
        end
    end


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_THREADS; i++) begin
                th_state[i] <= T_IDLE;
                th_ts_n[i] <= '0;
                th_pri_r[i] <= '0;
                for (int k = 0; k < MAX_TS; k++)
                    for (int m = 0; m < MAX_BURST; m++) th_burst_r[i][k][m] <= '0;
                th_stream[i] <= '0;
                th_cid[i] <= '0;
                th_pos[i] <= '0;
                th_bs_pc[i] <= '0;
                th_cur_ts[i] <= '0;
                th_ts_idx[i] <= '0;
                for (int k = 0; k < MAX_TS; k++) th_ts_id_r[i][k] <= '0;
                th_wait[i] <= '0;
                for (int k = 0; k < MAX_TS; k++) th_done_acc[i][k] <= '0;
                for (int k = 0; k < MAX_TS; k++) th_need[i][k] <= '0;
                for (int k = 0; k < MAX_TS; k++) th_dneed[i][k] <= '0;
                for (int k = 0; k < MAX_TS; k++) th_rw_m[i][k] <= '0;
                for (int k = 0; k < MAX_TS; k++) th_occ_r[i][k] <= '0;
                th_pre_cnt[i] <= 8'd0;
                csr[i] <= '0;
            end
            for (int i = 0; i < N_LOCK; i++) lock_owner[i] <= LOCK_FREE;
            buf_head <= '0;
            buf_tail <= '0;
            buf_cnt <= '0;
            sys_ts_cnt <= '0;
        end else begin
            // ---- 建线程：缓存放行优先，否则直接到达 ----
            begin
                automatic int t = find_idle();
                automatic int s;
                automatic logic [2:0] st;
                automatic logic [CID_W-1:0] c;
                automatic logic [2:0] p;
                automatic thread_tpl_t tpl; // 线程描述：模板池随机
                automatic logic [TS_W-1:0] ts;
                automatic logic [MAX_TS*4-1:0] bs; // 每 ts burst 数向量（0..8）
                automatic logic [MAX_TS*TS_ID_W-1:0] tid_vec; // 每 ts 编号向量
                automatic logic [2:0] pr;
                automatic logic [BURST_PAT_W-1:0] bp;
                automatic logic [7:0] vtsk, dc;
                automatic logic [CW_W-1:0] cw; // 8×6B=384bit（之前 256bit 截断丢共享半区）
                logic from_buf;
                from_buf = 1'b0;
                s = -1;
                st = 0; c = '0; p = 0; ts = 0; bs = 0; tid_vec = 0; pr = 0;
                bp = '0; vtsk = 0; dc = 0; cw = '0;
                if (buf_ok) begin
                    from_buf = 1'b1;
                    s = buf_head;
                    st = buf_mem[buf_head][ST_MSB -: ST_W];
                    c = buf_mem[buf_head][CID_MSB -: CID_W];
                    p = buf_mem[buf_head][POS_MSB -: 3];
                    pr = buf_mem[buf_head][2:0];
                end else if (ko_vld && ko_rdy &&
                    !key_active(ko_stream, ko_cid, ko_pos) && t >= 0) begin
                    from_buf = 1'b0;
                    st = ko_stream; c = ko_cid; p = ko_pos;
                    pr = ko_pri; // 线程优先级继承 KO 报文优先级（0 最高）
                end
                if (t >= 0 && (from_buf || (ko_vld && ko_rdy &&
                !key_active(ko_stream, ko_cid, ko_pos)))) begin
                    // 线程描述：来源模板库优先（全 7 条流按来源/pos 匹配实测
                    // c_task 均值，TPL_MASK 全开时生效；其余走通用池）
                    if (st <= 3'd6 && tpl_mask_is_full())
                        tpl = tpl_src(st, p);
                    else
                        tpl = tpl_get(tpl_pick());
                    ts = tpl.ts_cnt;
                    bs = tpl.ts_bs;
                    tid_vec = tpl.ts_id;
                    // pr = 线程优先级（继承 KO 报文 pri，见上；模板 pri 字段废弃）
                    bp = tpl.burst_seq;
                    vtsk = tpl.vtsk_c;
                    dc = tpl.dma_c;
                    cw = tpl.cw;
                    th_state[t] <= T_READY;
                    th_ts_n[t] <= ts;
                    th_pri_r[t] <= pr;
                    for (int k = 0; k < MAX_TS; k++)
                        th_ts_id_r[t][k] <= tid_vec[k*TS_ID_W +: TS_ID_W];
                    // 每 ts 独立：实际条数 = bs[k]（br 字段为预留，不截断）；
                    // th_dneed = 该 ts 预期 done 事件数：i/v burst 计 1（有 task 即回
                    // 1 个 eu_done）、c_task burst 按 c0/c1+dma_c 有效 task 数计
                    // （空 c_task burst 为 0，不推占位 task、不占 DSE 发射机会）
                    for (int k = 0; k < MAX_TS; k++) begin
                        automatic int need_k = bs[k*4 +: 4];
                        automatic logic [4:0] dneed_k = 5'd0;
                        for (int m = 0; m < MAX_BURST; m++) begin
                            automatic logic [BURST_W-1:0] bw =
                                bp[(k*MAX_BURST + m)*BURST_W +: BURST_W];
                            automatic burst_c_t cb = bw;
                            th_burst_r[t][k][m] <= bw;
                            if (m < need_k) begin
                                if (!cb.burst_type)
                                    dneed_k = dneed_k +
                                        {(cb.c0 || (cb.vld_cu && cb.c1)) ? 5'd1 : 5'd0};
                                else begin
                                    // occ_ts 运行时抽样 1-8 偏大分布（覆盖模板值，回写 burst）
                                    cb.occ_ts0 = 8'(rw_occ_pick());
                                    cb.occ_ts1 = 8'(rw_occ_pick());
                                    th_burst_r[t][k][m] <= cb;
                                    if (cb.c0 && dc[cb.dma_id0]) begin
                                        dneed_k = dneed_k + 5'd1;
                                        th_rw_m[t][k][cb.dma_id0] <= 1'b1;
                                        th_occ_r[t][k][cb.dma_id0*3 +: 3] <=
                                            cb.occ_ts0[2:0] - 3'd1;
                                    end
                                    if (cb.vld_cu && cb.c1 && dc[cb.dma_id1]) begin
                                        dneed_k = dneed_k + 5'd1;
                                        th_rw_m[t][k][cb.dma_id1] <= 1'b1;
                                        th_occ_r[t][k][cb.dma_id1*3 +: 3] <=
                                            cb.occ_ts1[2:0] - 3'd1;
                                    end
                                end
                            end
                        end
                        th_need[t][k] <= need_k[3:0];
                        th_dneed[t][k] <= dneed_k;
                    end
                    th_stream[t] <= st;
                    th_cid[t] <= c;
                    th_pos[t] <= p;
                    th_bs_pc[t] <= 5'd0;
                    th_cur_ts[t] <= tid_vec[TS_ID_W-1:0]; // 首个 ts 编号（约定 0）
                    th_ts_idx[t] <= 4'd0;
                    th_wait[t] <= 8'd0;
                    for (int k = 0; k < MAX_TS; k++) th_done_acc[t][k] <= 3'd0;
                    // ---- CSR 表项：建线程时同步生成 ----
                    csr[t].err <= 8'd0;
                    csr[t].ccr <= 64'd0;
                    csr[t].sys_ts <= sys_ts_cnt;
                    csr[t].th_id <= t[7:0];
                    csr[t].th_stat <= T_READY;
                    csr[t].o_mes <= 8'd0;
                    csr[t].cur_ts <= tid_vec[TS_ID_W-1:0]; // 初始 = ts_id[0]（与 th_cur_ts 一致）
                    csr[t].vtsk_c <= vtsk;
                    csr[t].dma_c <= dc;
                    csr[t].tw <= 64'd0;
                    // ---- pre_read occ 门控：带预读的线程登记 ts0 bit7（屏障 =
                    //      ts0 + PRE_OCC）；读写完成按模式/op 延迟倒计时（取
                    //      各使能组的最大延迟，到 0 清 bit，T_DONE 等待同覆盖）----
                    th_pre_cnt[t] <= 8'd0;
                    if (|src_pre_vld) begin
                        automatic logic [7:0] pd = 8'd0;
                        for (int g = 0; g < 4; g++)
                            if (src_pre_vld[g]) begin
                        automatic int em = rw_eff_mode(rw_mode, pr);
                        automatic int dmin = rw_delay_min(em, src_pre_op[g]);
                        automatic int dmax = rw_delay_max(em, src_pre_op[g]);
                                automatic int d = dmin + ($urandom % (dmax - dmin + 1));
                                if (d[7:0] > pd) pd = d[7:0];
                            end
                        th_rw_m[t][0][7] <= 1'b1;
                        th_occ_r[t][0][7*3 +: 3] <= pre_occ_ts[2:0] - 3'd1;
                        th_pre_cnt[t] <= pd;
                    end
                    csr[t].cw <= cw;
                    if (from_buf) begin
                        buf_head <= (buf_head == BUF_DEPTH-1) ? '0 : buf_head + 1'b1;
                        buf_cnt <= buf_cnt - 1'b1;
                    end
                end
            end
            // ---- 直接到达入缓存（同 key 活跃时） ----
            if (ko_vld && ko_rdy &&
            key_active(ko_stream, ko_cid, ko_pos) && !buf_full) begin
                buf_mem[buf_tail] <= {ko_pre_vld, ko_dma_addr, ko_pre_op,
                ko_stream, ko_cid, ko_pos, ko_pri};
                buf_tail <= (buf_tail == BUF_DEPTH-1) ? '0 : buf_tail + 1'b1;
                buf_cnt <= buf_cnt + 1'b1;
            end
            // ---- th_sch 一级发射：进入 ISSUED 并打拍（发射后 1 拍） ----
            if (iss_vld0 && th_state[iss_tid0] == T_READY &&
            th_bs_pc[iss_tid0] < th_off[iss_tid0][th_ts_n[iss_tid0]]) begin
                burst_iv_t biv;
                biv = th_burst_r[iss_tid0][th_sel_ts[iss_tid0]][th_sel_idx[iss_tid0]];
                th_state[iss_tid0] <= T_ISSUED;
                csr[iss_tid0].th_stat <= T_ISSUED;
                // ts 级锁：ts 首个 burst 声明 lock_req 且锁空闲 → 发射时获取锁
                if (biv.st && biv.lock_req &&
                    lock_owner[biv.lock_id] == LOCK_FREE)
                    lock_owner[biv.lock_id] <= iss_tid0;
                if (is_jump_burst(iss_tid0))
                    th_wait[iss_tid0] <= 4 + ($urandom % (jump_cnt + 1)); // 1+3+t
                else
                    th_wait[iss_tid0] <= 8'd1; // 发射后 1 拍进入下一 burst
            end
            if (iss_vld1 && th_state[iss_tid1] == T_READY &&
            th_bs_pc[iss_tid1] < th_off[iss_tid1][th_ts_n[iss_tid1]]) begin
                automatic burst_iv_t biv0 =
                    th_burst_r[iss_tid0][th_sel_ts[iss_tid0]][th_sel_idx[iss_tid0]];
                burst_iv_t biv;
                biv = th_burst_r[iss_tid1][th_sel_ts[iss_tid1]][th_sel_idx[iss_tid1]];
                th_state[iss_tid1] <= T_ISSUED;
                csr[iss_tid1].th_stat <= T_ISSUED;
                if (biv.st && biv.lock_req &&
                    lock_owner[biv.lock_id] == LOCK_FREE &&
                    !(iss_vld0 && biv0.st && biv0.lock_req &&
                      biv0.lock_id == biv.lock_id))
                    lock_owner[biv.lock_id] <= iss_tid1; // 与 iss0 同锁时让 iss0 先占
                if (is_jump_burst(iss_tid1))
                    th_wait[iss_tid1] <= 4 + ($urandom % (jump_cnt + 1));
                else
                    th_wait[iss_tid1] <= 8'd1;
            end
            // ---- ISSUED 打拍推进 bs_pc（跨 ts 连续，burst 队列允许超前 ts） ----
            for (int i = 0; i < MAX_THREADS; i++) begin
                if (th_state[i] == T_ISSUED) begin
                    if (th_wait[i] <= 1) begin
                        th_state[i] <= T_READY;
                        csr[i].th_stat <= T_READY;
                        th_bs_pc[i] <= th_bs_pc[i] + 1'b1;
                    end else begin
                        th_wait[i] <= th_wait[i] - 1'b1;
                    end
                end
            end
            // ---- c_task 读写完成上报：清对应 pending 位（occ 门控屏障释放）----
            for (int d = 0; d < 4; d++)
                if (rw_done_vld[d]) begin
                    automatic logic [5:0] rt = rw_done_tid[d*6 +: 6];
                    automatic logic [3:0] rx = rw_done_tidx[d*4 +: 4];
                    automatic logic [2:0] rm = rw_done_dma[d*3 +: 3];
                    if (rt < MAX_THREADS && rx < MAX_TS)
                        th_rw_m[rt][rx][rm] <= 1'b0;
                end
            // ---- pre_read 读写完成倒计时：到 0 清 ts0 bit7 屏障（复用 tid 时
            //      旧计数必为 0——T_DONE 已等其清空，无 NBA 冲突）----
            for (int i = 0; i < MAX_THREADS; i++)
                if (th_pre_cnt[i] != 8'd0) begin
                    th_pre_cnt[i] <= th_pre_cnt[i] - 8'd1;
                    if (th_pre_cnt[i] == 8'd1)
                        th_rw_m[i][0][7] <= 1'b0;
                end
            // ---- 完成推进：eu0/eu1/dma0..3 六路 done 聚合（同 (tid,tidx) 已合并）后
            //      逐线程推进；ts 完成判据 = done 事件数 ≥ th_dneed（预期事件数）且
            //      该 ts burst 已全部发射（th_sel_ts 越过该 ts 或流水到头——事件本身
            //      隐含已发射，此条件专为 th_dneed=0 的无事件 ts 兜底检查服务）；
            //      每拍运行使 dneed=0 的 ts 无 done 事件也能推进 ----
            for (int i = 0; i < MAX_THREADS; i++) begin
                if (th_state[i] != T_IDLE && th_state[i] != T_DONE) begin
                    // done 由执行单元带回 ts 序号（发射时随 burst 下发），累加对应 ts
                    automatic logic [4:0] sh [MAX_TS];
                    automatic logic [3:0] nts = th_ts_idx[i];
                    automatic logic [3:0] old_idx = th_ts_idx[i];
                    automatic logic [TS_ID_W-1:0] ncts = th_cur_ts[i];
                    automatic logic done_th = 1'b0;
                    for (int k = 0; k < MAX_TS; k++) sh[k] = th_done_acc[i][k];
                    // 同线程不同 tidx 本拍至多一条（跨 ts done 受 cur_ts 门控互斥）；
                    // 写回按事件逐字进行，不经 sh 兜底路径写回
                    for (int u = 0; u < 6; u++)
                        if (u < done_n && done_tid_l[u] == i[5:0] &&
                            done_tidx_l[u] < MAX_TS) begin
                            sh[done_tidx_l[u]] = sh[done_tidx_l[u]] + done_cnt_l[u];
                            th_done_acc[i][done_tidx_l[u]] <= sh[done_tidx_l[u]];
                        end
                    for (int k = 0; k < 8; k++) begin
                        if (sh[nts] >= th_dneed[i][nts] &&
                            (th_sel_ts[i] > nts ||
                             th_bs_pc[i] >= th_off[i][th_ts_n[i]])) begin
                            if (nts + 1 >= th_ts_n[i]) begin
                                // 末 ts：全部读写完成才 T_DONE（避免在途 DMA 跨线程
                                // 生命周期，也防 tid 复用时 pending 被旧完成误清）
                                if (rw_empty(i))
                                    done_th = 1'b1;
                                break;
                            end
                            // occ_ts 门控：越过 ts+occ_ts 之后的 ts 需等该 ts 未完成
                            // c_task 的读写完成（dma_ctrl 70~75 拍延迟）
                            if (rw_blk(i, nts))
                                break;
                            nts = nts + 1;
                            ncts = th_ts_id_r[i][nts];
                        end else begin
                            break;
                        end
                    end
                    if (done_th || nts != old_idx) begin
                        // ts 完成时释放锁：被跨过的 ts（old_idx..nts-1）若首个 burst
                        // 声明 unlock_req，则释放该锁（unlock ts 也在锁保护下执行完）
                        for (int k = old_idx; k < nts; k++) begin
                            automatic burst_iv_t ub = th_burst_r[i][k][0];
                            if (ub.st && ub.unlock_req &&
                                lock_owner[ub.lock_id] == i[5:0])
                                lock_owner[ub.lock_id] <= LOCK_FREE;
                        end
                        if (done_th) begin
                            th_state[i] <= T_DONE;
                            csr[i].th_stat <= T_DONE;
                        end else begin
                            th_ts_idx[i] <= nts;
                            th_cur_ts[i] <= ncts;
                            csr[i].cur_ts <= ncts;
                        end
                    end
                end
            end
            // ---- 释放：DONE 回 IDLE（C 窗资源不随线程释放，由 c_task loc/free 成对管理；
            // ts 级互斥锁由 unlock ts 完成释放，线程结束兜底释放本线程持有的锁） ----
            for (int i = 0; i < MAX_THREADS; i++)
            if (th_state[i] == T_DONE) begin
                th_state[i] <= T_IDLE;
                csr[i].th_stat <= T_IDLE;
                for (int k = 0; k < N_LOCK; k++)
                    if (lock_owner[k] == i[5:0])
                        lock_owner[k] <= LOCK_FREE;
            end
            sys_ts_cnt <= sys_ts_cnt + 1'b1;
        end
    end
endmodule
