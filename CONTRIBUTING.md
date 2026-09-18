# Contributing

## 补丁开发约定

ring-nccl 是**行为规格驱动**的项目：任何行为变更先改
[`docs/design/nccl-ring-spec.md`](docs/design/nccl-ring-spec.md)，再改代码。

- **最小侵入**：diff 中的每一行都应该能对应到规格条目；不重构无关代码。
- **可旁路**：新行为必须有开关（env/条件），默认关闭时行为与官方 NCCL 一致。
- **自检**：env 解析类改动扩展 `tests/ringparse_selftest.cc`；行为类改动在
  PR 里给出 4 机验证输出（all_reduce/all_gather 数值 + IB 计数器双 rail 证据）。
- **版本兼容**：补丁锚定 NCCL v2.30.7-1；上游升级的适配独立成 PR 并跑
  CI 的 drift 检查。

## 工具脚本

- POSIX bash + `set -u`；主机列表一律经 `HOSTS`、用户经 `SSH_USER` 参数化，
  不得硬编码；提权一律 `sudo -n`（NOPASSWD 前提），不得内嵌凭据。
- 通过 `shellcheck`（CI 强制）。

## 文档

- 中文为主的文档保持章节锚点稳定（cookbook 按步骤编号引用）。
- 性能数字必须带口径（冷/暖、工具、权重、上下文长度），进 `docs/benchmarks.md`。
