# fgOTN UVM 激励平台（uvm_sim）

基于 UVM 的 fgOTN（fine grain OTN，细粒度光传送网）帧级激励平台，面向
**fgODUflex 帧字节流接口**（4 行 x 3824 列 = 15296 字节/帧），覆盖
ITU-T G.709 Annex M/N/O 的核心开销字段：FAS/MFAS、PM/TCM1/TCM2、
DA（相位差累积）、fgOPUflex PT/CSF/OMFI 等。

本工程已在本机（Windows + MSYS2 UCRT64 + **Verilator 5.050**）完整编译、
运行并通过全部 4 个测试；同时提供 Questa/ModelSim、VCS、Xcelium 的脚本，
可直接在商用仿真器上使用。

## 目录结构

```text
uvm_sim/
├── README.md
├── rtl/
│   └── fgotn_dut_stub.sv        # DUT 占位模块（帧接收侧，可替换为真实 RTL）
├── tb/
│   ├── fgotn_if.sv              # 字节流接口（tvalid/tready/tstart/tend，时钟块含 skew）
│   └── tb_top.sv                # 顶层：时钟/复位握手、config_db+全局握手、run_test
├── uvm/
│   ├── fgotn_pkg.sv             # 包入口（编译顺序即依赖顺序）
│   ├── agent/                   # config / sequencer / driver / monitor / agent / coverage
│   ├── seq/                     # fgotn_frame_item + 5 个激励序列
│   ├── scoreboard/              # 逐字节帧比对 + BIP-8 自洽校验
│   ├── env/                     # fgotn_env（agent + scoreboard）
│   └── tests/                   # base_test + smoke/overhead/error/multiframe
├── sim/
│   ├── filelist.f               # 编译文件清单（依赖顺序）
│   ├── makefile                 # SIM=questa/vcs/xrun/verilator 通用入口
│   ├── run_verilator.sh/.bat    # Verilator 构建+运行（MSYS2）
│   ├── run_questa.bat           # Questa/ModelSim 一键编译运行
│   └── waves.do                 # Questa 波形脚本
└── tools/
    ├── uvm-core-main/           # Accellera uvm-core（已按 Verilator 打补丁）
    ├── verilator_link_fixes.cpp # GCC 16.1 string 链接补丁 + VPI 参数实现
    └── fetch_uvm_core.ps1       # uvm-core 下载脚本（GitHub 不可达时可换镜像）
```

## 快速开始

### Verilator（本机已验证）

```bash
# MSYS2 UCRT64 终端，进入 sim 目录
cd uvm_sim/sim
TESTNAME=fgotn_smoke_test NUM_FRAMES=10 SEED=1 ./run_verilator.sh

# 出波形（生成 wave.vcd，可用 GTKWave 打开）
TESTNAME=fgotn_smoke_test NUM_FRAMES=10 WAVE=1 ./run_verilator.sh
```

Windows 下也可直接双击/执行 `run_verilator.bat`（默认跑冒烟测试，
先 `set TESTNAME=...`、`set NUM_FRAMES=...` 可覆盖）。

### Questa/ModelSim

```bat
cd uvm_sim\sim
run_questa.bat fgotn_smoke_test 1 10
```

或 `make run SIM=questa TESTNAME=fgotn_smoke_test`（需 PATH 中有 vlog/vsim）。

### VCS / Xcelium

```bash
make run SIM=vcs  TESTNAME=fgotn_overhead_test
make run SIM=xrun TESTNAME=fgotn_error_test
```

## 测试用例

| 测试类 | 说明 | 验证重点 |
| --- | --- | --- |
| `fgotn_smoke_test` | 默认帧序列（`+NUM_FRAMES` 控制帧数） | 帧字节流完整透传、BIP-8 自洽 |
| `fgotn_overhead_test` | 开销聚焦（PT=02、STAT、DA、TCM 置位） | 开销字段写入/采集一致 |
| `fgotn_error_test` | 错误注入（坏 FAS + 短帧，关闭协议检查） | 错误按预期驱动且被 scoreboard 捕获 |
| `fgotn_multiframe_test` | MFAS 0→255 复帧连续 266 帧 | 256 帧复帧连续性 |

所有测试通过标准：UVM_ERROR/UVM_FATAL = 0，scoreboard 匹配帧数 = 发送帧数，
失配/BIP-8 错误 = 0。

