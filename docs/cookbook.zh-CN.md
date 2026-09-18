# Cookbook：从裸机复现终版（中文版）

目标：让一台都没碰过 DGX Spark 的新手（或 AI agent）按本章步骤，从四台裸机复现到
本项目终版——DeepSeek-V4.1-Flash TP4，4× DGX Spark 无交换机环，冷 prefill
16K/64K ≈ 2486/2495 tok/s、decode C1/C8 ≈ 52.9/169.8 tok/s。

英文版：[cookbook.md](cookbook.md)（结构相同，更紧凑）。排障：[troubleshooting.md](troubleshooting.md)。

---

## 0. 前提与物料

| 项 | 要求 |
| --- | --- |
| 硬件 | 4× DGX Spark（GB10，121.7 GiB 统一内存/台，每台 4 个 CX7 光口） |
| 线缆 | 8 条 DAC/光缆：按 §1 环型连接（每台两个邻居各两条） |
| 系统 | DGX OS（自带 CX7 驱动与 RoCE 用户态），四台互 ssh 免密，目标机 sudoers NOPASSWD |
| 管理 | 一台管理节点（你的笔记本即可），对四台免密 ssh |
| 网络 | 管理网（四台互通，用于 ssh/bootstrap/权重分发）；环口每条边独立 /24 |
| 权重 | `deepseek-ai/DeepSeek-V4.1-Flash`（ModelScope 下载 ~475 GiB/台，四台各自本机 NVMe） |
| 下载源 | 国内网络：git/pip 走镜像源，GitHub 走 `https://ghfast.top/` 前缀代理 |

全程约定（每个 `tools/` 脚本同此）：

```bash
export HOSTS="node0_ip node1_ip node2_ip node3_ip"   # 环序 rank0..rank3
export SSH_USER=<你的用户名>
```

## 1. 接线

每台 4 个光口（两块 CX7 卡各两口）分两组同构冗余：

| 口位 | PCIe1 | PCIe2 |
| --- | --- | --- |
| **pair 位（口0：enp1s0f0np0 / enP2p1s0f0np0）** | node0↔node3、node1↔node2 | 同左（第二直连） |
| **cross 位（口1：enp1s0f1np1 / enP2p1s0f1np1）** | node0↔node1、node2↔node3 | 同左（第二直连） |

即环序 node0-node1-node2-node3-node0；**每条环边有两条物理直连**（PCIe1 卡一条 +
PCIe2 卡一条，同位配对）。接好后用探测脚本实测（不要信图纸）：

```bash
bash tools/probe-4ports.sh
# 预期：每台的 enp1s0f0np0 与 enP2p1s0f0np0 两行只对两个 cross 邻居 OK；
#       enp1s0f1np1 与 enP2p1s0f1np1 只对两个 pair 邻居 OK
```

## 2. 配置双 rail 环地址

```bash
bash tools/ring-up2.sh    # 第一 rail（PCIe1 双口）：配地址 + MTU 9000 + GID 校验 + jumbo 验证
bash tools/ring-up4.sh    # 第二 rail（PCIe2 双口，增量）：同上
```

两脚本最后各自输出 GID slot3 校验与 jumbo 邻接验证，**必须全绿**（GID 空槽用
`tools/gid-fix.sh` 修，见排障 §症状1）。

## 3. 构建并部署 ring-nccl

在 node0（或任意一台）上：

```bash
git clone --depth 1 -b v2.30.7-1 https://ghfast.top/https://github.com/NVIDIA/nccl.git nccl-2307
cd nccl-2307
git apply <本仓库>/ring-nccl/ring-nccl.patch
make -j src.build CUDA_HOME=/usr/local/cuda \
  NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121"
# 产物 build/lib/libnccl.so.2.30.7；四台部署：
for h in $HOSTS; do ssh $SSH_USER@$h "sudo mkdir -p /opt/ring-nccl && sudo chown $SSH_USER /opt/ring-nccl"; \
  rsync -a build/lib/libnccl.so.2.30.7 $SSH_USER@$h:/opt/ring-nccl/ && \
  ssh $SSH_USER@$h "ln -sf libnccl.so.2.30.7 /opt/ring-nccl/libnccl.so.2"; done
```

