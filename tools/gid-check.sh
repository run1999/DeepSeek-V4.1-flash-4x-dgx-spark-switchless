#!/bin/bash
# GID 槽位预检：校验各 HCA 的 GID slot（默认 3）非空、类型 RoCE v2、ndev 正确。
# 空槽会让 NCCL 选口全乱（QP 连接超时），起服务前必须全绿；空槽用 gid-fix.sh 修复。
# 用法: HOSTS="ip0 ip1 ip2 ip3" [SSH_USER=user] bash {name}   （在管理节点执行）
# 前提: 目标机 sudoers NOPASSWD；管理节点到四台 ssh 免密。
set -u
H=(${HOSTS:-spark0 spark1 spark2 spark3})
U=${SSH_USER:-$(id -un)}
GID_INDEX=${GID_INDEX:-3}
HCAS=${HCAS:-"rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1"}

for i in 0 1 2 3; do
  echo "===== node$i ====="
  ssh -o BatchMode=yes -o ConnectTimeout=8 $U@${H[$i]} GID_INDEX=$GID_INDEX HCAS="'$HCAS'" 'bash -s' <<'EOS'
for hca in $HCAS; do
  base=/sys/class/infiniband/$hca/ports/1
  [ -d "$base" ] || { echo "  $hca: 设备不存在"; continue; }
  gid=$(cat "$base/gids/$GID_INDEX" 2>/dev/null)
  type=$(cat "$base/gid_attrs/types/$GID_INDEX" 2>/dev/null)
  ndev=$(cat "$base/gid_attrs/ndevs/$GID_INDEX" 2>/dev/null)
  state=$(cat "$base/state" 2>/dev/null)
  verdict=OK
  [ -z "$gid" ] || [ "$gid" = "0000:0000:0000:0000:0000:0000:0000:0000" ] && verdict="空槽!"
  [ "$type" != "RoCE v2" ] && verdict="类型错($type)"
  printf "  %-14s state=%-12s slot%s=%s ndev=%-16s [%s]\n" "$hca" "$state" "$GID_INDEX" "${gid: -14}" "$ndev" "$verdict"
done
EOS
done
