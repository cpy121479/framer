# POE 功能验证平台（poe_verify）

EU 核的功能验证平台，一条直线走通：

```text
KO 48B + csr 预发射口
   → poe_thr_pool 建线程 / 取指 / 发 task
       ├ poe_burst_imem   宏指令存储（只读 ROM，每线程一个组合读口）
       ├ poe_mux          MUX 级：按 sub_pc 读 MUX 指令行 → 从 256B RF 取数 +
       │                  MXS 移位 → 64B 操作数窗口；MXCC 从 32B CCR 表选 2B CSR
       │   └ poe_mux_imem MUX 指令存储（16 行 × 1280bit，TB/test 预载）
       ├ poe_dmux         DMUX 级：逆 MXS + 逆取数回填 RF（掩码保护）/ 回填 CCR 表 /
       │                  累积 32B O 窗；线程结束 → 出口 KO = {O 窗 32B, 入口 KO 低 16B}
       ├ poe_thread_bank  每线程一份 CSR + RF(256B) + CCR(32B) 表
       └ 共享一份 EU（poe_eu_dut = 替换点 / poe_eu_rm = 参考模型），64B 窗口 + 2B CCR 进出
   → ts_done / thr_done 事件 + 出口 KO（由 DMUX 直出）
```

DUT 侧与 RM 侧各例化一套平台，同一个激励在顶层广播给两侧；
ts 粒度比对 CSR/RF 两张表，按 `(tid, ts)` 配对，出口 KO 按 tid 配对。

## 目录

| 目录 | 内容 |
|---|---|
| `rtl/` | 平台 RTL：`poe_pkg`（唯一位号/地址表）、`poe_thr_pool`（64 线程池）、`poe_burst_imem`（只读宏指令存储）、`poe_mux`/`poe_mux_imem`（MUX：取数+移位）、`poe_dmux`（DMUX：回填+O 窗+KO 再生）、`poe_thread_bank`（每线程 CSR+RF+CCR）、`poe_platform`、`poe_verify_top`、`poe_checker`、`poe_eu_dut`/`poe_eu_rm`（EU 边界壳） |
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
  `poe_mux` 按 MUX 指令从 RF 取 0~2B/条、按 MXS 移位后拼出 **64B 操作数窗口**（`WIN_W=512`）给 EU；
  `poe_dmux` 在 EU 结果拍用**同一行指令**做逆操作，按掩码把"被搬过的位"回填 RF（其余位保持原值），
  一个 task 回填一次。示例 EU 模型是 128B 口，壳里把窗口放到高半区；接真实 64B EU 时把这段映射删掉即可。
- **CCR（32B 表）**：每线程另有一块 **32B CCR 表**（独立于 CSR，建线程清零）。MUX 按 **MXCC**
  从中选 2 字节给 EU（`MXCC[0]` → 高字节、`MXCC[1]` → 低字节）；DMUX 把 EU 写回的 2B 填回
  这两个字节，并**同拍镜像进 CSR 0x2**（验证侧仍按 "CSR 0x2 = CCR" 比对）。
- **CSR**：按字节寻址 `0x00..0x59`（每线程 90 字节）。`0x2` CCR（EU 读写）、`0x4` CCR_MASK、
  `0x5` SYS_TS、`0x9` TH_ID、`0xa` TH_STAT（3=DONE 结束线程）、`0xf` CUR_TS、`0x12` MUX_C、
  `0x16` MUX_PTR（64bit）、`0x1e` CW_MUX（4×32bit）、`0x2e` CW_CMD（352bit = 8×44bit）。
- **入口**：KO 48B + csr 预发射口（`1bit vld` + 线程号 + `4bit` 表项掩码 + `4×44bit` 数据），
  建线程拍预写 CW 窗低 4 项。
- **退出**：出口 KO 由 **DMUX 直出** = `{O 窗 32B（放高 32B）, 入口 KO 低 16B（原样保持）}`，
  **DA/SA 对调与透传已作废**；线程结束写在 CSR `0xa TH_STAT=DONE`，出口 KO 被取走后才释放槽位。
- **两级存储**：宏指令存储是只读 ROM（模块内部 initial 拼镜像，无写口）；
  微指令存储（EU 内）与 MUX 指令存储都需要 TB/test 预载。
