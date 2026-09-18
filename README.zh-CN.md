# DeepSeek-V4.1-Flash · 4× DGX Spark · 无交换机环

在**四台 NVIDIA DGX Spark（GB10）以无交换机 RoCE 环直连**的拓扑上，以 SGLang TP4 服务
**DeepSeek-V4.1-Flash**（552B MoE，1M 上下文）的完整复现手册与组件仓库——核心是
**ring-nccl**，我们为 NVIDIA NCCL 写的环拓扑行为补丁：

- 禁用环上无法满足的 tree/collnet/PAT 通道（对角直连要求；实测 PAT binomial 的
  rank+2 连接是初始化失败主源）；
- **按环边定向使用双物理直连（双 rail）+ 通道交错**——可用带宽翻倍（IB 计数器实证；
  环上通道交替在 [SparkRing#273](https://github.com/FujitsuPolycom/sparkring/issues/273)
  仍是 open question）；
- 拓扑用 env 描述，无编译期硬编码：

```bash
NCCL_RING_EDGE_DEVS="pair=1,3;cross=0,2"
```

**复现全栈从这里开始**：[docs/cookbook.zh-CN.md](docs/cookbook.zh-CN.md)（最详）·
[docs/cookbook.md](docs/cookbook.md)（EN）· English README: [README.md](README.md)

## 结果

冷 prefill（sparkDash 独立 prompt 语料，3 遍中位，stock FP8/MXFP4 权重，1M 上下文）：

| 指标 | 基线 | 终版 | 提升 |
| --- | --- | --- | --- |
| 冷 prefill 16K / 64K tok/s | ~1400 / ~1430 | **2486 / 2495** | **+77% / +74%** |
| decode C1 / C8 聚合 tok/s | 35.4 / ~80 | 52.9 / **169.8** | +49% / +113% |

正确性：算术烟测、64K needle 召回全过。方法、语料口径说明与参照对比
（有交换机上游 / SparkRing 起步形态）见 [docs/benchmarks.md](docs/benchmarks.md)。

## 仓库结构

| 路径 | 内容 |
| --- | --- |
| `docs/cookbook*.md` | 从裸机复现的分步手册（双语，主交付物） |
| `ring-nccl/` | NCCL 补丁 + 实现说明（hook 点、构建、env 用法） |
| `docs/design/nccl-ring-spec.md` | 补丁的行为规格（可测试的需求条目） |
| `deploy/` | 引擎侧差量：`Dockerfile.canary`、脱敏 `env.tp4.template`、幂等 `patch-start-sh.py` |
| `tools/` | 环运维：四口邻接探测、双 rail 环配置/回退、GID 检查修复、四机 NCCL 验收 |
| `scripts/bench.sh` | 一键基准封装（sparkDash API） |
| `tests/` | `NCCL_RING_EDGE_DEVS` 解析器自检（38 用例，CI 对逐字节抽取的线上逻辑跑） |
| `docs/troubleshooting.md` | 按症状索引的排障（QP 超时 / rail 零流量 / 性能偏低） |

## 快速开始

```bash
export HOSTS="ip0 ip1 ip2 ip3" SSH_USER=$USER
bash tools/probe-4ports.sh          # 实测接线
bash tools/ring-up2.sh && bash tools/ring-up4.sh
# 构建 ring-nccl（见 ring-nccl/IMPLEMENTATION.md）→ 四台 /opt/ring-nccl
NCCL_DIR=/opt/ring-nccl bash tools/nccl-go.sh   # 期望 all_reduce SUM=10.0 OK
```

引擎栈、权重、服务与基准见 cookbook §5-§9。

## 致谢

- [FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring) —— 起步服务栈
- [MiaAI-Lab](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks) 与
  [knapcio](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4) —— 基础配方、adapter 与基准工具
- NVIDIA —— NCCL（BSD-3）补丁基座

## 许可

MIT（见 `LICENSE`）；第三方归属见 `NOTICE`。
