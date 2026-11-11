# POE 功能验证平台（poe_verify）

EU 核的功能验证平台，一条直线走通：

```text
KO 48B + csr 预发射口
   → poe_thr_pool 建线程 / 取指 / 发 task
       ├ poe_burst_imem   宏指令存储（只读 ROM，每线程一个组合读口）
       ├ poe_mux          MUX 级：32 fetcher 取数（高位序）+ 8 lane 移位 → 64B 窗；
       │                  8×5bit CCR 指令从 64bit CCR 提取 16bit 给 EU
       │   └ poe_mux_imem MUX 指令存储（16 行 × 768bit，TB/test 预载）
       ├ poe_dmux         DMUX 级：8/4 lane 逆变换 + 32/16 fetcher 写回 RF/CCR64/O 窗；
       │                  线程结束 → 出口 KO = {O 窗 32B, 入口 KO 低 16B}
       │   └ poe_dmux_imem DMUX 指令存储（与 MUX 独立，16 行 × 768bit）
       ├ poe_thread_bank  每线程一份 CSR + RF(256B) + CCR(64bit = 32×2bit)
       └ 共享一份 EU（poe_eu_dut = 替换点 / poe_eu_rm = 参考模型），64B 窗口 + 16bit CCR 进出
   → ts_done / thr_done 事件 + 观测事件总线（该线程 RF/CSR 快照）+ 出口 KO（由 DMUX 直出）
```

DUT 侧与 RM 侧各例化一套平台，同一个激励在顶层广播给两侧；
ts 粒度比对 CSR/RF 快照，按 `(tid, ts)` 配对，出口 KO 按 tid 配对。

## 目录

| 目录 | 内容 |
|---|---|
| `rtl/` | 平台 RTL：`poe_pkg`（唯一位号/地址表）、`poe_thr_pool`（64 线程池）、`poe_burst_imem`（只读宏指令存储）、`poe_mux`/`poe_mux_imem`（MUX：取数+移位）、`poe_dmux`/`poe_dmux_imem`（DMUX：回填+O 窗+KO 再生，独立指令存储）、`poe_thread_bank`（每线程 CSR+RF+CCR）、`poe_platform`、`poe_verify_top`、`poe_checker`、`poe_eu_dut`/`poe_eu_rm`（EU 边界壳） |
| `eu/` | sa-studio 生成的 rv32i 参考模型（与 `D:\EU核\sa-studio\rv32i` 一致，**不要改**） |
| `tb/` | `poe_if`（UVM 激励/观测契约）、`tb_top`（RTL 自检）、`uvm_tb_top`、`pool_smoke_tb`（池级冒烟） |
| `uvm/` | UVM 环境：item / seq / agent / monitor / scoreboard / env / tests |
| `sim/` | filelist + 运行脚本 |

## 运行（MSYS2 + Verilator 5.x）

```bash
cd sim
./run.sh                                # RTL 自检：2 个 KO，DUT/RM 双平台，ts 粒度比对
./run_pool_smoke.sh                     # 线程池级冒烟：6 个 KO，看优先级发射顺序
TESTNAME=poe_base_test ./run_uvm.sh     # UVM：2 个 KO，(tid,ts) 配对比对 CSR/RF/出口 KO
```

依赖仓库里已有的 `uvm_poe/tools/uvm-core-main`（UVM 库）和
`uvm_poe/tools/verilator_link_fixes.cpp`（Verilator 链接补丁）。

## 当前口径

- **线程池**：`N_THR=64`、`TID_W=6`；pri 小优先、同 pri 取最老、不抢占；
  出口 KO 被取走（`out_rdy`）后才释放线程槽。
