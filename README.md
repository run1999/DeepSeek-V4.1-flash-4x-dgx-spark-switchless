# DeepSeek-V4.1-Flash · 4× DGX Spark · Switchless Ring

A cookbook-first repository for serving **DeepSeek-V4.1-Flash** (552B MoE,
1M context) with SGLang TP4 across **four NVIDIA DGX Spark (GB10) nodes cabled
as a switchless RoCE ring** — plus **ring-nccl**, our behavioral patch for
NVIDIA NCCL that makes such rings fast:

- disables the tree/collnet/PAT channels that require diagonal links a ring
  cannot provide (the measured root cause of init failures, incl. the PAT
  binomial rank+2 connection),
- steers each ring edge onto **both of its physical links** (dual rail) with
  channel interleaving — doubling usable fabric bandwidth (verified via IB
  counters; channel alternation on rings is still an open question in
  [SparkRing#273](https://github.com/FujitsuPolycom/sparkring/issues/273)),
- describes the topology via an env var — no compile-time tables, any ring
  rewiring is a config change:

```bash
NCCL_RING_EDGE_DEVS="pair=1,3;cross=0,2"   # edge class → device pair (NCCL_IB_HCA indices)
```

**Start here to reproduce the full stack:**
[`docs/cookbook.md`](docs/cookbook.md) (EN) ·
[`docs/cookbook.zh-CN.md`](docs/cookbook.zh-CN.md) (中文，最详)
· 中文版 README：[`README.zh-CN.md`](README.zh-CN.md)

## Results

Cold prefill (sparkDash independent-prompt corpus, median of 3), stock
FP8/MXFP4 weights, 1M context:

| Metric | Baseline | Final | Gain |
| --- | --- | --- | --- |
| Cold prefill 16K / 64K tok/s | ~1400 / ~1430 | **2486 / 2495** | **+77% / +74%** |
| Decode C1 tok/s | 35.4 | 52.9 | +49% |
| Decode C8 aggregate tok/s | ~80 | **169.8** | **+113%** |

Correctness: arithmetic smoke, 64K needle retrieval all pass. Method, corpus
caveats and side-by-side references (switched-fabric upstream, SparkRing
starting point) in [`docs/benchmarks.md`](docs/benchmarks.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `docs/cookbook*.md` | Step-by-step reproduction from bare metal (this is the main deliverable) |
| `ring-nccl/` | The NCCL patch (`ring-nccl.patch`) + implementation notes (hooks, build, env) |
| `docs/design/nccl-ring-spec.md` | Behavior specification the patch implements (testable requirements) |
| `deploy/` | Engine-side deltas: `Dockerfile.canary`, sanitized `env.tp4.template`, idempotent `patch-start-sh.py` |
| `tools/` | Fabric ops: 4-port adjacency probe, dual-rail ring up/down, GID check & fix, 4-node NCCL acceptance |
| `scripts/bench.sh` | One-shot benchmark wrapper (sparkDash API) |
| `tests/` | Parser self-test for `NCCL_RING_EDGE_DEVS` (38 cases, runs in CI against the exact shipped logic) |
| `docs/benchmarks.md` | Method + results + tuned-knobs table |
| `docs/troubleshooting.md` | Symptom-indexed diagnostics (QP timeout / zero rail traffic / low perf) |

## Quick start

```bash
export HOSTS="ip0 ip1 ip2 ip3" SSH_USER=$USER
bash tools/probe-4ports.sh          # verify cabling by measurement
bash tools/ring-up2.sh && bash tools/ring-up4.sh
# build ring-nccl (see ring-nccl/IMPLEMENTATION.md) → /opt/ring-nccl on all nodes
NCCL_DIR=/opt/ring-nccl bash tools/nccl-go.sh   # expect: all_reduce SUM=10.0 OK
```

Then follow cookbook §5-§9 for the engine stack, weights, serving and
benchmarks.

## Status & next steps

Working production profile; remaining performance headroom (protocol-size
tuning, proxy-thread pinning, channel weighting) tracked in the cookbook
appendix. Negative results (chunk 8192, prefill CUDA graph, TBO, one-shot
RDMA on rings, …) are documented so you don't re-walk them.

## Credits

- [FujitsuPolycom/sparkring](https://github.com/FujitsuPolycom/sparkring) — the serving stack this project started from
- [MiaAI-Lab](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-DGX-Sparks) &
  [knapcio](https://github.com/knapcio/DeepSeek-V4.1-Flash-4x-DGX-Spark-TP4) — base recipes, adapters, benchmark tooling
- NVIDIA — NCCL under BSD-3, the patch base

## License

MIT (see `LICENSE`); third-party attributions in `NOTICE`.
