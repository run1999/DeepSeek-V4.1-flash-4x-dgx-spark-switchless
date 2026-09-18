# ring-nccl — Implementation Notes

- Base: NVIDIA NCCL **v2.30.7-1**（官方 clone，commit `73cf112`）
- Patch: `ring-nccl.patch`（源码树内 `git diff` 产物，未 commit）
- 目标硬件：4 台 DGX Spark 组成无交换机环（rank 0-1-2-3-0），每台 4 个 RDMA 设备；相邻 rank 对之间两条同位直连（f1 位或 f0 位），非相邻 rank 对（0,2）(1,3) 无任何直连。


## 环境变量（SR-3）

```
NCCL_RING_EDGE_DEVS="pair=1,3;cross=0,2"
```

- **全机同值**：值是“边型规则”，不含任何 rank id，四台机器注入**同一条**即可（匹配部署管线全节点统一注入 env 的形态）。库内按 `(myRank, peerRank)` 自行判边型。
- 4-rank 环（环序 0-1-2-3-0）的边分两类：
  - `pair` 边 = rank 对 {(0,1),(2,3)}；`cross` 边 = {(1,2),(3,0)}。
  - 判定规则：myRank 为偶数时 peer=(myRank+1)%4 是 `pair` 边、peer=(myRank+3)%4 是 `cross` 边；myRank 为奇数时反之。
- `dev`：网络设备索引 = NCCL 设备枚举序中的位置，即 `NCCL_DEBUG=INFO` 日志 `NET/IB: [i] <name>` 行的 `[i]`。使用 `NCCL_IB_HCA` 时请按该枚举顺序书写（自然升序即一致），使“HCA 列表第 i 项 == 设备索引 i”。**所列设备必须在每个节点都存在**，否则 init 报错。
- 两个 key（`pair`、`cross`）各必须恰好出现一次（先后随意）；每 key 可列 1~4 个设备；通道 `c` 使用该边型列表的第 `c % n` 个设备（SR-4 的 `c%2` 即 n=2 的标准用法）。
- 格式演进：初版 per-rank 格式（`NCCL_RING_PEER_DEVS="1=1,3;3=0,2"`，每机不同值）已**移除**——部署管线对全节点注入同一组 env，per-rank 格式与之不匹配；旧值不再被识别，配错按格式错误处理（WARN + init 失败）。

4 机环示例（四机同一条；假设四台设备的枚举序一致：`rocep1s0f0=0, rocep1s0f1=1, rocep2p1s0f0=2, rocep2p1s0f1=3`；**上线前以各节点日志 `[i]` 行为准核对**）：

```
NCCL_RING_EDGE_DEVS="pair=1,3;cross=0,2"   # pair 边(0-1,2-3)走 f1 位(1,3)；cross 边(1-2,3-0)走 f0 位(0,2)
```

### 旁路条件（未启用时与官方 NCCL 行为完全一致）

| 条件 | 行为 |
| --- | --- |
| 变量未设置 / 为空 | 完全旁路 |
| `nRanks != 4` | 旁路，rank0 打一条 INFO 说明（择一选择的方案：旁路而非报错，避免全局 export 误伤其它作业） |
| 格式错误（缺 key/未知 key/重复 key/空段/尾分号/负数/越界索引/非数字…） | `WARN` + `ncclInvalidUsage`，`ncclCommInitRank` 失败退出，绝不静默 |

## Hook 点与理由