- **RF 与窗口**：平台侧每线程 **256B（2048bit = 64 槽 × 32bit）**，EU **不直接看 RF**：
  `poe_mux` 按文档 `data_fetcher` 的**高位序**（偏移 0 = 最高两字节）取 0~2B/条，
  32 条拼成 64B 窗，再对高 8 个 2B 槽做 lane 移位；低 48B 直通。
  `poe_dmux` 用同一行指令做 lane 逆变换 + 32 路 deposit 回 RF（只写搬过的位，其余保持原值）。
  示例 EU 模型是 128B 口，壳里把窗口放到高半区；接真实 64B EU 时把这段映射删掉即可。
  **建线程默认填非零 RF 测试图样**（`RF_INIT_PATTERN=1`：`byte[idx]=((idx*37)^tid^0x5A)`，0→0x5A），
  便于微指令不写 RF 时也能观察取数/移位/回填；设 `RF_INIT_PATTERN=0` 恢复清零。
  **建线程同拍把入口 KO 48B 写入 RF[1023:512] 的顶部**，区域内**降序**（KO byte0 在 RF 字节127）；
  当前 MUX 画像用高位序偏移 `KO_FET_OFF+2k` 取 KO 高 32B 到窗 slot 0..15，O 链再把这 32B
  deposit 到 32B O 窗；出口 KO = `{O 窗 32B, 入口 KO 低 16B}`。
- **CCR（64bit）**：每线程有 **32×2bit=64bit CCR 向量**（独立于 CSR，建线程清零）。
  MUX 用 **8 条 5bit 指令**各选 1 个 2bit 码，拼成 16bit 给 EU；DMUX 用同样 8 条指令把
  EU 写回的 16bit deposit 回 64bit，并**同拍把 16bit 镜像进 CSR 0x2** 供比对。
- **CSR**：按字节寻址 `0x00..0x59`（每线程 90 字节）。`0x2` CCR（EU 读写）、`0x4` CCR_MASK、
  `0x5` SYS_TS、`0x9` TH_ID、`0xa` TH_STAT（3=DONE 结束线程）、`0xf` CUR_TS、`0x12` MUX_C、
  `0x16` MUX_PTR（64bit）、`0x1e` CW_MUX（4×32bit）、`0x2e` CW_CMD（352bit = 8×44bit）。
- **入口**：KO 48B + csr 预发射口（`1bit vld` + 线程号 + `4bit` 表项掩码 + `4×44bit` 数据），
  建线程拍预写 CW 窗低 4 项。
- **退出**：出口 KO 由 **DMUX 直出** = `{O 窗 32B（放高 32B）, 入口 KO 低 16B（原样保持）}`，
  **DA/SA 对调与透传已作废**；线程结束写在 CSR `0xa TH_STAT=DONE`，出口 KO 被取走后才释放槽位。
- **观测事件总线（波形友好）**：平台不再铺 `64×RF(256B) + 64×CSR(90B)` 的全表快照；
  每个 `ts_done` 事件锁存一份**该线程**的快照：
  `obs_vld / obs_tid / obs_ts / obs_rf(2048bit) / obs_csr(720bit)`（约 2.8kbit，一拍有效）。
  UVM monitor 在 `obs_vld` 拍直接取走；RTL checker 比 DUT/RM 两份事件（要求同拍、同 tid、同 ts）。
  线程池功能需要的 `TH_STAT`/`CUR_TS` 仍保留小表 `64×8bit`（不属于观测总线）。
- **两级存储**：宏指令存储是只读 ROM（模块内部 initial 拼镜像，无写口）；
  微指令存储（EU 内）、MUX 指令存储、DMUX 指令存储都需要 TB/test 预载；MUX/DMUX 指令存储物理独立。