## 4. NCCL 数值与双 rail 验收

```bash
NCCL_DIR=/opt/ring-nccl bash tools/nccl-go.sh
# 预期：node0 输出 all_reduce SUM=10.0 -> OK 与 all_gather -> OK，四机无 WARN
```

双 rail 通流证据（IB 计数器，RDMA 不走内核 net 统计）：

```bash
# 跑任一大 prefill 前后各快照一次（见 troubleshooting.md 症状2 的现成命令）
# 预期：四个 HCA 的 port_xmit_data 增量均非零
```

## 5. 引擎栈（基于社区配方）

本项目的引擎侧构建在开源社区配方之上（任选其一作为基底，二进制等价）：

- 基底 A：[MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks)（Mia 的原始配方，TP4 profile）
- 基底 B：[knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4)（同源下游，含更多调优项与文档）

以基底 A 为例：

```bash
git clone https://ghfast.top/https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks.git ~/dsv41
cd ~/dsv41

# 5.1 换用本仓库的 canary 构建文件（sglang dsv4.1 分支钉 f80c91a4b + cargo stub 防 rust 探测挂死）
cp <本仓库>/deploy/Dockerfile.canary .

# 5.2 取 sglang dsv4.1 分支树（钉 f80c91a4b，勿追新——更新 heads 在 SM121 上有已知回归）
mkdir -p runtime/sglang-canary && cd runtime/sglang-canary
curl -fsSL -m 600 "https://ghfast.top/https://github.com/sgl-project/sglang/archive/f80c91a4b.tar.gz" -o src.tgz
tar -xzf src.tgz --strip-components=1 --wildcards "sglang-*/python" && rm src.tgz && echo f80c91a4b > REF
cd ../..

# 5.3 注入 EXTRA_DOCKER_ENV 透传与 DSV41_SHARED_PAD_K（幂等）
python3 <本仓库>/deploy/patch-start-sh.py start.sh

# 5.4 补 knapcio 系 adapter 文件（shared_pad_k / indexer_chunked / spark_prefill_dense 等）
#     从基底 B 的 adapter/ 目录拷入 adapter/（基底 B 已含全套）
```

## 6. 配置 .env.tp4

以 `deploy/env.tp4.template` 为底，除网络/主机占位符外，**关键调优值按下表逐项核对**
（这些值即终版实测配置，任何一项缺失都会掉档）：

| 变量 | 值 | 作用（单变量 A/B 数据见 benchmarks.md） |
| --- | --- | --- |
| `NCCL_HOST_DIR` | `/opt/ring-nccl` | 挂载并 LD_PRELOAD 自研补丁库 |
| `IB_HCA` | `rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1` | 四口（**顺序即 EDGE_DEVS 的设备索引，勿改序**） |
| `EP_SIZE` | `2` | EP straggler 减半（decode 主贡献，+10~12%） |
| `DSV41_CACHE_GIB` / `DSV41_CACHE_WAYS` | `4` / `16` | Engram 行缓存（命中 82-88%） |
| `DSV41_SHARED_PAD_K` | `1` | shared expert K 576→640 回到 b12x kernel（bit-identical） |
| `CHUNKED_PREFILL_SIZE` | `4096` | prefill 分块（8192 会过冲 -35%，1024 少 8%） |
| `MAX_RUNNING_REQUESTS` | `16` | c16 档 graph tier |
| `EXTRA_DOCKER_ENV` | `SPARK_PREFILL_TP_SPLIT=1 SPARK_PREFILL_TP_MIN_CONTEXT=32768 SPARK_PREFILL_TP_MIN_ROWS=1024 DSV41_INDEXER_CHUNKED=1 SGLANG_DSPARK_FOLDED_SAMPLING=2 SGLANG_RUST_BUILD_MODE=never NCCL_RING_EDGE_DEVS=pair=1,3;cross=0,2` | prefill TP split（≥32k 生效）+ indexer 分块 + ring-nccl 拓扑 |
| `DSPARK_BLOCK_SIZE` | `3` | 投机解码块（prose/chat 更快；code 型负载可试 5） |
| `MEM_FRACTION_STATIC` | `0.80` | 内存水位（终版实测值） |

