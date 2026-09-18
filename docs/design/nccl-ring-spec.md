# 环拓扑 NCCL 行为规格（ring-nccl v1）


## 1. 硬件与拓扑事实（本队 2026-09-18 probe 实测）

- 4× DGX Spark（GB10, SM121），每台 4 个 RoCE v2 网络设备（RDMA HCA）：
  - `rocep1s0f0`、`rocep1s0f1`（PCIe 器件 1 的两口）
  - `roceP2p1s0f0`、`roceP2p1s0f1`（PCIe 器件 2 的两口）
- 物理接线为**无交换机环**，rank 编号 0-3 对应四台主机，直连关系（邻接矩阵，实测）：
  - rank 对 (0,1)、(2,3)：rank0 侧用 f1 位设备（rocep1s0f1 + roceP2p1s0f1），对端同位
  - rank 对 (1,2)、(3,0)：两侧用 f0 位设备（rocep1s0f0 + roceP2p1s0f0）
  - **非相邻 rank 对（0,2）、(1,3) 无任何直连路径**
- 每条环边有**两条物理直连**（f1 位设备对一条 + f2 位设备对一条，各 200G）——"双 rail"

## 2. 观测到的标准 NCCL 缺陷（本队实验证据）

**E1（初始化失败）**：2026-09-17 判别实验：官方 NCCL 2.30.7（torch 自带）在上述拓扑做 4-rank TP 初始化时，ring 通道正常建立后，仍会尝试向**非直连**的对端地址发起 RDMA QP（日志：`ibv_modify_qp failed with 110 Connection timed out`，例：本端 10.10.10.1 → 对端 10.10.30.4，二者非直连子网），该连接永不成，导致 `ncclCommInitRank` 整体失败。根因判断：NCCL 的树/其他算法通道要求对角 rank 对直连，环拓扑不满足。

**E2（带宽浪费一半）**：2026-09-18 IB 计数器实测：`NCCL_IB_HCA` 列出全部 4 设备时，标准 NCCL 仅在前两个设备上产生流量（后两设备 `port_xmit_data` 增量精确为 0）——即每条边的第二条物理直连完全闲置，环带宽浪费 50%。

## 3. 行为规格

实现者须在 NVIDIA NCCL v2.30.7-1 官方源码上，以最小侵入补丁实现以下行为（hook 点自行寻找）：

**SR-1 环邻连接约束**：当启用本补丁时，跨节点传输连接的建立必须限制在环相邻 rank 对（(i,(i+1)%4) 与 (i,(i+3)%4)）之内；对非相邻 rank 对不得发起任何网络层连接建立。效果：环拓扑下初始化必须成功（消除 E1）。

**SR-2 按边定向的双设备选择**：启用时，每对相邻 rank 的传输连接使用**两个网络设备**（该边两端的同位设备对：f1 位边用 {rocep1s0f1, roceP2p1s0f1}，f0 位边用 {rocep1s0f0, roceP2p1s0f0}；设备以 `NCCL_IB_HCA` 列表顺序的索引表达）。同一 rank 对的多个通道在两个设备间交错分配，保证两设备均有流量（消除 E2）。

**SR-3 配置驱动（不得硬编码）**：边→设备映射必须由环境变量在运行时描述（不得编译期写死 rank 表）。最低要求支持以下语义（具体变量名实现者可自定，但须在补丁头部文档写清）：
```
# 示例语义：myRank 对每个 peerRank 的两个设备索引（NCCL_IB_HCA 顺序 0..3）
RING_PEER_DEVS="1=1,3;3=0,2"   # rank0 到 rank1 用 dev1+dev3；到 rank3 用 dev0+dev2
```
未设置该 env 时补丁完全旁路（行为=官方 NCCL）。拓扑非 4-rank 环时补丁应自动旁路或明确报错（实现者择一，文档写明）。

**SR-4 通道交错规则**：通道 c（0 起）在其 rank 对的设备对间按 `c % 2` 交错（文档写明；如实现者发现更优分配可扩展，但交错是最低要求）。

## 4. 验收（本队执行，实现者交付后）

- T1：4-rank all_reduce/all_gather 数值正确（现成工具）
- T2：IB 计数器实测四设备均有流量增量
- T3：同栈对比（sglang 栈配置不变，仅换通信库）：冷 prefill 16K/64K 相对单 rail 基线提升 ≥ +40%；decode 任何回退 >2% 拒收
- T4：64K needle 召回 PASS

## 5. 环境与构建（本队已验证）

- 源码：node0 `~/ring-nccl-src`（官方 v2.30.7-1 干净 clone，tag 提交 73cf112）
- 构建（node0 宿主，已验证可行）：`make -j src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121"`，产物 `build/lib/libnccl.so.2.30.7`
- 运行环境：容器 glibc 2.39（宿主一致）；部署路径约定 `/opt/ring-nccl/libnccl.so.2`（软链到 2.30.7）
- 容器注入方式：`-v /opt/ring-nccl:/nccl:ro -e LD_PRELOAD=/nccl/libnccl.so.2`

## 6. 非目标（第二步另立）

协议分带调优、proxy 线程绑核、通道数调优、任何性能超越项——本规格只求行为正确 + 性能达标（见 T3）。

## 7. 交付物

1. 补丁文件（对官方源码的 git diff，单一文件 `ring-nccl.patch`）
2. 实现说明（hook 点选择理由 + env 用法 + 旁路条件）
3. 补丁头部含实现说明
