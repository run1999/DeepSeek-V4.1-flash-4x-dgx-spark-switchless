## 改动

<!-- 一句话说明补丁/工具/文档改了什么 -->

## 关联

<!-- issue 编号或动机 -->

## 自检

- [ ] 行为规格（docs/design/nccl-ring-spec.md）已同步（若涉行为变更）
- [ ] `tests/ringparse_selftest.cc` 覆盖新解析逻辑（若涉 env 格式）
- [ ] CI 绿（patch apply + build + parser selftest + shellcheck）
- [ ] 最小侵入（diff 行数与改动点一一对应）