另：四台 GPU 时钟锁 2400MHz（GB10 有 nvidia-smi 不可见的快/慢态，不锁会有台间漂移）：

```bash
for h in $HOSTS; do ssh $SSH_USER@$h "sudo nvidia-smi -lgc 0,2400"; done
```

## 7. 权重与 Engram

```bash
# 四台各自下载（ModelScope 官方 CLI，自带 SHA 校验；并发内部分块 ~20-25 MB/s，单台约 2.5h）
pip install modelscope && modelscope download --model deepseek-ai/DeepSeek-V4.1-Flash \
  --local_dir ~/NewModels/DeepSeek-V4.1-Flash
# Engram 分片（每台 ~10 分钟）
./start-tp4.sh pack
```

## 8. 启动与验收

```bash
./start-tp4.sh build     # 四台各建 overlay 镜像（分钟级）
./start-tp4.sh serve     # 先 worker 后 head，加载 475GB 约 8-13 分钟
```

验收三条（start 脚本失败也可能退出码 0，**以这三条为准**）：

1. 四台容器日志出现 `world_size=4`；
2. `curl http://<HEAD_IP>:8888/health` 返回 200；
3. 文本烟测返回正确算术（如 "What is 19 + 23?" → `42`）。

## 9. 基准复现

部署 [sparkDash](https://github.com/MiaAI-Lab/sparkDash)（bench 工具，其 repo 有部署说明），
注册四台并把目标 spark 的 llm 端口指向 8888，然后：

```bash
SPARKDASH_HOST=<sparkDash 所在机> SPARK=<spark id> PORT=8888 bash scripts/bench.sh
```

预期（3 遍中位，冷口径，sparkDash 语料——对真实语料绝对值缩水 9-20%）：

| 指标 | 预期值 |
| --- | --- |
| 冷 prefill 16K / 64K | ~2486 / ~2495 tok/s |
| decode C1（prose） | ~52.9 tok/s |
| decode C8 聚合 | ~169.8 tok/s |

## 附录 A：调优项单变量数据

见 [benchmarks.md](benchmarks.md) 的调优构成表；每项的增量在基线之上按单变量 A/B 实测。

## 附录 B：负结果（别踩）

| 尝试 | 结果 |
| --- | --- |
| `CHUNKED_PREFILL_SIZE=8192` | 16K 档暴跌 -35%（单 forward 形态恶化）——甜点是 4096 |
| prefill CUDA graph（breakable） | 本树上 warmup replay 即 illegal memory access，不可用 |
| `--enable-two-batch-overlap` | 该模型不支持（启动硬校验拒绝） |
| `--enable-single-batch-overlap` | prefill 负贡献 -3.7% |
| RoCEnante 式 one-shot RDMA all-reduce | 环拓扑不可行（需任意两 rank 直连，环只保证邻居） |
| 照搬外部 NCCL env 段（BUFFSIZE 8M/TOS 等） | 负增益 -10%（此类参数须按本机 A/B） |
| `NCCL_MAX_NCHANNELS=8`（试图通道铺开双 rail） | 无效且更慢——铺开靠 EDGE_DEVS 定向，不靠通道数 |
| stop 脚本后不手动清容器 | 新旧容器混杂导致诡异失败（worker 清理静默失败是已知坑） |

## 附录 C：下一步优化（未做完）

- per-size 协议分带（按消息尺寸 LL/Simple，预期补齐 prefill 尾差 3%）
- NCCL proxy 线程绑核
- 通道分配策略（当前奇偶交错，可试加权）
