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
    //   0x0 16b ERR     0x2 16b CCR(EU 读写)  0x4 32b SYS_TS   0x8 8b TH_ID
    //   0x9  8b TH_STAT 0xa  1b O_TSK_EN      0xb  8b O_LABEL 0xc 16b PC_INTER
    //   0xe  8b CUR_TS  0xf  8b TSK_C        0x10  8b DMA_C   0x11 2b LK_SET
    //   0x12 16b LK_TAG 0x14 64b MUX_PTR     0x1c 352b CW_CMD
    //   总空间 0x00..0x47（72 字节）
    localparam logic [6:0] A_ERR      = 7'h00;   // 16b 错误告警
    localparam logic [6:0] A_CCR      = 7'h02;   // 16b EU 读写（= mstatus 低 16bit）
    localparam logic [6:0] A_SYS_TS   = 7'h04;   // 32b 系统时标（EU 当 mcycle 读）
    localparam logic [6:0] A_TH_ID    = 7'h08;   //  8b 线程 ID
    localparam logic [6:0] A_TH_STAT  = 7'h09;   //  8b 线程状态（3=DONE 即线程结束）
    localparam logic [6:0] A_O_TSK_EN = 7'h0a;   //  1b o 窗操作标签
    localparam logic [6:0] A_O_LABEL  = 7'h0b;   //  8b o 窗位置标签
    localparam logic [6:0] A_PC_INTER = 7'h0c;   // 16b 当前 PC
    localparam logic [6:0] A_CUR_TS   = 7'h0e;   //  8b 当前 ts（平台推进）
    localparam logic [6:0] A_TSK_C    = 7'h0f;   //  8b i/v task 控制（与 tsk_msk 相与）
    localparam logic [6:0] A_DMA_C    = 7'h10;   //  8b ctask 控制（与 tsk_msk 相与）
    localparam logic [6:0] A_LK_SET   = 7'h11;   //  2b 锁操作命令
    localparam logic [6:0] A_LK_TAG   = 7'h12;   // 16b 锁 tag
    localparam logic [6:0] A_MUX_PTR  = 7'h14;   // 64b MUX 指针
    localparam logic [6:0] A_CW_CMD   = 7'h1c;   // 352b C 窗访问地址
    localparam int         CSRB       = 72;      // per-thread CSR 字节数
    localparam int         CW_W       = 44;      // C 窗表项位宽（CW_CMD = 8 项 × 44bit = 352bit）
    localparam int         CW_N       = 8;       // C 窗表项数
    localparam int         PRE_N      = 4;       // 预发射口一次预写的表项数（CW 窗低 4 项）

    // 访问位宽码（写/读口用它表示"本次访问多少个字节"）
    localparam logic [2:0] W8   = 3'd0;   //  8bit
    localparam logic [2:0] W16  = 3'd1;   // 16bit
    localparam logic [2:0] W32  = 3'd2;   // 32bit
    localparam logic [2:0] W64  = 3'd3;   // 64bit
    localparam logic [2:0] W352 = 3'd4;   // 352bit

    // 线程状态取值（写 CSR 0x9 TH_STAT）
    localparam logic [7:0] TH_RUN  = 8'h01;   // 建线程后
    localparam logic [7:0] TH_DONE = 8'h03;   // 线程结束

    // ---- ④ 48B KO 报文：平台只解析行1 公共表头 + 行2 的 POE_HEAD ----
    //   行1 = [383:320]：{DA, DP, SA, SP, TYPE, {PRI, SN[12:8]}, SN[7:0], B/E/LBO}
    //   行2 = [319:256]：{POE_HEAD[31:0], MEM_HEAD[31:0]}
    //   平台只把 POE_HEAD 当作宏指令存储的行号（本镜像只有 TS_MAX 行，取低 TS_W 位）。
    localparam int KO_DA_LSB   = 376;   // [383:376] 目的模块地址（回包时与 SA 对调）
    localparam int KO_DP_LSB   = 368;   // [375:368] 宿端端口（平台不解析，原样搬运）
    localparam int KO_SA_LSB   = 360;   // [367:360] 源模块地址（回包时与 DA 对调）
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
