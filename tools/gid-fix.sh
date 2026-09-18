#!/bin/bash
# GID 空槽修复：对指定口删地址→等→重加，让 RoCE v1/v2 GID 对重新占据 slot 2/3。
# 成因多为对同一网口反复 add/del 地址留下空槽；配合 gid-check.sh 使用。
# 用法: HOSTS="ip0 ip1 ip2 ip3" [SSH_USER=user] bash {name}   （在管理节点执行）
# 前提: 目标机 sudoers NOPASSWD；管理节点到四台 ssh 免密。
# 参数: IF=<网口> ADDR_<i>=<该节点此口上的地址>（默认修 node2/node3 的 PCIe2 口1）
set -u
H=(${HOSTS:-spark0 spark1 spark2 spark3})
U=${SSH_USER:-$(id -un)}
IF=${IF:-enP2p1s0f1np1}
declare -A IDX_ADDR=( [2]=${ADDR_2:-10.10.31.3} [3]=${ADDR_3:-10.10.31.4} )

for i in 2 3; do
  echo "===== node$i ($IF ${IDX_ADDR[$i]}) ====="
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$i]} "
    echo '--- 修复前 slot3/4 ---'
    grep -H . /sys/class/infiniband/roceP2p1s0f1/ports/1/gids/{3,4} 2>/dev/null | sed 's|.*/gids/|slot |'
    sudo -n ip addr del ${IDX_ADDR[$i]}/24 dev $IF 2>/dev/null
    sleep 3
    sudo -n ip addr add ${IDX_ADDR[$i]}/24 dev $IF
    sleep 4
    echo '--- 修复后 slot2-4 ---'
    for g in 2 3 4; do
      gid=\$(cat /sys/class/infiniband/roceP2p1s0f1/ports/1/gids/\$g 2>/dev/null)
      t=\$(cat /sys/class/infiniband/roceP2p1s0f1/ports/1/gid_attrs/types/\$g 2>/dev/null)
      printf '  slot %d: %-32s %s\n' \$g "\$gid" "\$t"
    done
  " 2>&1
done
