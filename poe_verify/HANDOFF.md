# poe_verify 交付清单（填公司仿真框架用）

> 用途：把本平台填进公司自己的仿真框架。只列**需要填的文件**、编译顺序/路径、参数和期望结果；
> 本目录下的 `sim/` 脚本是本地 Verilator+MSYS2 专用，不需要带过去。

## 1. 三个顶层（框架里分别建三个 sim 目标）

| 用例 | top module | 需要编的文件组 | 期望结果 |
|---|---|---|---|
| RTL 自检（无 UVM，最常用） | `tb_top` | A + B + `tb/tb_top.sv` | `SMOKE PASS` |
| 池级冒烟（单模块） | `pool_smoke_tb` | `rtl/poe_pkg.sv` + `rtl/poe_burst_imem.sv` + `rtl/poe_thr_pool.sv` + `tb/pool_smoke_tb.sv` | `POOL_SMOKE_PASS ...` |
| UVM | `uvm_tb_top` | A + B + `tb/poe_if.sv` + `tb/uvm_tb_top.sv` + D + UVM 库 | `UVM_ERROR 0` |

## 2. 文件分组

### A. 平台 RTL（12 个，全部必填）

| 文件 | 说明 |
|---|---|
| `rtl/poe_pkg.sv` | **唯一位号/地址表**（burst 字段 / ts 行 / CSR 地址 / MUX 指令字段）；必须最先编 |
| `rtl/poe_burst_imem.sv` | 宏指令存储（只读 ROM，每线程一个组合读口） |
| `rtl/poe_mux_imem.sv` | MUX 指令存储（16 行 × 1280bit = 五组字段，TB 预载） |
| `rtl/poe_mux.sv` | MUX 级：按 MUX 指令取数 + MXS 移位组 64B 窗口；MXCC 选 2B CCR 给 EU |
| `rtl/poe_dmux.sv` | DMUX 级：逆 MXS/逆取数回填 RF（掩码保护）+ 回填 CCR 表 + O 窗累积 + 再生出口 KO |
| `rtl/poe_thread_bank.sv` | 每线程一份 CSR（90B）+ RF（256B）+ CCR（32B）表 |
| `rtl/poe_thr_pool.sv` | 线程池：建线程/取指/发 task/推 CUR_TS/事件；出口 KO 由 DMUX 直出，本模块收"已发出/已取走" |
| `rtl/poe_platform.sv` | 单边平台：把上面 + EU 装配成一份（DUT/RM 各一份） |
| `rtl/poe_verify_top.sv` | RTL 自检顶层：两份平台 + 检查器（**只有 tb_top 用**） |
| `rtl/poe_checker.sv` | RTL 自检的 ts 粒度比较器（**只有 tb_top 用**） |
| `rtl/poe_eu_dut.sv` | **EU 边界壳（DUT 侧）= 真 EU 的替换点** |
| `rtl/poe_eu_rm.sv` | EU 参考模型壳（RM 侧，与 DUT 壳同构） |

### B. EU 参考模型（生成物，13 个 .sv 必编；2 个 .json 只是生成元数据，不用编）

`eu/isa_pkg.sv`、`eu/isa_formats_pkg.sv`、`eu/isa_instr_pkg.sv`、`eu/isa_alu.sv`、
`eu/sa_pkg.sv`、`eu/sa_imem_bank.sv`、`eu/sa_pe_ialu_r.sv`、`eu/sa_pe_ialu_iu.sv`、
`eu/sa_pe_store.sv`、`eu/sa_pe_csr.sv`、`eu/sa_stage_s0.sv`、`eu/sa_stage_s1.sv`、`eu/sa_core.sv`

（`eu/arch.json`、`eu/isa-rv32i.json` 仅记录生成参数，不参与编译。）

### C. TB（4 个）

| 文件 | 说明 |
|---|---|
| `tb/tb_top.sv` | RTL 自检顶层（发 2 个 KO，等两个线程结束，打印检查结果） |
| `tb/pool_smoke_tb.sv` | 池级冒烟（6 个 KO，看优先级发射顺序） |
| `tb/poe_if.sv` | UVM 侧激励/观测接口（宽度是 localparam，必须与 `uvm_tb_top` 的 localparam 一致） |
| `tb/uvm_tb_top.sv` | UVM 顶层：接口 + 两份平台 + 跑 test |

### D. UVM 代码（8 个）

