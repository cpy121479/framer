# dma_ctrl 设计方案（POE 子模块）

> 状态：初步方案草案，供讨论与迭代。

## 1. 模块定位

dma_ctrl 负责执行 c_burst 中的 DMA 类任务：

- 接收 **c_task**（c_burst 内含最多 2 个 c_task）；
- 根据 **tsk_id** 查 **CSR 表**判断具体操作类型；
- 通过 **RBA 总线**对 DMA 完成对应读 / 写操作；
- 读操作时，将结果写入 **C窗**；
- 预留一组 **KOIU → dma_ctrl** 的 KO 报文直连接口，便于后续从 KO 报文提前预读 DMA 信息、减少线程拥塞。

## 2. 对外接口

| 方向 | 接口 | 说明 |
| --- | --- | --- |
| burst_sch → dma_ctrl | c_task | c_burst 中 ≤2 个 c_task |
| dma_ctrl → CSR 表 | tsk_id 查询 | 得到操作类型 |
| dma_ctrl ↔ DMA | RBA 总线 | 读 / 写操作 |
| dma_ctrl → C窗 | 读结果 | 读操作时写入 |
| KOIU → dma_ctrl | KO 报文（预留） | 预读 DMA 信息 |

## 3. 内部结构

- **c_task 解析**：提取 tsk_id；
- **CSR 表查询**：tsk_id → 操作类型；
- **RBA 操作控制**：经 RBA 总线对 DMA 发起读 / 写；读结果写回 C窗。

## 4. 处理流程

1. 接收 c_task；
2. 按 tsk_id 查 CSR 表得到操作类型；
3. 经 RBA 总线对 DMA 执行对应操作；
4. 读操作结果写入 C窗；
5. （预留）KOIU 直连 KO 报文，提前预读 DMA 信息，减少线程拥塞。

## 5. 待确认项

- CSR 表的内容与地址映射（tsk_id → 操作类型编码）；
- RBA 总线协议与 DMA 握手；
- C窗的地址分配与写回时机；
- 旁路接口（KO 报文直连）的触发时机与数据格式。

## 6. 相关图示

- [dma_ctrl 设计](C:/Users/92541/.codex/visualizations/2026/08/06/019fd49a-1e82-7920-a852-d56510961252/dma-ctrl-design-standalone.html)
