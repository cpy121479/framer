# fgOTN UVM Agent（fgODUflex 帧接口）

基于前面整理的 fgOTN 协议开销内容，搭建的 UVM（Universal Verification Methodology）agent 骨架，面向 **fgODUflex 帧字节流接口**（4 行 × 3824 列 = 15296 字节/帧）。事务类中直接包含 G.709 Annex M 定义的开销字段（FAS/MFAS、PM/TCM1/TCM2、DA、fgOPUflex PT/CSF 等），driver/monitor 负责帧的发送与采集，覆盖率组件跟踪关键开销字段。

## 目录结构

```
uvm_fgotn_agent/
├── README.md
├── tb/
│   ├── fgotn_if.sv          # 字节流接口（tvalid/tready/tstart/tend）
│   ├── fgotn_base_test.sv   # 基础测试：agent + 默认帧序列
│   └── top.sv               # 顶层：时钟/复位、接口、DUT stub、run_test
└── src/
    ├── fgotn_pkg.sv         # 包入口（统一 include）
    ├── fgotn_frame_item.sv  # 帧事务：完整帧字节流 + 开销字段 + build/parse
    ├── fgotn_agent_config.sv# 配置对象（vif、active/passive、覆盖率开关）
    ├── fgotn_sequencer.sv   # 定序器
    ├── fgotn_driver.sv      # 驱动器（valid/ready 握手，支持短帧错误注入）
    ├── fgotn_monitor.sv     # 监视器（重建帧、解析开销、帧长/FAS 检查）
    ├── fgotn_coverage.sv    # 覆盖率（PT 码点、MFAS、STAT、帧长、开销存在性）
    ├── fgotn_sequences.sv   # 基础序列（默认帧 / 开销聚焦 / 错误注入）
    └── fgotn_agent.sv       # agent 封装（monitor 常驻，driver/sequencer 仅 active）
```

## 使用方式

### 1. 编译（Questa/ModelSim 示例）

```bash
vlib work
vlog +incdir+$UVM_HOME/src $UVM_HOME/src/uvm_pkg.sv
vlog tb/fgotn_if.sv tb/fgotn_base_test.sv tb/top.sv
vlog src/fgotn_pkg.sv
vsim -c work.tb_top -do "run -all; quit -f"
```

VCS 示例：

```bash
vcs -sverilog -ntb_opts uvm-1.2 -f filelist.f
./simv +UVM_TESTNAME=fgotn_base_test
```

### 2. 在测试中例化 agent

```systemverilog
// 1) 配置 config_db（在 tb 或 test build_phase 中）
uvm_config_db#(virtual fgotn_if)::set(null, "uvm_test_top", "vif", vif);

// 2) 创建 agent 并传入配置
cfg = fgotn_agent_config::type_id::create("cfg");
cfg.vif       = vif;
cfg.is_active = UVM_ACTIVE;          // 或 UVM_PASSIVE（仅监测）
uvm_config_db#(fgotn_agent_config)::set(this, "agent", "fgotn_agent_config", cfg);
agent = fgotn_agent::type_id::create("agent", this);

// 3) 跑序列
seq.start(agent.sqr);
```

### 3. 与协议开销的对应关系

| 事务字段 | 协议定义（G.709 Annex M） | 帧内位置 |
| --- | --- | --- |
| `fas[8]` | FAS0~FAS7 帧定位信号（0x28 XOR HRN） | 行 1~4，列 1~4 / 1905~1908 |
| `mfas` | 复帧定位信号（256 帧复帧） | 行 1，列 7 |
| `pm_tti/bip8/bdi/bei/stat/dm/aps` | PM 通道监控 | TTI：行 1~4 列 1909~1910；BIP-8：行 3 列 11；DM：行 2 列 7；APS：行 4 列 9~10；BDI/STAT：列 12 |
| `tcm1_*` | TCM1 串联连接监控 | TTI：列 1913~1914；BIP-8：行 3 列 8；DM：行 2 列 6；APS：行 4 列 7~8 |
| `tcm2_*` | TCM2 串联连接监控 | TTI：列 1911~1912；BIP-8：行 3 列 5；DM：行 2 列 5；APS：行 4 列 5~6 |
| `da[4]` | DA1~DA4 相位差累积（8 bit 有符号，3 取 2 判决） | 行 1~4，列 1915~1917（斜向分布） |
| `opu_pt/opu_csf/opu_omfi` | fgOPUflex 净荷类型 / 客户失效 / OMFI | 行 4 列 15（PT/CSF）；列 16/1920（OMFI） |
| `mapping_oh` | 映射专用开销（JC/CFS/fgBWR RCOH 等） | 行 1~3，列 15 / 1919 等 |

## 已做的简化（骨架用途，需按 DUT 实际规格细化）

- BIP-8 按同帧计算并回插；标准中是对第 i 帧计算、插入第 i+2 帧。
- DAi 三字节的斜向分布已按协议实现，但未实现 2/3 多数判决的恢复逻辑。
- OMFI、JC/CFS、fgBWR RCOH 仅保留字段与示例写入位置，未做完整多帧（11 帧/256 帧）序列。
- monitor 的 FAS 检查仅检查 FAS0；TCM1/TCM2 的位级拆分（BEI/BIAE 与 STAT 共字节）按简化处理。
- 帧间时序（帧周期 11.756/p ms）未建模，仅通过 `inter_frame_gap` 控制空闲拍。

## 扩展建议

- 增加 scoreboard：对比 monitor 输出与参考模型（如 BIP-8 校验、开销字段透传检查）。
- 增加寄存器/配置模型（UVM RAL）管理 p、保护模式等参数。
- 将覆盖率扩展为协议级交叉覆盖（PT × STAT、MFAS × DA 等）。
- 需要时把 `fgotn_if` 换成带 ready 反压/中断的真实 RTL 接口时序。