| 需求 | 文件:函数 | 改动 | 依据（官方源码事实） |
| --- | --- | --- | --- |
| SR-3 | `src/graph/ringpeer.cc`（新文件）+ `src/init.cc` `ncclCommInitRankDev`（拓扑构建后调用 `ncclRingPeerInit`） | 解析/校验/日志 | — |
| SR-1 树 | `init.cc`（tree graph **照常搜索**，搜索后当模式激活时置 `bwIntra=bwInter=0`）+ `graph/connect.cc` `ncclTopoPostset`（跳过 `connectTrees`） | 树通道保持 -1（Preset 默认值），树带宽 0 → `ncclTopoGetAlgoTime` 返回 -1 → enqueue 选型忽略，tuner 永不选树 | `connectTrees` 用 `ncclGetDtree` 在节点序上建 doubling tree，4 节点必有 0-2 跨节点边（connect.cc:121）。**不可跳过搜索本身**：见下方「v2 修复」 |
| SR-1 collnet | `init.cc`：`collnetEnable=0` | collnet 图不搜索、通道不建 | collnetDirect heads 跨节点全互联（connect.cc `connectCollNet`），必含非邻对 |
| SR-1 PAT | `init.cc:1571` 跳过 `ncclTransportPatConnect`��`graph/tuning.cc` `ncclPatEnable` 返回 0 | PAT 不建连、不入选 | PAT binomial 树 `mask=2` 时连接 `rank<->rank+2`（transport/generic.cc:78-84），且 4×1GPU/node 时**默认开启** |
| SR-1 兜底 | `transport/net.cc` `sendSetup`/`recvSetup`：`ncclRingPeerCheckPeer` | 跨节点非邻 NET 连接（如运行期懒连接的 p2p）显式 `WARN`+失败 | E1 根因：非直连对上 QP `ibv_modify_qp` 超时 errno 110 |
| SR-2/SR-4 | `transport/net.cc` `sendSetup`/`recvSetup`：`ncclRingPeerNetDev` 覆盖 `(peer, channelId) → netDev/netId/proxyRank` | 设备选择强制走边映射，`c % n` 交错 | 见下 |

### 为什么 hook 在 sendSetup/recvSetup 而不是 ncclTopoGetNetDev 内部

- `recvSetup` 调 `ncclTopoGetNetDev` 时**故意传自身 rank**（"receiver uses its own netdev"，net.cc:360-364）；per-edge 映射必须以真实对端为键，所以只能在拿到 `peerInfo->rank` 的调用点覆盖。
- 在官方选择逻辑之后覆盖（而非改内部），保证变量未设置时零行为差异，且不影响 `ncclTopoGetNetDev` 的其它调用方（PXN、GDR 探测、collnet 等）。
- 覆盖发生在 `ncclTopoCheckGdr`/`ncclTopoNeedFlush`/proxy 建连之前，GDR/flush/PXN 判定自动跟随新设备，日志 `Channel xx : a -> b via NET/IB/n` 的 n 即为覆盖后设备，便于验收比对 IB 计数器。
- 环序天然物理正确：`connectRings` 按节点序 0→1→2→3→0 连接（connect.cc:81-96），无需干预。

## 设计取舍

1. **跨节点算法收缩为 ring-only**：树/collnet/PAT 在此物理拓扑上不可能工作（都需要非邻直连），禁用是 SR-1 的必然推论。代价是小消息延迟类算法不可用——物理上本就不可用。AllReduce/ReduceScatter/AllGather/Broadcast/Reduce 全部走 ring。
2. **设备索引取枚举序而非复刻 HCA 解析**：避免重复实现 `NCCL_IB_HCA` 的 `^`/`=`/`:port`/通配/rail 语法；文档约定按枚举序书写 HCA 列表（目标硬件的自然写法即满足）。
3. **每类边允许 1~4 设备（`c%n` 交错）**：规格要求的两设备 n=2 是标准用法；n=1 是用户自担的降级。
4. **进程级静态映射状态**：env 为进程全局，解析一次；边型格式与 rank 无关，同进程多个 4-rank 环 communicator 也可共用同一映射（优于初版 per-rank 格式，后者每 communicator 需各配各的）。
5. **非邻懒连接直接报错**：运行期向非邻 rank 发起 NET 连接（如 alltoall、指向非邻的 ncclSend）会得到明确的 WARN+错误，而非 QP 超时挂死。

## 构建与自检

```bash
cd ~/ring-nccl-src
make -j src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121"
# 产物 build/lib/libnccl.so.2.30.7
```

