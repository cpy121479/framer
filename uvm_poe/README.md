# uvm_poe —— KOA 调度 + POE THM/th_sch/burst_sch/EU/dma_ctrl/RBA 行为模型平台

## 目的

模拟 **KOA → POE THM → th_sch → burst_sch → EU 桩 + dma_ctrl（c_task FIFO）/ RBA** 链路：

- **KOA**：7 条 KO 输入流（5 条 fgOTN/X2X 流带 cid/pos + 2 条串口流），写入
  **5 个独立 SBUF**（EXT/INS/ALM/UART_EXT/UART_INS，每个深度 2560，按 pri 拆 8 段、
  每段 320 深）；同段合并向量写（上限 16）；调度为组间 SP + 组内 RR，每拍输出 1 条
  （`out_vld/out_pri/out_src(=优先级组号)/out_stream/out_cid/out_pos/pre_read`）。
- **THM**：保序（同 `(stream,cid,pos)` 活跃线程 → 8 深缓存 FIFO 放行；不能建线程
  且缓存满才 `ko_rdy=0`）+ 线程状态机（IDLE→READY→ISSUED→DONE）+ CSR + ts 级互斥锁
  （16 个，仅一级发射阻塞）；线程描述从模板池随机取（10 个模板 T0~T9，每 ts ≤8 burst）。
  ts 完成按预期 done 事件数（th_dneed）判定：i/v burst 计 1、c_task 按有效 task 数计，
  空 c_task burst 计 0（不入缓存、不占 DSE 机会，无事件 ts 由 THM 每拍兜底推进）。
  跳转边界（ts 末条 burst + 下一 ts_id 不连续）发射后等待 4+t 拍（t 随机，建模
  完成反馈 + 跳转竞争）。
- **th_sch（一级发射）**：全局按 `(pri, tid)` 取前 2（同锁 loc 同拍互斥）；
  q0/q1 槽池（8 深）**仅存 i/v burst**（槽项含 pri）；c_task burst 解析出有效
  c_task（c0/c1 + dma_c，cw 解析 tag/op，含 ts）入独立 16 深缓存（满则反压）。
- **burst_sch（二级发射）**：无头阻，按优先级选任意有效槽；
  i/v：q0→EU0、q1→EU1 各自独立调度（`ts==cur_ts`、非 O 窗反压）；
  c_task：4 个 DSE 调度器（DSE==tag 0..3）各选最高优先且 `ts==cur_ts` 的项，
  **发射即完成**（done 寄存 1 拍回 THM），c_task 推入 dma_ctrl 对应 DSE 的 FIFO，
  FIFO 满时反压该 DSE。
- **EU 桩 ×2**：各含 4 个 CU 桩（≤2 task 分发给 CU0/CU1，CU2/CU3 预留），
  全部完成后聚合回 1 个 `eu_done`（按 burst 计）。
- **dma_ctrl**：4 个 c_task FIFO（每 DSE 1 个，8 深，存 `{tid,tidx,dma_id,tag,op}`），
  每拍各出队 1 个（模型化消化腾空间）。
- **RBA**：4 个读写机会计数（初始 64）；dma 出队 1 个 c_task = 1 次读/写请求 →
  计数 -1，70~75 拍后归还 +1；计数为 0 反压（停止出队 → FIFO 满 → 二级发射反压）。
- **br 字段预留**：真实 ts 跳转由模板 `ts_id` 不连续标记。

## 数据结构要点

- **burst 38bit**：一种结构两种类型（`burst_type`：0=i/v、1=c_task），字段按类型复用；
  锁字段（lock_id/lock_req/unlock_req）仅 ts 首个 burst（st=1）生效；`branch`（br）预留。
- **CSR（每线程，614bit）**：err/ccr/sys_ts/th_id(6b)/th_stat/o_mes/cur_ts/vtsk_c/
  dma_c/tw/cw(8×6B)；cw 由模板初始化，th_sch 解析时只读，dma_ctrl 不回写。
- **c_task 缓存项**：`{pri, tid, tidx, ts, dma_id, tag, op}`（16 深）。

## 通道时隙表

每平面总时隙（默认 9520）随机拆给各通道（每通道 ≥1，如 1+1+9518），每平面通道数随机
1..N_CH；每通道按自己的时隙数算帧周期和带宽优先级（1..20 时隙→pri=1，>20→0）。

