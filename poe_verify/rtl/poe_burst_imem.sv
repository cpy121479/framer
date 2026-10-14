// ============================================================================
// burst 指令存储（= 宏指令存储；burst = 宏指令 = 一个 task，叫 burst 与仓库既有词表一致）
//
//   **只读存储器**：初始化后内容不变，因此没有写接口 —— 初始化只做一次，
//   在模块内部 initial 里拼程序镜像（不依赖外部 hex，改程序只改这里）：
//       行 256bit = { 预留[255:241], jump_target[240:237], is_last[236], n_burst[235:232], 8 × 29bit burst[231:0] }
//       n_burst = 本 ts 有效 burst 条数（4bit：0=空 ts，1..8）；未用的 burst 槽保持全 0，平台按 n_burst 截断
//       29bit burst 字段见 poe_pkg 的 BF_* 表（唯一位号表）：
//         [28]bt [27]st；st=1 时 [26]lk [25]br [24:17]tsk_msk；[16]tr [15:14]vld_cu
//         [13:11]tsk_id0 [10:8]tsk_id1；[7:0] 按类型：i/v = sub_pc，c_task = {occ_ts0,occ_ts1}
//       · lk/br 是 burst 的字段，**只在 st=1（本 ts 第一条 burst）时有效**，行级不重复存
//       · 读口用 TD_* 常量定位（单一出处：poe_pkg），不再硬编码位号
//
//   读口：**每个线程一个组合读口**（N_THR 个）。取指只要 ts 行号（= 程序基址 + CUR_TS），
//         一拍返回该线程的一整行。这是行为模型：镜像内容不变，软件模拟下多读口不需要
//         仲裁 / 流水（真实 ROM 端口受限时只改本文件，池子接口不动）。
//   程序镜像是常数：DUT 平台与 RM 平台例化同一个模块 → 镜像天然一致。
// ============================================================================
// 行布局常量（TD_B_LSB / TD_N_LSB / TD_LAST / BURST_W / N_BURST）定义在 poe_pkg.sv
import poe_pkg::*;

module poe_burst_imem #(
    parameter int N_THR  = 64,   // 读口数 = 线程数（每个线程一个取指口）
    parameter int TS_MAX = 16,   // 行数：一个线程最多几个 ts
    parameter int TS_W   = 4     // 行号（ts）位宽
) (
    input  logic [N_THR*TS_W-1:0] rd_ts_flat,   // 每个读口要读的行号（= 程序基址 + CUR_TS）
    output logic [N_THR*TD_ROW_W-1:0] row_flat  // 每个读口当拍返回的整行（256bit）
);
    // ---- 程序镜像（只读）----
    logic [255:0] mem [TS_MAX];

    // ---- 程序镜像：**内部初始化**（不依赖外部 hex 文件）----
    //   一行 = 一个 ts；字段按 poe_pkg 的 TD_*/BF_* 拼，改程序只改这里。
//   st=1 标在每条 ts 的第一条 burst 上；线程结束由 CSR 0xa TH_STAT=DONE 指示。
    initial begin
        for (int i = 0; i < TS_MAX; i++) mem[i] = '0;   // 未写到的行 = 空 ts

        // ts0：2 条 i/v burst（sub_pc 0、1），非末 ts，无分支
        mem[0][TD_B_LSB + 0*BURST_W +: BURST_W] = burst_iv_pack(
            1'b1, 1'b0, 1'b0, 8'hFF, 1'b0, 2'b01, 3'd0, 3'd1, 8'd0);
        mem[0][TD_B_LSB + 1*BURST_W +: BURST_W] = burst_iv_pack(
            1'b0, 1'b0, 1'b0, 8'h00, 1'b0, 2'b01, 3'd2, 3'd3, 8'd1);
        mem[0][TD_N_LSB +: 4]    = 4'd2;    // n_burst = 2
        mem[0][TD_LAST]          = 1'b0;    // 非末 ts
        mem[0][TD_JTGT_LSB +: 4] = 4'd0;    // 无分支，不用

        // ts1：**br=1 的 ts**（被阻塞，等上个 ts 的执行结果刷新 CUR_TS）
        //   本程序里上个 ts 的结果是"跳转" → CUR_TS 被刷成 jump_target=3，ts1/ts2 都被跳过
        mem[1][TD_B_LSB + 0*BURST_W +: BURST_W] = burst_iv_pack(
            1'b1, 1'b0, 1'b1, 8'hFF, 1'b0, 2'b01, 3'd4, 3'd5, 8'd2);
        mem[1][TD_B_LSB + 1*BURST_W +: BURST_W] = burst_iv_pack(
            1'b0, 1'b0, 1'b0, 8'h00, 1'b0, 2'b01, 3'd6, 3'd7, 8'd3);
        mem[1][TD_N_LSB +: 4]    = 4'd2;
        mem[1][TD_LAST]          = 1'b0;
        mem[1][TD_JTGT_LSB +: 4] = 4'd3;    // 跳转落点 = ts3

        // ts2：故意留空（全 0）——演示"被跳过去"，本程序不会执行到

        // ts3：跳跃落点，末 ts（线程结束由 CSR 0xa TH_STAT=DONE 指示）
        //   复用 sub_pc 0/1 的微指令行，不需要额外微指令画像
        mem[3][TD_B_LSB + 0*BURST_W +: BURST_W] = burst_iv_pack(
            1'b1, 1'b0, 1'b0, 8'hFF, 1'b0, 2'b01, 3'd0, 3'd1, 8'd0);
        mem[3][TD_B_LSB + 1*BURST_W +: BURST_W] = burst_iv_pack(
            1'b0, 1'b0, 1'b0, 8'h00, 1'b0, 2'b01, 3'd2, 3'd3, 8'd1);
        mem[3][TD_N_LSB +: 4]    = 4'd2;
        mem[3][TD_LAST]          = 1'b1;
        mem[3][TD_JTGT_LSB +: 4] = 4'd0;
    end

    // ---- 组合读口：每个线程一个口，一拍返回一整行（无时钟、无复位：内容不随时间变化）----
    for (genvar t = 0; t < N_THR; t++) begin : g_rd
        assign row_flat[t*TD_ROW_W +: TD_ROW_W] = mem[rd_ts_flat[t*TS_W +: TS_W]];
    end
endmodule