- 编译通过为硬性要求（已验证）。
- env 解析器的最小自检：`ringparse_selftest.cc`（仓库根目录，`.git/info/exclude` 已排除，不属于补丁交付物）——用 sed 从 `ringpeer.cc` **逐字节抽取**解析函数/边型判定/邻接判定后编译运行，38 个用例（正例含 key 顺序/单设备/满 4 设备；缺 key/未知 key/重复 key/空段/尾分号/负数/越界/非数字/旧 per-rank 值拒绝；8 组 (rank,peer) 边型判定全枚举；`c%n` 交错序列），全部通过（构建与运行方法见该文件头部注释）。
- 4 机功能/性能验收（E1 消除 = init 不再出现非邻 QP；E2 消除 = 四设备 IB 计数器均非零且按 c 奇偶分流）由团队执行。

## v2 修复：4 机真机 init 崩溃（2026-09-18）

**现象**：torch `ncclCommInitRank`（首个集合通信触发懒初始化）报 `internal error`，torch 侧 `Last error: Error : ring 0 does not contain rank 1`（ncclInternalError，源出 `graph/rings.cc:64 ncclBuildRings`）。`NCCL_DEBUG=WARN` 无输出的原因：WARN 走 debug 输出通道，被 DEBUG_FILE/缓冲吞掉；`NCCL_DEBUG=INFO` + `NCCL_DEBUG_SUBSYS`（注意默认子系集只有 INIT|BOOTSTRAP|ENV，GRAPH 必须显式加，且子系名写错整串失效）复现后完整定位。

**根因**（v1 设计缺陷，与部署无关）：v1 跳过了 tree graph 搜索，`treeGraph->nChannels` 保持 0。而 `init.cc` allgather 校准处的原生命码
`comm->nChannels = treeGraph->nChannels = ringGraph->nChannels = std::min(treeGraph->nChannels, ringGraph->nChannels)`
把 `comm->nChannels` 连带塌缩为 0（该行在 `ncclTopoPreset` 之后、`ncclTopoPostset` 之前）。Postset 内所有按通道循环的环表填充（ringPrev/ringNext/topoRanks 交换）全部空转；随后 `NCCL_MIN_NCHANNELS` 下限逻辑又把通道数从全零环表「复活」为 4，`ncclBuildRings` 校验全零环即报上述错误。次要风险：跳过搜索使 `treeGraph->intra` 为 NULL，而 `ncclTopoPreset` 按源码会解引用它，属隐患路径。

**修法**（保持原生数据流完整）：tree graph 照常搜索（intra/nChannels 全量有效，Preset/校准/stock min() 全部自洽），仅在搜索后模式激活时置 `treeGraph->bwIntra = bwInter = 0`（bw==0 → algo time -1 → enqueue.cc 选型 `>= 0.0` 过滤永不选树）；`connectTrees` 继续跳过，树 peer 保持 -1。v1 对 `comm->nChannels` 的特判同步移除（回退 stock min）。PAT/collnet 的禁用与 net.cc 覆盖逻辑不变。

**最小 4 机验证（lmsysorg/sglang:dev-dsv41 容器，注入与生产一致）**：all_reduce 4MB `SUM=10.0 OK`、barrier OK、第二组 all_reduce `130560.0 OK`，四机 `NCCL WARN/ERROR` 0 条；通道-设备映射逐机核对全对——pair 边 (0→1)/(2→3) 通道 0/2 走 rocep1s0f1(IB/1)、通道 1/3 走 roceP2p1s0f1(IB/3)，cross 边 (1→2)/(3→0) 通道 0/2 走 rocep1s0f0(IB/0)、通道 1/3 走 roceP2p1s0f0(IB/2)，收发两端同边同设备（同位直连验证通过）；Trees 全 -1。库 md5 `04f3d609a77d5087249062d6ee582f12`（四机 /opt/ring-nccl 已同步，MD5-RECORD.txt 已更新）。

**调试方法备忘**：容器里抓 NCCL 日志必须 `-v /tmp:/wtmp -e NCCL_DEBUG_FILE=/wtmp/...`（否则日志随 --rm 容器消失）；`Channel xx/%d : a -> b via NET/IB/n` 行即 per-edge 设备选择的验收证据；`NET/IB : Using [i]<name>` 行确认设备枚举序（本环境 rocep1s0f0=0, rocep1s0f1=1, roceP2p1s0f0=2, roceP2p1s0f1=3，与 env 假设一致）。
