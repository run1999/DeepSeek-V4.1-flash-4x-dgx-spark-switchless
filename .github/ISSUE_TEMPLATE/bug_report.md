---
name: Bug report
about: ring-nccl / 环工具 / 部署问题
labels: bug
---

**环境**
- NCCL 版本与基线 commit（本项目补丁针对 v2.30.7-1 / 73cf112）：
- GPU/主机型号与数量：
- 拓扑（环序与口位）与 `NCCL_RING_EDGE_DEVS` 值：
- `NCCL_IB_HCA` 完整值：
- 容器内 `LD_PRELOAD` 与 `NCCL_DEBUG=INFO` 的相关日志片段：

**症状**（初始化失败 / 零流量 / 性能偏低 / 其他）：

**复现步骤**：

**已按 docs/troubleshooting.md 排查过的项**：
