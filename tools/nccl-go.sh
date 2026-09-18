#!/bin/bash
# ring-nccl 四机数值验收：容器内 4-rank all_reduce/all_gather，期望 SUM 与理论值一致。
# 自包含：测试脚本由本文件生成并分发；容器镜像需与推理栈同源（含 torch + CX7 用户态）。
# 用法: HOSTS="ip0 ip1 ip2 ip3" [SSH_USER=user] bash {name}   （在管理节点执行）
# 前提: 目标机 sudoers NOPASSWD；管理节点到四台 ssh 免密。
# 参数: NCCL_DIR=<四机一致的补丁库目录，默认 /opt/ring-nccl>
#       EDGE_DEVS=<NCCL_RING_EDGE_DEVS 值，默认 pair=1,3;cross=0,2>
#       IMAGE=<容器镜像，默认 lmsysorg/sglang:dev-dsv41>
set -u
H=(${HOSTS:-spark0 spark1 spark2 spark3})
U=${SSH_USER:-$(id -un)}
NCCL_DIR=${NCCL_DIR:-/opt/ring-nccl}
EDGE_DEVS=${EDGE_DEVS:-pair=1,3;cross=0,2}
IMAGE=${IMAGE:-lmsysorg/sglang:dev-dsv41}
MGMT_IF=${MGMT_IF:-enP7s7}   # bootstrap/rendezvous 用管理网口

cat > /tmp/ringnccl_check.py <<'EOS'
import os, torch, torch.distributed as dist
dist.init_process_group("nccl")
r = dist.get_rank()
torch.cuda.set_device(r)
x = torch.full((1024*1024,), float(r+1), dtype=torch.float32, device="cuda")
for _ in range(5): dist.all_reduce(x)
torch.cuda.synchronize(); dist.barrier()
t0 = torch.cuda.Event(True); t1 = torch.cuda.Event(True)
t0.record()
for _ in range(20): dist.all_reduce(x)
t1.record(); torch.cuda.synchronize()
ms = t0.elapsed_time(t1) / 20
expect = sum(range(1, int(os.environ["WORLD_SIZE"])+1))
ok = torch.allclose(x, torch.full_like(x, float(expect)))
if r == 0:
    print(f"all_reduce SUM={x[0].item():.1f} expect={expect} -> {'OK' if ok else 'FAIL'}; {ms:.2f} ms/op (4MiB)")
g = torch.zeros(4, dtype=torch.float32, device="cuda"); g[r] = r + 1
dist.all_gather_into_tensor(g, g[:1].clone())
ok2 = torch.allclose(g, torch.tensor([1.,2.,3.,4.], device="cuda"))
if r == 0: print(f"all_gather -> {'OK' if ok2 else 'FAIL'}")
dist.barrier(); dist.destroy_process_group()
EOS

for i in 0 1 2 3; do
  scp -q -o BatchMode=yes -o ConnectTimeout=8 /tmp/ringnccl_check.py $U@${H[$i]}:/tmp/ </dev/null
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$i]} "
    docker rm -f ncclcheck >/dev/null 2>&1
    setsid bash -c 'nohup docker run --rm --name ncclcheck \
      --gpus all --network host --ipc host --privileged \
      --device /dev/infiniband:/dev/infiniband \
      -v $NCCL_DIR:/nccl:ro -v /tmp/ringnccl_check.py:/check.py:ro \
      -e LD_PRELOAD=/nccl/libnccl.so.2 \
      -e RANK=$i -e WORLD_SIZE=4 -e MASTER_ADDR=${H[0]} -e MASTER_PORT=29540 \
      -e NCCL_RING_EDGE_DEVS="$EDGE_DEVS" \
      -e NCCL_SOCKET_IFNAME=$MGMT_IF -e GLOO_SOCKET_IFNAME=$MGMT_IF \
      -e NCCL_NET=IB -e NCCL_IB_DISABLE=0 \
      -e NCCL_IB_HCA=rocep1s0f0,rocep1s0f1,roceP2p1s0f0,roceP2p1s0f1 \
      -e NCCL_IB_GID_INDEX=3 \
      -e NCCL_IB_SUBNET_PREFIX_LEN=24 -e NCCL_IB_SUBNET_AWARE_ROUTING=1 \
      -e NCCL_IB_MERGE_NICS=0 -e NCCL_ALGO=Ring \
      -e NCCL_MIN_NCHANNELS=4 -e NCCL_MAX_NCHANNELS=4 \
      -e NCCL_P2P_LEVEL=SYS -e NCCL_CUMEM_ENABLE=0 -e NCCL_IGNORE_CPU_AFFINITY=1 \
      -e NCCL_DEBUG=WARN -e PYTHONUNBUFFERED=1 \
      $IMAGE timeout 300 python3 /check.py > /tmp/ncclgo.out 2>&1 < /dev/null &'
    echo node$i 已启动" 2>&1
done

echo "--- 等待完成 ---"; sleep 90
echo; echo "===== 结果（期望 OK）====="
for i in 0 1 2 3; do
  printf 'node%s: ' $i
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$i]} \
    'grep -aE "OK|FAIL|ibv_modify_qp|Error" /tmp/ncclgo.out 2>/dev/null | head -3 | tr "\n" " "; echo' 2>&1
done
