# framer —— fgOTN KO / POE 验证与方案工作区

## 目录结构

```text
framer/
├─ docs/                    # 方案文档与设计图
│  ├─ *.md                  # 模块设计方案、平台方案、数据结构位宽总表等
│  └─ diagrams/             # drawio 架构图（thm-architecture / c_task_dma_flow 等）
└─ uvm_poe/                 # 主工程：KOA 调度 + POE THM/th_sch/burst_sch/CU/dma_ctrl
```

## 主工程：uvm_poe

KOA 8 组 RR+SP 调度 → POE THM（线程管理/保序/CSR）→ th_sch（一级发射）→
burst_sch（二级发射，i/v→CU，c_task→dma_ctrl）→ CU/EU 桩 + dma_ctrl（C 窗资源池）。

运行：

```bash
cd uvm_poe/sim
TESTNAME=koa_smoke_test RUN_US=30 N_OH_PLANES=4 OH_SLOTS=9520 \
  N_X2X_PLANES=8 X2X_SLOTS=9520 N_CH=8 UART_MPPS=60 WAVE=1 ./run_verilator.sh
```

详细方案见 `docs/uvm_poe平台方案.md` 与 `docs/数据结构位宽总表.md`。
