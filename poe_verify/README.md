# POE 功能验证平台（poe_verify）

EU 核的功能验证平台，一条直线走通：

```text
KO 48B + csr 预发射口
   → poe_thr_pool 建线程 / 取指 / 发 task
       ├ poe_burst_imem   宏指令存储（只读 ROM，每线程一个组合读口）
       ├ poe_mux          按 sub_pc 读 MUX 指令行（32 条 × 11bit），从 256B RF
       │                  取数组出 64B 操作数窗口；EU 结果再反向散射回 RF
       │   └ poe_mux_imem MUX 指令存储（16 行 × 352bit，TB/test 预载）
       ├ poe_thread_bank  每线程一份 CSR + RF 表
       └ 共享一份 EU（poe_eu_dut = 替换点 / poe_eu_rm = 参考模型），64B 窗口进出
   → ts_done / thr_done 事件 + 出口 KO（DA/SA 对调）
```

DUT 侧与 RM 侧各例化一套平台，同一个激励在顶层广播给两侧；
ts 粒度比对 CSR/RF 两张表，按 `(tid, ts)` 配对，出口 KO 按 tid 配对。

## 目录

| 目录 | 内容 |
|---|---|
| `rtl/` | 平台 RTL：`poe_pkg`（唯一位号/地址表）、`poe_thr_pool`（64 线程池）、`poe_burst_imem`（只读宏指令存储）、`poe_mux`/`poe_mux_imem`（RF 取数与回写）、`poe_thread_bank`（每线程 CSR+RF）、`poe_platform`、`poe_verify_top`、`poe_checker`、`poe_eu_dut`/`poe_eu_rm`（EU 边界壳） |
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
- **RF**：每线程 **256B（2048bit = 64 槽 × 32bit）**；示例 EU 参考模型是 128B，
  用 `poe_platform.EU_RF_W` 做视图映射（接真实 256B EU 时设成 `= RF_W` 即 1:1）。
- **CSR**：按字节寻址 `0x00..0x47`；`0x2` CCR（EU 读写）、`0x9` TH_STAT（3=DONE 结束线程）、
  `0xe` CUR_TS、`0x1c` 352bit CW 窗（8×44bit）。
- **入口**：KO 48B + csr 预发射口（`1bit vld` + 线程号 + `4bit` 表项掩码 + `4×44bit` 数据），
  建线程拍预写 CW 窗低 4 项。
- **退出**：出口 KO（DA/SA 对调）；线程结束写在 CSR `0x9 TH_STAT=DONE`。
- **两级存储**：宏指令存储是只读 ROM（模块内部 initial 拼镜像，无写口）；
  微指令存储（EU 内）与 MUX 指令存储都需要 TB/test 预载。
- **MUX（RF 取数）**：一行 32 条 × 11bit，按 `sub_pc` 索引；第 k 条固定对应 64B 窗口的
  第 k 个 2B 槽（`mvld`=0/1/2 字节，槽内低字节先）。偏移 `i=0` 时从 CSR `MUX_PTR`(0x14)
  按 `src_ptr` 低 3bit 选，`i=1` 时 `[7:0]` 即字节偏移；EU 结果按同一行指令反向散射回 RF。
- **CSR 所有权**：建线程初始化（含 `MUX_PTR` 默认值、CW 窗预发射）由平台写；
  运行期 `CCR`/`MUX_PTR` 由 EU 走通用 CSR 写口写；`TH_STAT=DONE` 由 EU 在末条 task 完成时写；
  `CUR_TS` 暂由线程池顺序推进（跳转微指令到位后切给 EU）。
- **回刷契约**：EU 的 `done` 拍 `rf_out/rmw_out` 同拍有效，`poe_thread_bank` 同拍落表
  （不能再打一拍，否则线程池的下一条 task 会读到旧 RF）。