## 激励与协议字段映射（G.709 Annex M）

| 事务字段 | 协议定义 | 帧内位置 |
| --- | --- | --- |
| `fas[8]` | FAS0~FAS7 帧定位（0x28 XOR 半行号） | 行 1~4，列 1~4 / 1905~1908 |
| `mfas` | 复帧定位（256 帧复帧） | 行 1，列 7 |
| `pm_*` | PM 通道监控（TTI/BIP-8/BDI/STAT/BEI/DM/APS） | TTI 列 1909~1910；BIP-8 行3列11；BDI/STAT/BEI 列12 |
| `tcm1_*` / `tcm2_*` | TCM1/TCM2 串联连接监控 | TTI 列 1913~1914 / 1911~1912；BIP-8 行3列8 / 列5 |
| `da[4]` | DA1~DA4 相位差累积（斜向分布） | 行 1~4，列 1915~1917 |
| `opu_pt/csf/omfi` | fgOPUflex 净荷类型/客户失效/复帧指示 | 行4列15（PT/CSF）；列16/1920 bits5-8（OMFI） |
| `payload` | fgOPUflex 净荷 15168 字节 | 列 17~1904、1921~3824 |

## 设计要点（与 Verilator 的兼容性处理）

1. **时序**：`run_test()` 在时间 0 调用；复位在独立 `initial` 块完成并通过
   包级握手标志 `g_reset_done` 通知测试；测试 `run_phase` 先
   `raise_objection` 再等待/启动。
2. **接口时钟块**：驱动侧 `default input #1step output #1`，采样侧
   `default input #1step`，避免读写竞争（Verilator 实测）。
3. **config_db 回退**：Verilator 下从模块 initial 写 config_db 可能取不到，
   tb_top 同时填充全局握手对象 `fgotn_pkg::g_tb_cfg`（含 vif），
   组件在 config_db 失败时回退读取；商用仿真器仍走标准 config_db。
4. **约束随机化回退**：Verilator 的 `randomize()` 恒返回 0（不支持约束求解），
   事务统一走 `sv_randomize()`：商业仿真器用约束随机化，Verilator 用
   `$urandom` 填充（`randomize_fallback()`）。
5. **测试类显式引用**：tb_top 中 `void'(<Test>::type_id::get())` 防止
   Verilator 把仅由 `+UVM_TESTNAME` 字符串引用的测试类优化掉。
6. **uvm-core 补丁**（tools/uvm-core-main）：
   - 注释掉 `reg/uvm_reg_model.svh`（本平台不用 RAL，编译时间大幅下降）；
   - `uvm_report_server.svh` 中 `$display` 改为 `$fdisplay(1, ...)`
     （避免 Verilator 5.050 Windows 版挂起）；
   - `uvm_dpi.cc` 不引入 `uvm_hdl_polling.c`；
   - `verilator_link_fixes.cpp` 修复 GCC 16.1 libstdc++ `basic_string`
     移动构造 C4 符号缺失的链接回归，并实现 `vpi_get_vlog_info`
     （供 UVM 命令行参数枚举）与无缓冲 stdout。
7. **帧数据**：`frame_bytes` 全程逐字节比对（scoreboard），
   BIP-8 在 scoreboard 侧独立重算并与帧内字段自洽校验。

## 已做的简化（骨架用途，按真实 DUT 规格细化）

- BIP-8 按同帧计算并回插；标准为对第 i 帧计算、插入第 i+2 帧。
- OMFI、JC/CFS、fgBWR RCOH 仅保留字段与示例写入位置，未做完整
  11 帧/256 帧复帧序列。
- TCM1/TCM2 的 BDI/STAT/BIAE 位级拆分从简（列 13 按字节合并）。
- 帧间时序（11.756/p ms）未建模，用 `inter_frame_gap` 控制空闲拍数。
- 覆盖率组件在 Verilator 下被忽略（不支持 covergroup），商业仿真器可用。

## 扩展建议

- 接入真实 fgOTN RTL：替换 `rtl/fgotn_dut_stub.sv`，接口信号按 DUT 规格对齐。
- 增加 RAL 寄存器模型管理 p 值、保护模式等参数。
- 把覆盖率扩展为协议级交叉覆盖（PT × STAT、MFAS × DA 等）。
- 增加 `tready` 反压/中断场景的随机序列。