- **MUX/DMUX 指令行**（一行 = 一个 `sub_pc` 的完整画像，1280bit，布局唯一定义在 `poe_pkg` ⑤ 节）：
  ① 取数 32×11bit（第 k 条 ↔ 窗口第 k 个 2B 槽，**slot 0 = 最高 16bit**；`mvld`=0/1/2；
  先取的字节放槽的高 8bit；`i=0` 时偏移从 CSR `MUX_PTR` 按 `src_ptr` 低 3bit 选，`i=1` 时 `[7:0]` 即偏移）
  ② MXS 移位 32×15bit（`[14:11]bits0 [10]lr0 [9:7]shift0 [6:4]bits1 [3]lr1 [2:0]shift1`；
  按 lr 侧跳 shift 位取 bits 位、**左对齐**：field0→槽 bit15 起、field1→槽 bit7 起；`bits0>8` 时 field1 不执行；
  **全 0 的 MXS = 直通**）
  ③ MXCC 2×5bit（32B CCR 表索引）④⑤ O 路 16×(11+15)bit（64B 窗 → 32B O 窗，供 KO 再生）。
- **CSR 所有权**：建线程初始化（含 `MUX_PTR` 默认值、CW 窗预发射）由平台写；
  运行期 `CCR` 走 `ccr_in/ccr_out → DMUX → 32B CCR 表 + CSR 0x2 镜像`；
  `MUX_PTR`/`TH_STAT`/`CUR_TS` 走 EU 的通用 CSR 写口（其中 `TH_STAT=DONE` 由 EU 在末条 task 完成时写）；
  `CUR_TS` 暂由线程池顺序推进（跳转微指令到位后切给 EU）。
- **回刷契约**：EU 的 `done` 拍 `rf_out/rmw_out` 同拍有效，`poe_thread_bank` 同拍落表
  （不能再打一拍，否则线程池的下一条 task 会读到旧 RF）。
- **EU 边界契约**：`task 握手 / 64B 窗口 in-out / 通用 CSR 读写 / done+done_tid /
  err_out（随结果拍有效）/ 微指令 bank 预载口`；比较侧已覆盖 CSR、RF、出口 KO、EU err。
  另加 **2B CCR 口**：`ccr_in`（MUX 按 MXCC 选出的 2B）→ `ccr_out`（EU 写回的 2B，交 DMUX 回填）。
  `./run.sh` 开头会做一次 **MXS 语义自检**（`MXS_SELFTEST 65536 组往返 OK`，含设计给的例子
  `0xABCD → 0x50CC`），失败会直接让 `SMOKE FAIL`。

## 接真实 EU 的替换清单（即插即用）

只改 `rtl/poe_eu_dut.sv` 一个文件（RM 侧对应 `rtl/poe_eu_rm.sv`），其余文件不动：

1. 删掉壳里的 `sa_core u_eu (...)`，换真实 EU RTL，按下面的端口逐条对齐；
2. 删掉示例模型的映射段（"POE CSR ↔ RISC-V CSR"映射、`win_in → in_regs[1023:512]` 高半区
   映射、末条 task 代写 `TH_STAT=DONE` 的占位），改成真实 EU 自己的 CSR/窗口接口；
3. 保持这些契约不变：`task_vld/task_tid/task_sub_pc/task_last/task_rdy`、
   `win_in/win_out/win_we`（64B）、`ccr_in → ccr_out`（2B CCR）、
   `csr_snap → csr_we/csr_wtid/csr_waddr/csr_ww/csr_wdata`（`TH_STAT/CUR_TS/MUX_PTR` 等；CCR 不走这里）、
   `done/done_tid`、`err_out`（随结果拍）、`imem_we/saddr/waddr/wdata`（微指令存储预载）；
4. 跑三条回归：`./run.sh`、`./run_pool_smoke.sh`、`TESTNAME=poe_base_test ./run_uvm.sh`，
   期望 `SMOKE PASS` / `UVM_ERROR 0`。

注：平台侧 `imem_*`（EU 内微指令存储预载）与 `mux_imem_*`（MUX 指令存储预载）是**两组独立端口**；
MUX 指令存储属平台（`rtl/poe_mux_imem.sv`，16 行 × 1280bit），换 EU 时不动。
