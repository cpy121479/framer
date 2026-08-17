# uvm_ko_stim —— 按 fgOTN 开销带宽产生 KO 指令的 UVM 平台

## 目的

POE 核处理数据流中的开销；以 fgOTN 业务为例，KO 指令的到达速率取决于业务中的**开销带宽**。
本平台在 UVM 下仿真该场景：按开销带宽产生合法 48B KO 指令，接口简化为
**1bit vld + 48 字节 KO 总线**（可选 tready 反压），并按 fgOTN 协议
（ITU-T G.709.20 / G.709 Annex M/N）建模开销位置经 **fgGMP 映射**在
**不同速率 OTN 服务层帧**中的分布；每条 KO 同时输出**服务层（行,列）**与
**fgOTN（行,列）**旁路信号，供波形核对。

## 协议模型

### fgOTN 帧与速率

- fgOTN 帧为 **4 行 × 3824 列 = 15296 字节**，帧内开销区共 **128 字节**
  （112 B fgODUflex OH + 16 B fgOPUflex OH，每行 32 字节）。
- fgODUflex(p) 标称速率 **p × 10 409 203 bit/s**（p = 占用服务层 fgTS 数，1..119）。
- fgOTN 帧周期（协议推导）：`T_fg = 15296×8 / (p × 10.409203M)`。

### 服务层映射（GMP）

- 服务层限定为 **ODU0/ODU1/ODU2**（帧均为 4×3824 = 15296 字节），fgOTN 经 fgGMP 映射，
  占用服务层 **fgTS 时隙 1..119**（ODU0 共 119、ODU1 共 238、ODU2 共 952 个 fgTS），
  fgTS 位于服务层帧净荷列 **17..3824**。
- **字节序模型**：fgOTN 字节流按帧扫描序连续推进，第 g 个 fgOTN 字节的时刻为
  `t = g × T_fg / 15296`。每服务层帧承载的 fgOTN 字节数为
  `W = 15296 × T_sf / T_fg`（含 GMP 速率适配/填充）。
- **KO 位置**：每行 2 个开销区域（左区列 1..16、右区列 1905..1920），4 行共
  **8 个区域 = 每帧 8 条 KO**，位置 k=0..7 按扫描序对应
  行1左/行1右/行2左/行2右/行3左/行3右/行4左/行4右。
- **服务层位置**：fg 字节经 GMP 均匀散布到服务层净荷区，该字节在服务层帧内的比例
  `frac = (g mod W)/W`，映射到 4×4080 帧净荷列 17..3824。

### 带宽公式

- 开销位置带宽 `BW_oh (位置/s) = oh_pos_per_frame / T_fg`
- **KO 速率 = 开销位置速率**：`KO/s = BW_oh`（每个开销位置生成一条 48B KO，不除以 48）
- 服务层 OTN 帧周期 `T_sf = otu_frame_bytes × 8 / otu_rate_bps`
- 每服务层帧 KO 数（长程均值）`KO/sf = BW_oh × T_sf`

### 位置旁路信号（波形核对）

每条 KO 发射时，以下信号与 `vld` 对齐（`sf_vld`/`fg_vld` 同为 1）：

| 信号 | 位宽 | 含义 |
| --- | --- | --- |
| `sf_vld` | 1 | 服务层位置有效 |
| `sf_row` / `sf_col` | 3 / 12 | KO 对应服务层 ODU 帧位置：行 1..4，净荷列 17..3824 |
| `sf_frame_idx` | 16 | 服务层帧号（全局位置 = 帧号×16320 + 帧内偏移，严格递增） |
| `fg_vld` | 1 | fgOTN 位置有效 |
| `fg_row` / `fg_col` | 3 / 12 | KO 对应 fgOTN 帧开销区域起点：行 1..4，列 1（左区）或 1905（右区） |
| `fg_frame_idx` | 16 | fgOTN 帧号（帧边界处行列复位，帧号递增继续全局递增） |

