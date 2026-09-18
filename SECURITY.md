# Security Policy

本仓库为部署配方与 NCCL 补丁集，不处理模型权重与用户数据。

- 工具脚本不内嵌任何凭据；如发现残留请立即报告（视为高危）。
- NCCL 补丁影响集群通信拓扑，请在隔离环境验证后再上生产。
- 报告渠道：GitHub Security Advisory（私有披露）或 issue 标注 `security`。
