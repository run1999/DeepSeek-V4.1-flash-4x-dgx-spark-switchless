# Troubleshooting

按症状索引。所有命令假设 `HOSTS`/`SSH_USER` 已设置（见 `tools/` 任意脚本头部）。

## 症状 1：NCCL 初始化失败 / `ibv_modify_qp failed with 110 Connection timed out`

环上 NCCL（无论是否打过补丁）试图连接**非直连**的对端（如 node0→node2 方向）。

诊断顺序：

1. **GID 槽位**：`bash tools/gid-check.sh`——任何 `空槽!` 都会让 NCCL 选口错乱。空槽用
   `bash tools/gid-fix.sh` 修复（删地址→重加，让 RoCE GID 对回到 slot 2/3）。
2. **补丁是否生效**：容器内确认 `NCCL_RING_EDGE_DEVS` 已注入、且 `LD_PRELOAD` 指向的
   是 ring-nccl 库（`docker exec <ct> sh -c 'echo $NCCL_RING_EDGE_DEVS $LD_PRELOAD'`）。
   未设 env 时补丁完全旁路（行为=官方 NCCL），环上必然失败。
3. **env 格式**：`pair=1,3;cross=0,2`（两键各一次，逗号分隔设备索引）。格式错时库会在
   启动日志打 WARN 并使 init 失败。

## 症状 2：服务能跑，但第二 rail 零流量（带宽减半）

IB 计数器验证（跑一次 prefill 前后对比）：

```bash
snap() { for h in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do \
  echo "$h $(cat /sys/class/infiniband/$h/ports/1/counters/port_xmit_data)"; done; }
snap > /tmp/ib1; <一次大 prefill 请求>; snap > /tmp/ib2
paste /tmp/ib1 /tmp/ib2 | awk '{printf "%-14s delta %.0f\n", $1, $3-$2}'
```

四个设备增量应均非零（注意：RDMA 不走内核 `net/statistics`，必须看 IB 计数器）。
若 `roceP2p1s0f0/1` 增量为 0：

1. `NCCL_IB_HCA` 顺序是否为 `rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1`
   （`EDGE_DEVS` 的设备索引按此顺序解释，顺序错=定向错）；
2. 第二 rail 地址是否已配（`tools/ring-up4.sh`）且 GID slot3 非空；
3. `EDGE_DEVS` 是否真的进了容器（见症状 1 第 2 步）。

## 症状 3：性能远低于预期

- **对照口径**：先跑 `scripts/bench.sh` 拿同口径数字，再与 `docs/benchmarks.md` 对照；
  注意 sparkDash 语料的 Engram 缓存偏高效应（绝对值偏高 9-20%）。
- **时钟锁定**：`nvidia-smi --query-gpu=clocks.sm` 四台应一致（我们锁定 2400MHz）；
  GB10 存在 nvidia-smi 不可见的快/慢态，四台时钟不一致会拖垮每步集合。
- **通道-设备映射**：`NCCL_DEBUG=INFO` 一次，确认 `send/recv via NET/IB/x` 在 IB/0..IB/3
  间交错（双 rail 生效的直接证据）。

## 其他已知坑

- **rsync 排除表**：同步部署树时 `--exclude models` 是全局 glob，会把源码树里的
  `sglang/srt/models/` 一并排除——排除权重目录必须写根锚定 `--exclude /models`。
- **stop 脚本残留容器**：上游 stop.sh 对 worker 清理可能静默失败（容器残留导致下次
  `docker run` 同名被吞、新旧容器混杂）；重启前手动四台 `docker rm -f` 一次。
- **canary 树的 rust 探测挂死**：sglang dsv4.1 分支的镜像处理器启动时探测 cargo，
  在无工具链环境挂死 4-20 分钟且拖爆 rendezvous——`Dockerfile.canary` 已内置 cargo
  stub（exit 1 秒败→PIL fallback）根治，勿删该层。
