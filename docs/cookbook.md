# Cookbook: reproduce the end-to-end stack from bare metal (English)

Target: bring four factory DGX Spark nodes to this project's final state —
DeepSeek-V4.1-Flash TP4 on a switchless RoCE ring, cold prefill 16K/64K ≈
2486/2495 tok/s, decode C1/C8 ≈ 52.9/169.8 tok/s.

Full-detail Chinese edition (identical structure): [cookbook.zh-CN.md](cookbook.zh-CN.md).
Troubleshooting: [troubleshooting.md](troubleshooting.md).

Convention for every step:

```bash
export HOSTS="node0_ip node1_ip node2_ip node3_ip"   # ring order = rank0..rank3
export SSH_USER=<user>
```

## 0. Prerequisites

4× DGX Spark (GB10, 4 CX7 ports each); 8 DAC cables; DGX OS; passwordless ssh
between all four nodes plus a management node; NOPASSWD sudo on targets;
weights `deepseek-ai/DeepSeek-V4.1-Flash` (~475 GiB per node, local NVMe).
CN networks: prefix GitHub URLs with `https://ghfast.top/`.

## 1. Cabling

Ring node0-node1-node2-node3-node0. Each edge has TWO physical links — one on
the PCIe1 card, one on the PCIe2 card, matched by port position:

- port0 (`enp1s0f0np0` / `enP2p1s0f0np0`) = **cross** position: edges (0,3),(1,2)
- port1 (`enp1s0f1np1` / `enP2p1s0f1np1`) = **pair** position: edges (0,1),(2,3)

Verify by measurement, never by diagram: `bash tools/probe-4ports.sh` — each
port must show OK only to its two same-position neighbors.

## 2. Configure the dual-rail ring

```bash
bash tools/ring-up2.sh   # rail 1 (PCIe1 ports): addresses + MTU 9000 + GID check + jumbo test
bash tools/ring-up4.sh   # rail 2 (PCIe2 ports), incremental
```

Both must end fully green (empty GID slots → `tools/gid-fix.sh`).

## 3. Build & deploy ring-nccl

On node0:

```bash
git clone --depth 1 -b v2.30.7-1 https://ghfast.top/https://github.com/NVIDIA/nccl.git nccl-2307
cd nccl-2307 && git apply <repo>/ring-nccl/ring-nccl.patch
make -j src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121"
for h in $HOSTS; do ssh $SSH_USER@$h "sudo mkdir -p /opt/ring-nccl && sudo chown $SSH_USER /opt/ring-nccl" && \
  rsync -a build/lib/libnccl.so.2.30.7 $SSH_USER@$h:/opt/ring-nccl/ && \
  ssh $SSH_USER@$h "ln -sf libnccl.so.2.30.7 /opt/ring-nccl/libnccl.so.2"; done
```

## 4. NCCL acceptance

```bash
NCCL_DIR=/opt/ring-nccl bash tools/nccl-go.sh   # expect: all_reduce SUM=10.0 OK, all_gather OK
```

Dual-rail proof: IB counters (`port_xmit_data`) must show nonzero delta on all
four HCAs across a prefill (command snippet in troubleshooting.md §2).

## 5. Engine stack (community recipe base)

Base: [MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks)
(or its downstream [knapcio fork](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4),
which already bundles the adapter set). Clone the base, then apply this repo's deltas:

1. `deploy/Dockerfile.canary` → repo root (sglang `dsv4.1` branch pinned
   `f80c91a4b`, kernel packages, cargo stub — do not remove the stub).
2. Stage the branch tree:
   `mkdir -p runtime/sglang-canary && cd $_ && curl -fsSL -m 600
   "https://ghfast.top/https://github.com/sgl-project/sglang/archive/f80c91a4b.tar.gz" | tar xz --strip-components=1 --wildcards "sglang-*/python"`
   then `echo f80c91a4b > REF`.
3. `python3 <repo>/deploy/patch-start-sh.py start.sh` (idempotent: injects
   EXTRA_DOCKER_ENV passthrough + DSV41_SHARED_PAD_K).
4. Copy the knapcio adapter files (`shared_pad_k.py`, `indexer_chunked*.py`,
   `spark_prefill_dense.py`, `fast_load.py`, updated `sitecustomize.py`, …)
   into `adapter/` if the base does not carry them.

## 6. .env.tp4

Start from `deploy/env.tp4.template`; fill host placeholders, then lock these
tuned values (each single-variable A/B validated; see benchmarks.md):

`NCCL_HOST_DIR=/opt/ring-nccl` ·
`IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1` (order defines EDGE_DEVS indices) ·
`EP_SIZE=2` · `DSV41_CACHE_GIB=4` / `DSV41_CACHE_WAYS=16` · `DSV41_SHARED_PAD_K=1` ·
`CHUNKED_PREFILL_SIZE=4096` · `MAX_RUNNING_REQUESTS=16` · `DSPARK_BLOCK_SIZE=3` ·
`MEM_FRACTION_STATIC=0.80` ·
`EXTRA_DOCKER_ENV="SPARK_PREFILL_TP_SPLIT=1 SPARK_PREFILL_TP_MIN_CONTEXT=32768 SPARK_PREFILL_TP_MIN_ROWS=1024 DSV41_INDEXER_CHUNKED=1 SGLANG_DSPARK_FOLDED_SAMPLING=2 SGLANG_RUST_BUILD_MODE=never NCCL_RING_EDGE_DEVS=pair=1,3;cross=0,2"`

Lock GPU clocks (GB10 has an nvidia-smy-invisible fast/slow state; unbalanced
clocks drag every collective):

```bash
for h in $HOSTS; do ssh $SSH_USER@$h "sudo nvidia-smi -lgc 0,2400"; done
```

## 7. Weights & Engram

Per node: `modelscope download --model deepseek-ai/DeepSeek-V4.1-Flash
--local_dir ~/NewModels/DeepSeek-V4.1-Flash` (~2.5 h/node; CLI verifies SHA).
Then `./start-tp4.sh pack` (Engram shards, ~10 min).

## 8. Serve & accept

```bash
./start-tp4.sh build && ./start-tp4.sh serve   # workers first; ~8-13 min load
```

Accept (the launcher may exit 0 on failure — trust only these): all four
nodes log `world_size=4`; `/health` = 200; arithmetic smoke ("19 + 23" → 42).

## 9. Benchmarks

Deploy [sparkDash](https://github.com/MiaAI-Lab/sparkDash), point the target
spark's llm port at 8888, then `SPARKDASH_HOST=<ip> SPARK=<id> PORT=8888
bash scripts/bench.sh`. Expected medians (cold, sparkDash corpus — absolute
values run 9-20% hot vs real text): prefill 16K/64K ≈ 2486/2495, C1 ≈ 52.9,
C8 ≈ 169.8.

## Appendix: known dead ends

chunk 8192 (-35%) · prefill breakable CUDA graph (replay crash) ·
two-batch-overlap (rejected by model) · single-batch-overlap (negative) ·
one-shot RDMA all-reduce on a ring (needs full mesh) · blindly copying
foreign NCCL env blocks (-10%) · MAX_NCHANNELS=8 to "spread" rails (does
nothing; spreading comes from EDGE_DEVS) · trusting stop scripts to remove
worker containers (they silently leak — `docker rm -f` by hand).
