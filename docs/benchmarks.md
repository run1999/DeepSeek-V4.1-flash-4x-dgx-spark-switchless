# Benchmarks

DeepSeek-V4.1-Flash TP4 @ 4× DGX Spark（GB10），SGLang，DSpark 投机解码。

## 方法

- 工具：[sparkDash](https://github.com/MiaAI-Lab/sparkDash) bench API
  （`POST /api/sparks/<id>/llm/prefill-bench`，`contextSizes` 档；`POST .../llm/bench`，
  `concurrencies` 档、prose 256 tokens）
- 口径：冷 prefill（每档独立 prompt，无缓存命中），3 遍取中位
- 本项目数字均为 **stock 原版权重（FP8/MXFP4）+ 1M 上下文**
- 注意：sparkDash 的 prefill 语料为重复 token，Engram 行缓存命中偏高，绝对值对真实语料
  预计缩水 9-20%；跨方案对比时口径一致即可

## 结果

| 方案 | fabric | 冷 prefill 16K / 64K（tok/s） | decode C1 / C8（tok/s） |
| --- | --- | --- | --- |
| MiaAI 上游参考（官方 README 数据） | 有交换机全互联 | 3782 / 3531 | 45.4 / 114.1 |
| SparkRing 栈（本项目起步形态实测） | 无交换机环（单 rail） | ~1400 / ~1430 | 35.4 / ~80 |
| **本项目当前** | 无交换机环（双 rail） | **2486 / 2495** | **52.9 / 169.8** |

与起步形态相比：冷 prefill **+77% / +74%**，decode C1 **+49%**、C8 **+113%**；
在有交换机全互联仍占 fabric 位差的前提下，decode 已全面超过有交换机参照。

## 本项目的调优构成

| 层 | 项 |
| --- | --- |
| NCCL | `ring-nccl`（tree/PAT 对角连接禁用；`NCCL_RING_EDGE_DEVS` 按边双设备定向 + 通道交错，双 rail 通流） |
| 引擎 | `EP_SIZE=2`（EP straggler 减半，decode 主贡献）；Engram 行缓存 4GiB/16-way；shared-expert K pad（K=576→640，bit-identical）；`chunked_prefill=4096`；`SPARK_PREFILL_TP_SPLIT`（≥32k 上下文 dense indexer 查询行按 rank 分割，int all-gather 归并）；GPU 时钟锁 2400MHz |
| 硬件 | 四口双 rail 接线（每条环边 2×200G；工具见 `tools/`） |