- **MUX/DMUX 指令行**（一行 = 一个 `sub_pc` 的完整画像，768bit，布局唯一定义在 `poe_pkg` ⑤ 节）：
  ① 取数 32×11bit（第 k 条 ↔ 窗口第 k 个 2B 槽，slot 0 = 最高 16bit；**高位序偏移**；
  `mvld`=0/1/2/3（3 按 2）；`i=0` 查 MUX_PTR 低 3bit，`i=1` 用 `[7:0]`）；
  ② 主 lane 8×15bit（`[3:0]bits0 [4]lr0 [7:5]shift0 [10:8]bits1 [11]lr1 [14:12]shift1`；
  `bits=valid−1`、单/双操作数模式、整 lane 双向移位 + 静态窗 out0@bit0/out1@bit8）；
  ③ CCR 8×5bit（32×2bit 条件码索引）；
  ④ O 取数 16×11bit（slot k 为源、偏移为 deposit 目标）；⑤ O lane 4×15bit。
- **CSR 所有权**：建线程初始化（含 `MUX_PTR` 默认值、CW 窗预发射）由平台写；
  运行期 `CCR` 走 `ccr_in/ccr_out → DMUX → 64bit CCR + CSR 0x2 镜像`；
  `MUX_PTR`/`TH_STAT`/`CUR_TS` 走 EU 的通用 CSR 写口：EU 在 ts 最后一条 task 的结果拍写
  `CUR_TS`（br 时写 jump_target，否则 cur+1），线程最后一条 task 写 `TH_STAT=DONE`；
  **线程池只读 CSR 的 `CUR_TS`/`TH_STAT`，不写 CSR**。
- **回刷契约**：EU 的 `done` 拍 `rf_out/rmw_out` 同拍有效，`poe_thread_bank` 同拍落表
  （不能再打一拍，否则线程池的下一条 task 会读到旧 RF）。
- **EU 边界契约**：`task 握手 / 64B 窗口 in-out / 通用 CSR 读写 / done+done_tid /
  err_out（随结果拍有效）/ 微指令 bank 预载口`；比较侧已覆盖 CSR、RF、出口 KO、EU err。
  另加 **16bit CCR 口**：`ccr_in`（MUX 8×5bit 提取的 8×2bit）→ `ccr_out`（EU 写回的 8×2bit，交 DMUX deposit）。
  `./run.sh` 开头会做一次 **lane 语义自检**（`LANE_SELFTEST 65536 组往返 OK`，含文档 R4 的直通/二操作数例子），
  失败会直接让 `SMOKE FAIL`。

## 接真实 EU 的替换清单（即插即用）

只改 `rtl/poe_eu_dut.sv` 一个文件（RM 侧对应 `rtl/poe_eu_rm.sv`），其余文件不动：

1. 删掉壳里的 `sa_core u_eu (...)`，换真实 EU RTL，按下面的端口逐条对齐；
2. 删掉示例模型的映射段（"POE CSR ↔ RISC-V CSR"映射、`win_in → in_regs[1023:512]` 高半区
   映射、末条 task 代写 `TH_STAT=DONE` 的占位），改成真实 EU 自己的 CSR/窗口接口；
3. 保持这些契约不变：`task_vld/task_tid/task_sub_pc/task_last/task_rdy`、
   `win_in/win_out/win_we`（64B）、`ccr_in → ccr_out`（16bit = 8×2bit CCR）、
   `csr_snap → csr_we/csr_wtid/csr_waddr/csr_ww/csr_wdata`（`TH_STAT/CUR_TS/MUX_PTR` 等；CCR 不走这里）、
   `done/done_tid`、`err_out`（随结果拍）、`imem_we/saddr/waddr/wdata`（微指令存储预载）；
4. 跑三条回归：`./run.sh`、`./run_pool_smoke.sh`、`TESTNAME=poe_base_test ./run_uvm.sh`，
   期望 `SMOKE PASS` / `UVM_ERROR 0`。

注：平台侧 `imem_*`（EU 内微指令存储预载）、`mux_imem_*`（MUX 指令存储）、`dmux_imem_*`（DMUX 指令存储）
是**三组独立端口**；MUX/DMUX 指令存储属平台（各 16 行 × 768bit），换 EU 时不动。
