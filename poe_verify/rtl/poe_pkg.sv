// ============================================================================
// poe_pkg —— 精简平台**唯一的位号/地址表**（其它文件不出现裸位号/裸地址）
//
// 三张表：① 29bit burst 字段 ② 256bit ts 行布局 ③ 线程 CSR 字节地址
// ============================================================================
package poe_pkg;

    // ========================================================================
    // ① 29bit burst（= 宏指令）：i/v task 与 c_task 前 21bit 相同
    //
    //   [28] bt           burst 类型：0 = i/v task，1 = c_task
    //   [27] st           是否本 ts 内头 burst
    //   ── st=1 时 [26:17] 有效 ──
    //   [26] lk           当前 ts 是否需要锁
    //   [25] br           当前 ts 是否依赖分支指令
    //   [24:17] tsk_msk   当前 ts 默认执行的 i/v task 掩码（8bit）
    //   ── st=0 时 [26:17] 为 rsv 保留字段 ──
    //   [16] tr           当前 burst 是否需要申请 O 窗
    //   [15:14] vld_cu    本 burst 内有效的 CU 指示（1 个 EU 有 2 个 CU）
    //   [13:11] tsk_id0   burst 内第 0 个 CU 的 task_id
    //   [10:8]  tsk_id1   burst 内第 1 个 CU 的 task_id
    //   ── [7:0] 按类型复用 ──
    //   i/v task：[7:0]  sub_pc      task 入口 pc
    //   c_task  ：[7:4]  occ_ts0     第 0 条 DMA 命令占用 ts 数（0=1 个 ts，1=2 个…）
    //             [3:0]  occ_ts1     第 1 条 DMA 命令占用 ts 数
    //
    // tsk_id 的选择语义（调度侧，本平台只透传不执行）：
    //   tsk_msk（头 burst，st=1）与 CSR 的 tsk_c（i/v，0xf）/ dma_c（c_task，0x10）**相与**，
    //   得到 8bit "哪些 task 要执行" 的指示；再用本 burst 的 tsk_id0/tsk_id1 去查对应 bit：
    //   为 1 执行该 task，为 0 不执行。
    // ========================================================================
    localparam int BURST_W      = 29;
    localparam int BF_BT        = 28;   // burst 类型（1=c_task）
    localparam int BF_ST        = 27;   // 本 ts 头 burst
    localparam int BF_LK        = 26;   // 仅 st=1
    localparam int BF_BR        = 25;   // 仅 st=1
    localparam int BF_TSK_MSK_LSB = 17; // [24:17] 仅 st=1；st=0 时为 rsv
    localparam int BF_TSK_MSK_W   = 8;
    localparam int BF_TR        = 16;   // 本 burst 是否申请 O 窗
    localparam int BF_VLD_CU_LSB= 14;   // [15:14] 有效 CU 指示
    localparam int BF_VLD_CU_W  = 2;
    localparam int BF_TSK_ID0_LSB = 11; // [13:11] CU0 的 task_id
    localparam int BF_TSK_ID0_W   = 3;
    localparam int BF_TSK_ID1_LSB = 8;  // [10:8]  CU1 的 task_id
    localparam int BF_TSK_ID1_W   = 3;
    localparam int BF_SUBPC_LSB = 0;    // i/v：sub_pc[7:0]
    localparam int BF_SUBPC_W   = 8;
    localparam int BF_OCC0_LSB  = 4;    // c_task：occ_ts0[3:0]
    localparam int BF_OCC0_W    = 4;
    localparam int BF_OCC1_LSB  = 0;    // c_task：occ_ts1[3:0]
    localparam int BF_OCC1_W    = 4;

    // ---- ② 256bit ts 行 = { 预留[255:241], jump_target[240:237], is_last[236], n_burst[235:232], 8 × 29bit burst[231:0] } ----
    localparam int TD_ROW_W = 256;   // 一行 ts 的总位宽（row_flat 的单元宽度）
    localparam int TD_B_LSB = 0;     // burst 数组起始位 → [231:0]，burst[b] = row[b*29 +: 29]
    localparam int TD_N_LSB = 232;   // n_burst（4bit）→ [235:232]，本 ts 有效 burst 条数（0=空 ts，1..8）
    localparam int TD_LAST  = 236;   // is_last（1bit）→ [236]，本 ts 是线程最后一个 ts
    localparam int TD_JTGT_LSB = 237; // jump_target（4bit）→ [240:237]：**平台自用占位**
                                      //   仅当本 ts 头 burst 的 br=1 时用：本 ts 被阻塞，
                                      //   等上个 ts 的执行结果刷新 CUR_TS，跳到这个 ts 行号。
                                      //   真实 EU 到位后改由 EU 回传的 jump/jump_target 驱动。

    // ---- ③ 线程 CSR：字节寻址寄存器组（每个寄存器占它自己的那几个字节）----
    //   0x0  16b ERR        0x2  16b CCR       0x4   8b CCR_MASK   0x5  32b SYS_TS
    //   0x9   8b TH_ID      0xa   8b TH_STAT   0xb   2b O_TSK_SET  0xc   8b O_LABEL
    //   0xd  16b PC_INTER   0xf   8b CUR_TS    0x10  8b TSK_C      0x11  8b DMA_C
    //   0x12  8b MUX_C      0x13  2b LK_SET    0x14 16b LK_TAG     0x16 64b MUX_PTR
    //   0x1e 128b CW_MUX    0x2e 352b CW_CMD
    //   总空间 0x00..0x59（90 字节）
    //   注：CCR_MASK / MUX_C / CW_MUX 本版只做存储与观测（随 csr_flat 一起比对），
    //       平台暂时不消费它们的语义（真 EU 到位后按需建模）。
    localparam logic [6:0] A_ERR      = 7'h00;   // 16b 错误告警
    localparam logic [6:0] A_CCR      = 7'h02;   // 16b 条件寄存器（EU 读写；= mstatus 低 16bit）
    localparam logic [6:0] A_CCR_MASK = 7'h04;   //  8b 条件寄存器刷新使能
    localparam logic [6:0] A_SYS_TS   = 7'h05;   // 32b 系统时标（EU 当 mcycle 读）
    localparam logic [6:0] A_TH_ID    = 7'h09;   //  8b 线程 ID
    localparam logic [6:0] A_TH_STAT  = 7'h0a;   //  8b 线程状态（3=DONE 即线程结束）
    localparam logic [6:0] A_O_TSK_SET= 7'h0b;   //  2b o 窗操作标签
    localparam logic [6:0] A_O_LABEL  = 7'h0c;   //  8b o 窗位置标签
    localparam logic [6:0] A_PC_INTER = 7'h0d;   // 16b 当前 PC 值
    localparam logic [6:0] A_CUR_TS   = 7'h0f;   //  8b 当前 TS
    localparam logic [6:0] A_TSK_C    = 7'h10;   //  8b i/v task 控制（与 tsk_msk 相与）
    localparam logic [6:0] A_DMA_C    = 7'h11;   //  8b ctask 控制（与 tsk_msk 相与）
    localparam logic [6:0] A_MUX_C    = 7'h12;   //  8b MUX 指针刷新使能
    localparam logic [6:0] A_LK_SET   = 7'h13;   //  2b 锁操作命令
    localparam logic [6:0] A_LK_TAG   = 7'h14;   // 16b 锁 tag
    localparam logic [6:0] A_MUX_PTR  = 7'h16;   // 64b MUX 指针（8×8bit 表）
    localparam logic [6:0] A_CW_MUX   = 7'h1e;   // 128b CW MUX（4 套 × 32bit）
    localparam logic [6:0] A_CW_CMD   = 7'h2e;   // 352b C 窗访问地址（8×44bit）
    localparam int         CSRB       = 90;      // per-thread CSR 字节数（0x00..0x59）
    localparam int         CW_W       = 44;      // C 窗表项位宽（CW_CMD = 8 项 × 44bit = 352bit）
    localparam int         CW_N       = 8;       // C 窗表项数
    localparam int         PRE_N      = 4;       // 预发射口一次预写的表项数（CW 窗低 4 项）

    // ---- ⑤ MUX（RF 取数 + 移位）/ DMUX（回填 + O 窗 + KO 再生）----
    //   一行 MUX 指令（按 sub_pc 索引，一行 = 一个 task 的完整画像）分五组字段：
    //     ① 取数组  32 × 11bit  RF 取数：第 k 条 ↔ 64B 窗的第 k 个 2B 槽（**slot 0 = 最高 16bit**）
    //     ② 移位组  32 × 15bit  MXS：与①一一配对，把取到的 16bit 里的字段左对齐到该 2B 槽
    //     ③ CCR 选择 2 ×  5bit  MXCC[0] → CSR 高字节、MXCC[1] → CSR 低字节（索引 32B CCR 表）
    //     ④ O 路取数 16 × 11bit  从 64B 窗取数填 32B O 窗（第 m 条 ↔ O 窗第 m 个 2B，m=0 最高）
    //     ⑤ O 路移位 16 × 15bit  与④配对（DMUX 侧逆操作，同一套 MXS 语义）
    //   行宽 1280bit：实际用到 1258bit，最高 22bit 预留（真实定义确定后再分配）。
    //
    //   取数指令（11bit）：
    //     [10]    i       0 = 偏移从 CSR MUX_PTR（0x16，8×8bit 表）里按 src_ptr 低 3bit 选一个字节偏移
    //                     1 = [7:0] 直接就是字节偏移
    //     [9:8]   mvld    从该偏移取几个字节：0（不取）/1/2（不是 +1）
    //     [7:0]   src_ptr i=0 时选 MUX_PTR 表项；i=1 时是偏移本身
    //   槽内字节序：**先取的字节放槽的高 8bit**（mvld=2 → 槽[15:8]=RF[off]、槽[7:0]=RF[off+1]；
    //   mvld=1 → 槽[15:8]=RF[off]、槽[7:0]=0）。
    //
    //   MXS 移位指令（15bit）：[14:11]bits0 [10]lr0 [9:7]shift0 [6:4]bits1 [3]lr1 [2:0]shift1
    //     · field0：按 lr0 侧跳过 shift0 位后取 bits0 位，**左对齐**放到 2B 槽的 bit15 起
    //       （bits0>8 时会跨到第二字节高位，低位补 0；此时 bits1 不执行）
    //     · field1：与 field0 **同一套取位规则**（都在整 16bit 源上按 lr 端数），**左对齐**放到 bit7 起
    //       lr=0 从最高位侧数（左，bit15 起），lr=1 从最低位侧数（右，bit0 起）
    //     · **全 0 的 MXS = 直通**（不做提取，16bit 原样搬运）—— 本版定义的逃逸编码，
    //       bits0 是 4bit 表达不了"16bit 全取"，直通只能这样表达，等真实定义后替换
    //   例（源 16bit = 0xABCD）：bits0=5 lr0=0 shift0=1 + bits1=7 lr1=1 shift1=1
    //     → 0x50CC（= 1_01010_000_1100110_0，丢弃的 1 是 shift0 跳过的最高位）
    localparam int MUX_AW      = 4;                                         // MUX 指令行号位宽（= sub_pc）
    localparam int MUX_INS_N   = 32;                                        // ① / ② 的条数
    localparam int MUX_INS_W   = 11;                                        // 取数指令位宽
    localparam int MXS_W       = 15;                                        // 移位指令（MXS）位宽
    localparam int MXCC_W      = 5;                                         // MXCC 位宽（索引 32B CCR → 5bit）
    localparam int MXCC_N      = 2;                                         // MXCC 条数（高字节 / 低字节）
    localparam int O_INS_N     = 16;                                        // ④ / ⑤ 的条数（32B O 窗 = 16 × 2B）
    localparam int MF_FET_LSB  = 0;                                         // ① [351:0]
    localparam int MF_MXS_LSB  = MF_FET_LSB  + MUX_INS_N*MUX_INS_W;         // ② [831:352]
    localparam int MF_MXCC_LSB = MF_MXS_LSB  + MUX_INS_N*MXS_W;             // ③ [841:832]
    localparam int MF_OFET_LSB = MF_MXCC_LSB + MXCC_N*MXCC_W;               // ④ [1017:842]
    localparam int MF_OMXS_LSB = MF_OFET_LSB + O_INS_N*MUX_INS_W;           // ⑤ [1257:1018]
    localparam int MUX_ROW_W   = 1280;                                      // 行宽（含最高 22bit 预留）

    // 取数指令字段
    localparam int MI_I_LSB    = 10;                 // 立即偏移控制位
    localparam int MI_MVLD_LSB = 8;                  // 取几个字节（0~2）
    localparam int MI_PTR_LSB  = 0;                  // src_ptr / 立即偏移
    // MXS 字段
    localparam int MXS_B0_LSB  = 11;                 // bits0[14:11]
    localparam int MXS_B0_W    = 4;
    localparam int MXS_LR0     = 10;                 // lr0：0 = 从最高位侧（左），1 = 从最低位侧（右）
    localparam int MXS_S0_LSB  = 7;                  // shift0[9:7]
    localparam int MXS_S0_W    = 3;
    localparam int MXS_B1_LSB  = 4;                  // bits1[6:4]
    localparam int MXS_B1_W    = 3;
    localparam int MXS_LR1     = 3;                  // lr1
    localparam int MXS_S1_LSB  = 0;                  // shift1[2:0]
    localparam int MXS_S1_W    = 3;

    localparam int WIN_B       = 64;                 // EU 操作数窗口字节数（64B）
    localparam int WIN_W       = WIN_B*8;            // 512bit
    localparam int CCR_B       = 32;                 // 每线程 CCR 表字节数（32B；EU 只用 MXCC 选的 2B）
    localparam int CCR_W       = CCR_B*8;            // 256bit
    localparam int O_WIN_B     = 32;                 // 每线程 O 窗字节数（线程结束时再生 KO 的高 32B）
    localparam int O_WIN_W     = O_WIN_B*8;          // 256bit
    localparam int KO_LO_LSB   = 0;                  // 出口 KO 低 16B = 入口 KO 低 16B（原样保持）
    localparam int KO_LO_W     = 128;

    // ---- MUX / DMUX 公共解码函数（两侧必须共用同一套，否则取数和回填会走偏）----
    // 取数指令 → 字节偏移（i=0 时查 CSR MUX_PTR 表）
    function automatic logic [7:0] mux_off(input logic [MUX_INS_W-1:0] ins,
                                          input logic [CSRB*8-1:0] snap);
        mux_off = ins[MI_I_LSB] ? ins[MI_PTR_LSB +: 8]
                                : snap[8*int'(A_MUX_PTR) + 8*ins[MI_PTR_LSB +: 3] +: 8];
    endfunction
    function automatic logic [1:0] mux_mvld(input logic [MUX_INS_W-1:0] ins);
        mux_mvld = ins[MI_MVLD_LSB +: 2];
    endfunction

    // 从 width 位源里取一个字段：lr=0 从最高位侧跳过 shift 位；lr=1 从最低位侧跳过 shift 位
    function automatic logic [15:0] mxs_field(input logic [15:0] src,
                                             input logic        lr,
                                             input logic [2:0]  shift,
                                             input logic [3:0]  bits,
                                             input int unsigned width);
        automatic int unsigned msb, lo;
        mxs_field = 16'd0;
        if (bits == 4'd0) return 16'd0;
        msb = lr ? (int'(shift) + int'(bits) - 1) : (width - 1 - int'(shift));
        if ((msb + 1) >= int'(bits)) begin
            lo = msb + 1 - int'(bits);
            mxs_field = (src >> lo) & ((16'd1 << int'(bits)) - 16'd1);
        end
    endfunction

    // MXS（MUX 侧）：取到的 16bit → 2B 槽（field0 左对齐到 bit15 起、field1 左对齐到 bit7 起）
    function automatic logic [15:0] mxs_align(input logic [15:0] src, input logic [MXS_W-1:0] mxs);
        automatic logic [3:0]  b0;
        automatic logic [2:0]  b1;
        automatic logic        lr0, lr1;
        automatic logic [2:0]  s0, s1;
        automatic logic [15:0] f0, f1;
        {b0, lr0, s0, b1, lr1, s1} = mxs;
        mxs_align = 16'd0;
        if (mxs == '0) begin
            mxs_align = src;                                  // 直通
        end else begin
            if (b0 != 4'd0) begin
                f0 = mxs_field(src, lr0, s0, b0, 16);
                mxs_align = f0 << (16 - int'(b0));            // field0 左对齐到 bit15 起
            end
            if ((b0 <= 4'd8) && (b1 != 4'd0)) begin           // bits0>8 时 field1 不执行
                // field1 与 field0 用**同一套取位规则**（都在整 16bit 源上按 lr 端数），
                // 区别只在落点：field0 → 槽 bit15 起，field1 → 槽 bit7 起
                f1 = mxs_field(src, lr1, s1, b1, 16);
                mxs_align |= (f1 << (8 - int'(b1)));          // field1 左对齐到 bit7 起
            end
        end
    endfunction

    // MXS（DMUX 侧逆操作）：2B 槽 → 送回源 16bit 的原位；同时给出"哪些位要回填"的掩码
    task automatic mxs_unshift(input  logic [15:0]      lane,
                               input  logic [MXS_W-1:0] mxs,
                               output logic [15:0]      val,
                               output logic [15:0]      msk);
        automatic logic [3:0]  b0;
        automatic logic [2:0]  b1;
        automatic logic        lr0, lr1;
        automatic logic [2:0]  s0, s1;
        automatic logic [15:0] f0, f1;
        automatic int unsigned msb, lo;
        {b0, lr0, s0, b1, lr1, s1} = mxs;
        val = 16'd0;
        msk = 16'd0;
        if (mxs == '0) begin
            val = lane;                                       // 直通：16bit 全回填
            msk = 16'hFFFF;
        end else begin
            if (b0 != 4'd0) begin
                f0  = lane >> (16 - int'(b0));                 // 槽的 bit15 起 b0 位
                msb = lr0 ? (int'(s0) + int'(b0) - 1) : (15 - int'(s0));
                if ((msb + 1) >= int'(b0)) begin
                    lo   = msb + 1 - int'(b0);
                    val |= f0 << lo;
                    msk |= ((16'd1 << int'(b0)) - 16'd1) << lo;
                end
            end
            if ((b0 <= 4'd8) && (b1 != 4'd0)) begin
                f1  = 16'(lane[7:0]) >> (8 - int'(b1));         // 第二字节的 bit7 起 b1 位
                msb = lr1 ? (int'(s1) + int'(b1) - 1) : (15 - int'(s1));  // 与 mxs_align 同一套取位规则
                if ((msb + 1) >= int'(b1)) begin
                    lo   = msb + 1 - int'(b1);
                    val |= f1 << lo;
                    msk |= ((16'd1 << int'(b1)) - 16'd1) << lo;
                end
            end
        end
    endtask

    // ---- 画像打包小工具（TB / UVM 预载用，避免在用例里裸拼位号）----
    function automatic logic [MUX_INS_W-1:0] mux_fetch_pack(input logic        i,
                                                           input logic [1:0]  mvld,
                                                           input logic [7:0]  ptr);
        mux_fetch_pack = {i, mvld, ptr};
    endfunction
    function automatic logic [MXS_W-1:0] mux_mxs_pack(input logic [3:0] b0, input logic lr0, input logic [2:0] s0,
                                                     input logic [2:0] b1, input logic lr1, input logic [2:0] s1);
        mux_mxs_pack = {b0, lr0, s0, b1, lr1, s1};
    endfunction

    // 访问位宽码（写/读口用它表示"本次访问多少个字节"）
    localparam logic [2:0] W8   = 3'd0;   //  8bit
    localparam logic [2:0] W16  = 3'd1;   // 16bit
    localparam logic [2:0] W32  = 3'd2;   // 32bit
    localparam logic [2:0] W64  = 3'd3;   // 64bit
    localparam logic [2:0] W352 = 3'd4;   // 352bit
    localparam logic [2:0] W128 = 3'd5;   // 128bit（CW_MUX）

    // 线程状态取值（写 CSR 0xa TH_STAT）
    localparam logic [7:0] TH_RUN  = 8'h01;   // 建线程后
    localparam logic [7:0] TH_DONE = 8'h03;   // 线程结束
    localparam logic [63:0] MUX_PTR_DEF = 64'h1C18_1410_0C08_0400;  // MUX_PTR 默认值：ptr[k]=4k（非全 0）

    // ---- ④ 48B KO 报文：平台只解析行1 公共表头 + 行2 的 POE_HEAD ----
    //   行1 = [383:320]：{DA, DP, SA, SP, TYPE, {PRI, SN[12:8]}, SN[7:0], B/E/LBO}
    //   行2 = [319:256]：{POE_HEAD[31:0], MEM_HEAD[31:0]}
    //   平台只把 POE_HEAD 当作宏指令存储的行号（本镜像只有 TS_MAX 行，取低 TS_W 位）。
    localparam int KO_DA_LSB   = 376;   // [383:376] 目的模块地址（出口 KO 由 O 窗再生，不再对调）
    localparam int KO_DP_LSB   = 368;   // [375:368] 宿端端口（平台不解析，原样搬运）
    localparam int KO_SA_LSB   = 360;   // [367:360] 源模块地址（同上；本版出口不再改这两个字段）
    localparam int KO_PRI_LSB  = 341;   // [343:341] 优先级，0 最高（线程优先级）
    localparam int KO_PRI_W    = 3;     // PRI 位宽
    localparam int KO_HEAD_LSB = 288;   // [319:288] POE_HEAD = 线程首条 burst 的加载地址

    // ---- 打包一条 29bit burst（供 burst 指令存储内部初始化程序镜像用）----
    // i/v task（bt=0）：低 8bit = sub_pc
    function automatic logic [BURST_W-1:0] burst_iv_pack(
        input logic st, input logic lk, input logic br, input logic [7:0] tsk_msk,
        input logic tr, input logic [1:0] vld_cu, input logic [2:0] tsk_id0, input logic [2:0] tsk_id1,
        input logic [7:0] sub_pc);
        burst_iv_pack = '0;
        burst_iv_pack[BF_BT] = 1'b0;
        burst_iv_pack[BF_ST] = st;
        if (st) begin
            burst_iv_pack[BF_LK] = lk;
            burst_iv_pack[BF_BR] = br;
            burst_iv_pack[BF_TSK_MSK_LSB +: BF_TSK_MSK_W] = tsk_msk;
        end
        burst_iv_pack[BF_TR]  = tr;
        burst_iv_pack[BF_VLD_CU_LSB +: BF_VLD_CU_W]   = vld_cu;
        burst_iv_pack[BF_TSK_ID0_LSB +: BF_TSK_ID0_W] = tsk_id0;
        burst_iv_pack[BF_TSK_ID1_LSB +: BF_TSK_ID1_W] = tsk_id1;
        burst_iv_pack[BF_SUBPC_LSB +: BF_SUBPC_W]     = sub_pc;
        return burst_iv_pack;
    endfunction

    // c_task（bt=1）：低 8bit = {occ_ts0[3:0], occ_ts1[3:0]}
    function automatic logic [BURST_W-1:0] burst_c_pack(
        input logic st, input logic lk, input logic br, input logic [7:0] tsk_msk,
        input logic tr, input logic [1:0] vld_cu, input logic [2:0] tsk_id0, input logic [2:0] tsk_id1,
        input logic [3:0] occ_ts0, input logic [3:0] occ_ts1);
        burst_c_pack = '0;
        burst_c_pack[BF_BT] = 1'b1;
        burst_c_pack[BF_ST] = st;
        if (st) begin
            burst_c_pack[BF_LK] = lk;
            burst_c_pack[BF_BR] = br;
            burst_c_pack[BF_TSK_MSK_LSB +: BF_TSK_MSK_W] = tsk_msk;
        end
        burst_c_pack[BF_TR]  = tr;
        burst_c_pack[BF_VLD_CU_LSB +: BF_VLD_CU_W]   = vld_cu;
        burst_c_pack[BF_TSK_ID0_LSB +: BF_TSK_ID0_W] = tsk_id0;
        burst_c_pack[BF_TSK_ID1_LSB +: BF_TSK_ID1_W] = tsk_id1;
        burst_c_pack[BF_OCC0_LSB +: BF_OCC0_W]       = occ_ts0;
        burst_c_pack[BF_OCC1_LSB +: BF_OCC1_W]       = occ_ts1;
        return burst_c_pack;
    endfunction

endpackage