## 输入流

| 流 | 来源 | 每帧 KO | 报文 | 优先级 | cid/pos |
| --- | --- | --- | --- | --- | --- |
| OH_EXT | fgOTN 开销提取 | 8 | KO_OVERHEAD | **7** | 带 |
| OH_INS | fgOTN 开销下插 | 8 | KO_OVERHEAD | 带宽规则 | 带 |
| APS_EXT | X2X APS 提取 | 1 | KO_CTRL | 带宽规则 | 带 |
| APS_INS | X2X APS 下插 | 1 | KO_CTRL | 带宽规则 | 带 |
| ALM | X2X ALM | 4 | KO_CTRL | 带宽规则 | 带 |
| UART_EXT | 串口提取 | 随机 | 随机模板 | **7** | 不带 |
| UART_INS | 串口下插 | 随机 | 随机模板 | 随机 0..7 | 不带 |

## 参数（plusarg）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `RUN_US` | 200 | 激励窗口（µs） |
| `N_OH_PLANES` / `N_X2X_PLANES` | 4 / 8 | fgOTN / X2X 平面数 |
| `OH_SLOTS` / `X2X_SLOTS` | 9520 | 每平面总时隙（随机拆通道） |
| `N_CH` | 8 | 每平面最大通道数（实际随机 1..N） |
| `UART_MPPS` | 60 | 串口每路速率 |
| `WAVE_FILE` | wave.vcd | 波形文件名 |
| `MAX_THREADS`（RTL） | 64 | THM 线程数 |
| `BUF_DEPTH`（RTL） | 8 | THM 保序报文缓存深度 |
| `SBUF_DEPTH`（RTL） | 2560 | KOA 每个 SBUF 总深度（拆 8 个 pri 段，每段 320） |
| `MAX_WR_SEG`（RTL） | 16 | KOA 每段每拍合并写入条数上限 |

## 运行

```bash
cd sim
TESTNAME=koa_smoke_test RUN_US=30 N_OH_PLANES=4 OH_SLOTS=9520 \
  N_X2X_PLANES=8 X2X_SLOTS=9520 N_CH=8 UART_MPPS=60 WAVE=1 ./run_verilator.sh
```

## 验证

- KOA scoreboard：5×SBUF×8 段参考模型（SP+RR），比对优先级组号/输出顺序，
  校验数量守恒与队列清空（输入=输出、错配 0、UVM_ERROR 0）。
- POE 链路：FINAL 校验全部线程回 IDLE（idle=64）；完成事件（eu/dma done）与发射
  一一对应；每次仿真报告 RBA 反压拍数、c_task FIFO 满拍数、ct 缓存峰值/满事件、
  q0/q1 槽池峰值。
- THM 保序缓存/线程状态的断言级 UVM 验证为后续扩展（当前靠事件日志与守恒检查）。

## 目录结构

```text
uvm_poe/
├─ rtl/
│  ├─ poe_types.sv        # 共享类型包：burst(38b)/csr_t(614b)/cw/C 窗类型（保留定义）
│  ├─ poe_thread_tpl.sv   # 线程模板池（T0~T9，每 ts ≤8 burst，ts_id 可跳变）
│  ├─ koa.sv              # KOA：5×SBUF×8 段 + SP/RR 调度
│  ├─ poe_thm.sv          # THM：线程池(64)/保序(8)/CSR/ts 级锁/done 聚合(2EU+4DSE)
│  ├─ poe_thsch.sv        # th_sch：全局(pri,tid)取 2；q0/q1 存 i/v，c_task 解析入缓存
│  ├─ poe_burstsch.sv     # burst_sch：i/v 双调度 + 4×DSE 调度器；c_task 发射即 done
│  ├─ poe_eu_stub.sv      # EU 桩：4 个 CU 桩，聚合回 1 个 eu_done
│  ├─ poe_dma_ctrl.sv     # 4 个 c_task FIFO（满反压二级发射）
│  └─ poe_rba.sv          # 4 个读写机会计数（64，70~75 拍归还）
├─ tb/                    # koa_if.sv、tb_top.sv
├─ uvm/                   # ko_pkg / item / seq / agent / scoreboard / tests
├─ sim/                   # filelist.f、run_verilator.sh
└─ tools/                 # 复用已打补丁的 uvm-core + Verilator 链接修复
```