**fgOTN 位置映射**：位置 k = 第 k 个开销区域，帧内字节偏移 =
`(k/2)×3824 + (k%2)×1904`（每行左区偏移 0、右区偏移 1904）。8 个区域覆盖全部
128 个开销字节（每区域 16B）。

**服务层位置映射**：按穿越时刻在帧内的比例映射到 4×4080 帧的净荷区（列 17..3824），
即 fgTS 所在区域。

## 参数表

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `n_slots` | 119 | fgODUflex(p) 占用服务层 fgTS 数（p，1..119） |
| `frame_period_us` | 0 | fgOTN 帧周期（µs）；0=按 n_slots 从协议推导，>0 手动覆盖 |
| `oh_pos_per_frame` | 8 | 每 fgOTN 帧的 KO 数（**4 行 × 每行 2 个开销区域**，可配置） |
| `otu_rate_bps` | ODU2 | 服务层速率（ODU0/1/2 可选，也可直接给 ODU_RATE） |
| `otu_frame_bytes` | 15296 | ODU 帧字节数（4×3824，ODU0/1/2 相同） |
| `clk_freq_hz` | 312.5e6 | KO 接口时钟 |
| `n_frames` | 100 | 仿真的服务层帧数 |
| `jitter_pct` | 0 | KO 发射时刻抖动 %（默认 0=字节时刻确定性；只扰动时刻，不影响位置与数量） |
| `rate_tolerance_pct` | 25 | scoreboard KO 数量校验容差 % |

scoreboard 用实际 KO 总数与期望总数（字节时刻条件 `g < n_frames × W`）对比，误差超过容差
则报错，并对旁路行列号/帧号做范围检查（服务层 ODU 净荷区、fgOTN 4×3824 开销区）。

## 工程结构

```text
uvm_ko_stim/
├─ tb/            # ko_if.sv（1bit vld + 384bit(48B) KO 总线 + tready + 行列号旁路）、tb_top.sv
├─ uvm/           # ko_pkg.sv 及 item/seq/agent(driver/monitor/sequencer)/scoreboard/env/tests
├─ sim/           # filelist.f、makefile、run_verilator.sh/.bat、run_questa.bat
├─ rtl/           # （占位，无 DUT 时为空）
└─ tools/         # 复用 uvm_sim 已打补丁的 uvm-core + Verilator 链接修复
```

## 编译与运行

MSYS2（Verilator 5.050 实测路径）：

```bash
cd sim
TESTNAME=ko_smoke_test NUM_FRAMES=200 OTU_TYPE=OTU2 OH_POS=16 WAVE=1 ./run_verilator.sh
```

Windows 直接跑 `run_verilator.bat`；有 Questa 用 `run_questa.bat ko_smoke_test 1 100`。

可配 plusarg：`+ODU_TYPE=ODU0|ODU1|ODU2`、`+ODU_RATE=<bps>`、`+OH_POS=<n>`、
`+N_SLOTS=<n>`、`+FRAME_PERIOD_US=<us>`（默认 0=协议推导）、`+NUM_FRAMES=<n>`、
`+JITTER_PCT=<n>`、`+USE_TREADY=<0|1>`（`+OH_BYTES` 作为旧名兼容）。

## 说明与后续扩展

- KO 报文按 48B（6×8B）建模：行 1 公共表头 DA/DP/SA/SP/TYPE/PRI+SN/B·E·LBO，行 2
  POE_HEAD+MEM_HEAD，行 3-6 按开销/IO/控制/DMA 四种模板填充；
- 本平台聚焦**带宽与位置**（KO 速率=开销位置速率；字节序 GMP 映射给出 KO 在服务层
  ODU 帧与 fgOTN 4×3824 帧中的扫描序位置，并输出行列号+帧号旁路）；帧结构合法性
  做基础检查；
- 后续扩展：fgGMP 的 16B 块级 fgTS 逐块映射（当前按均匀散布近似）、OTUCn/flexO
  服务层、fgOTN 复帧索引
  （MFAS/OMFI）对齐、RAL 与交叉覆盖率。