`uvm/poe_uvm_pkg.sv` 用 `` `include `` 引下面 7 个（所以 **include 路径必须含 `poe_verify/uvm`**）：

`uvm/item/poe_item.sv`、`uvm/seq/poe_ko_seq.sv`、`uvm/agent/poe_agent.sv`、
`uvm/agent/poe_monitors.sv`、`uvm/scoreboard/poe_scoreboard.sv`、`uvm/env/poe_env.sv`、
`uvm/tests/poe_base_test.sv`

编译入口只需 `uvm/poe_uvm_pkg.sv`（其余由它 include）。

### E. 外部依赖

- **UVM 库**：框架自带 UVM 就用框架的（本平台只用标准 UVM 1.2 API，**没有用 `uvm_config_db`**，
  接口通过包级全局 `poe_uvm_pkg::g_vif` 传递）；若要自带：`uvm_poe/tools/uvm-core-main/`（327 个文件）。
- **Verilator 专用**：`uvm_poe/tools/verilator_link_fixes.cpp` —— VCS/Xcelium **不要带**。

### F. 不需要填进去的（本目录专用）

`sim/filelist*.f`、`sim/run.sh`、`sim/run_uvm.sh`、`sim/run_pool_smoke.sh`（本地 Verilator+MSYS2 脚本）、
`sim/burst_imem_hex.txt`（早期参考 dump，代码已不读它）、`.gitignore`、`.gitattributes`、`sim/obj_*/`。

## 3. 编译设置

- **include 路径**：`poe_verify/uvm`（给 `include "item/..."` 等）+ UVM 库的 `src`（给 `` `include "uvm_macros.svh" ``）
- **顺序**（package 必须在前）：
  1. `rtl/poe_pkg.sv`
  2. 其余 `rtl/*.sv`（12 个里去掉 poe_pkg）
  3. `eu/isa_pkg.sv` → `eu/isa_formats_pkg.sv` → `eu/isa_instr_pkg.sv` → 其余 `eu/*.sv`
  4. `tb/*`（UVM 目标再加 `uvm/poe_uvm_pkg.sv`）
- **宏/define**：**不需要任何 `+define+`**（代码里没有 ifdef 开关；只需给 UVM 目标的 `uvm_macros.svh`）
- **timescale**：TB 自带 `` `timescale 1ns/1ps ``；`rtl/`、`eu/` 里没有声明，建议框架统一给 `-timescale=1ns/1ps`
  （Verilator 侧我们是用 `-Wno-TIMESCALEMOD` 忽略的）
- **UVM 目标额外参数**：`UVM_TESTNAME=poe_base_test`（目前只有一个 test）

## 4. 参数（当前值）

| 参数 | 值 | 定义位置 |
|---|---|---|
| `N_THR` | 64 | `tb/tb_top.sv`（poe_verify_top 例化）、`tb/uvm_tb_top.sv`（localparam） |
| `TID_W` | 6 | 同上 |
| `RF_W` | 2048（256B/线程） | 同上 |
| `WIN_W` | 512（64B 送 EU 的窗口） | `poe_platform` 默认 |
| `TS_MAX` / `TS_W` | 16 / 4 | 同上 |
| `N_BURST` | 8 | 同上 |
| `RF_INIT_PATTERN` | 1（建线程 RF 填非零测试图样；0=清零） | `poe_platform` / `poe_thread_bank` 默认 |

注意：`tb/poe_if.sv` 里的 `N_THR/TID_W/RF_W/TS_W` 是 localparam（Verilator 对接口参数化的类型敏感），
**必须与 `uvm_tb_top` 的 localparam 保持一致**（文件里已注释）。

## 5. 三条用例的期望基线（回归参照）

```
RTL 自检：MXS_SELFTEST 65536 组往返 OK（例子 0xABCD→50cc）；
          CHK ts 边界=4  err=0  出口KO=2  线程结束=2；EU err 检查 8 次全 0；tid0/tid1 CCR 5/5   SMOKE PASS
池级冒烟：POOL_SMOKE_PASS  task=24 ts_done=12 thr_done=6 out_ko=6 ct_skip=0
UVM：    CSR 4 次错 0；RF 4 次错 0；出口 KO 2 次错 0；EU 错误标志 dut=8 rm=8 次错 0；UVM_ERROR 0
```

## 6. 注意

- **观测接口**：平台输出 `ts_done` **事件快照总线** `obs_vld/obs_tid/obs_ts/obs_rf(2048b)/obs_csr(720b)`
  （约 2.8kbit，一拍有效），不再有 64 线程全表快照；UVM monitor 和 RTL checker 都在 `obs_vld` 拍取。
  线程池功能用的 `th_stat_flat` 仍是一张 `64×8bit` 小表，不属于观测总线。
- **KO 回流路径**：建线程同拍把入口 KO 48B 从 `RF[128]` 起按高字节在前写入（bank 端口 `alloc_ko`，
  平台接 `ko_data`）；当前 MUX 画像取 KO 高 32B（`RF[128..159]`）到 64B 窗 slot 0..15（MXS 直通），
  O 路再把 EU 处理后的这 32B 收进 O 窗；出口 KO = `{O 窗 32B, 入口 KO 低 16B}`（DMUX 不变）。
- `eu/` 是 sa-studio 生成的 rv32i 参考模型，DUT/RM 两个壳内部都例化同一份 —— 所以今天
  DUT vs RM 比对通过只代表"自洽"，接真实 EU 后才开始真验证。
- 接真实 EU 时**只改 `rtl/poe_eu_dut.sv`**，替换步骤见 `README.md` 的"接真实 EU 的替换清单"。
- 无第三方 IP / 无加密文件依赖。
