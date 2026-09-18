# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。补丁版本号与所针对的 NCCL
版本独立声明（见各 Release 说明）。

## [0.1.0] - 2026-09-18

首个公开版本。

### ring-nccl（对 NVIDIA NCCL v2.30.7-1 的补丁）

- 环邻连接约束：禁用要求对角直连的 tree/collnet/PAT 通道（含 PAT binomial 的
  rank+2 连接，环上初始化失败的实测主源）
- 按边定向的双设备选择 + 通道交错：每条环边两条物理直连（双 rail）均通流
  （IB 计数器验证，带宽翻倍）
- `NCCL_RING_EDGE_DEVS` 运行时拓扑描述（`pair=<dev>,<dev>;cross=<dev>,<dev>`，
  全节点同值）；未设置时补丁完全旁路；world_size≠4 旁路；格式错误显式失败
- 解析器自检 38 用例（`tests/ringparse_selftest.cc`，CI 逐字节抽取被测逻辑）

### 工具（tools/）

- 四口邻接探测、双 rail 环配置（v2/v4）、环回退、GID 空槽检查/修复、
  NCCL 四机数值验收（自包含测试载荷）

### 部署配套（deploy/）

- `Dockerfile.canary`（sglang dsv4.1 分支钉 f80c91a4b + cargo stub）
- `env.tp4.template`（脱敏配置模板）与 `patch-start-sh.py`（EXTRA_DOCKER_ENV 透传注入）

### 基准

- 4× DGX Spark 无交换机环、stock 权重、1M 上下文：冷 prefill 16K/64K
  2486/2495 tok/s、decode C1/C8 52.9/169.8 tok/s（见 docs/benchmarks.md）
