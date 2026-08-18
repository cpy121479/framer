# uvm_poe —— KOA 调度 + POE THM/th_sch/burst_sch/CU 桩行为模型平台（v5）

## 目的

模拟 **KOA → POE THM → th_sch → burst_sch → CU/EU 桩 + dma_ctrl 桩** 链路：

- **KOA**：7 条 KO 输入流（5 条 fgOTN/X2X 流带 cid/pos + 2 条串口流），写入
  **5 个独立 SBUF**（EXT/INS/ALM/UART_EXT/UART_INS，每个 SBUF 深度 2560，地址按
  pri 拆成 8 段，每段 320 深 FIFO）；**同段合并向量写**：同段同拍可写多条
  （`MAX_WR_SEG` 上限），写入顺序固定 APS 类（编小优先）→ OH 类（编小优先），
  空间不足时排在后面的让位（rdy=0、vld 保持不丢）。
  调度为 **组间 SP + 组内 RR**：每拍先选最小编号非空优先级组（0 最高），组内按
  `rr_ptr`（每拍推进）轮询 5 个 SBUF、取最先非空段出队，每拍输出 1 条，输出带
  `out_stream/out_cid/out_pos`。
- **保序在 THM**：新 KO 报文查 THM 线程池，同 `(stream,cid,pos)` 活跃线程（非 IDLE）则
  存入 **8 深报文缓存**等待，前序线程释放后按 FIFO 放行；缓存满/线程满 → `ko_rdy=0` 反压。
- **POE THM**：线程 = 若干 ts，每 ts 若干 burst；burst 为正式结构 **32bit 一种结构两种
  类型**（burst_type 区分，字段重叠）：st/tr/ts_len/branch/rev/burst_type/vld_cu/
  tsk_id0/1+c0/1+sub_pc0/1（i/v）/dma_id0/1+occ_ts0/1（c_task）。
  状态机 IDLE→READY→ISSUED→DONE（WAIT 并入 ISSUED 打拍）；**READY ≠ 回 IDLE**——
  回 READY 后可发射下一个 burst，不限制同一 ts；`bs_pc` 跨 ts 连续打拍推进，
  `cur_ts` 仅由 **cu_done 统计**推进，一级发射队列可含 cur_ts 及更靠后 ts 的 burst。
  KO 带 **pre_read** 时直接向 burst 队列插队注入一条 c_task burst（不建线程/不查保序）。
  建线程时同步生成 **CSR 表项**（err/ccr/sys_ts/th_id(6b)/th_stat/o_mes/cur_ts/vtsk_c/
  dma_c/tw/cw(8×6B)），逐步替换临时字段（th_stat/cur_ts 已同步）。
- **th_sch**：按 (pri, tid) 排序固定发射 ≤2（同 pri tid 小优先，不足从次低补）。
- **burst_sch**：二级发射，队头公共条件 = `q.ts==cur_ts` 且无 O 窗反压（`tr`，所有 burst；
  pre_read 插队 burst 跳过 ts 检查）；c_task burst（`burst_type=1`）按 c0/c1 判任务有效、
  查 CSR.dma_c 确认生效，得需执行任务数 N，**C 窗资源池可用**才放行（FIFO 空闲 ≥ N 且
  线程占用 + N ≤ 4）；生成操作指令 `{vld,th_id,op_type,smc_addr}`（≤4 路/拍）；
  ts 小优先、同 ts 按 rr 轮询，每拍最多 1 个；**i/v_task → CU/EU，c_task → dma_ctrl**。
- **CU/EU 桩 / dma_ctrl 桩**：各延迟 1 拍执行完，回 `cu_done/dma_done + tid`；dma_ctrl
  通过 **256 深 FIFO** 管理 C 窗资源（资源条目 168bit=21B；c_task 执行完归还 + 线程结束
  兜底，单线程上限 4），按 op_type 处理 **loc**（3 拍查 C 窗/申请资源/更新 CSR.cw/RBA 读）
  与 **free**（同拍去重/RBA 写 c_line/cw.o=0/查指令预存转交）；
  branch burst 后 THM 预取等待 (3+t) 拍
  （t 随机 0..n，n=当拍 READY 中 branch burst 数）。

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
| `MAX_WR_SEG`（RTL） | 16 | KOA 每段每拍合并写入条数上限（8 APS + 4 OH 同段最坏 12） |

## 运行

```bash
cd sim
TESTNAME=koa_smoke_test RUN_US=30 N_OH_PLANES=4 OH_SLOTS=9520 \
  N_X2X_PLANES=8 X2X_SLOTS=9520 N_CH=8 UART_MPPS=60 WAVE=1 ./run_verilator.sh
```

## 验证

- KOA scoreboard：5×SBUF×8 段参考模型（同拍 OUT 先 IN、rr 按拍推进对齐 DUT），
  比对优先级组号/48B 数据，校验数量守恒与队列清空。
- 实测（200µs，UART 60Mpps）：输入 39200 = 输出 39200，错配 0，UVM_ERROR 0；
  压测（30µs，UART 120Mpps）：输入 8249 = 输出 8249，错配 0，UVM_ERROR 0。
- THM 链路（同场景）：线程内 16327 个 burst 全部发射→完成一一对应（EMIT_CU 12633 +
  EMIT_DMA 3694 = DONE 12633 + DONE_DMA 3694）；pre_read 插队 319 条经 EMIT_DMA 到
  dma_ctrl；队列无 cur_ts 以前的 burst；C 窗资源池申请=归还（FINAL f_cnt=256）无死锁
  （CBLOCK=0）。
- 每次仿真报告各流反压事件/拍数。
- THM 保序缓存/线程状态的断言级 UVM 验证为后续扩展（当前靠事件日志与守恒检查）。

## 目录结构

```text
uvm_poe/
├─ rtl/poe_types.sv   # 共享类型包：burst_t（48b）/ csr_t（61B）
├─ rtl/koa.sv          # KOA：8 优先级队列 + SP/组内 FIFO，输出带 stream/cid/pos
├─ rtl/poe_thm.sv      # THM：线程池(64) + 保序检查 + 8 深缓存 + bs_pc/cur_ts 状态机
├─ rtl/poe_thsch.sv    # th_sch：按(pri,tid)选≤2 一级发射 + 2×burst 队列(深8)
├─ rtl/poe_burstsch.sv # burst_sch：二级发射（ts一致+O窗反压+C窗查询，按类型路由 CU/dma）
├─ rtl/poe_cu_stub.sv  # CU 桩：延迟1拍执行完
├─ rtl/poe_dma_ctrl_stub.sv # dma_ctrl 桩：c_task 执行，回 dma_done
├─ tb/koa_if.sv, tb_top.sv
├─ uvm/                # ko_pkg / item / seq（时隙表随机生成）/ agent / scoreboard / tests
├─ sim/                # filelist.f、run_verilator.sh/.bat
└─ tools/              # 复用已打补丁的 uvm-core + Verilator 链接修复
```
