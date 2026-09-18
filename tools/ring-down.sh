#!/bin/bash
# 撤销环配置：flush 四个环口的地址并恢复默认 MTU（可反复跑；不影响管理网）。
# 用法: HOSTS="ip0 ip1 ip2 ip3" [SSH_USER=user] bash {name}   （在管理节点执行）
# 前提: 目标机 sudoers NOPASSWD；管理节点到四台 ssh 免密。
set -u
IFS=" " read -r -a IFACES <<< "${IFACES:-enP2p1s0f1np1 enP2p1s0f0np0 enp1s0f1np1 enp1s0f0np0}"
H=(${HOSTS:-spark0 spark1 spark2 spark3})
U=${SSH_USER:-$(id -un)}
R() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$1]} "$2" 2>&1; }
SUDO() {
  local i=$1; shift
  R "$i" "sudo -n $*; rc=\$?; exit \$rc"
}

echo "##### 撤销环地址"
for i in 0 1 2 3; do
  printf 'node%s: ' $i
  for ifc in "${IFACES[@]}"; do
    SUDO $i "ip addr flush dev $ifc" >/dev/null 2>&1
    SUDO $i "ip link set $ifc mtu 1500" >/dev/null 2>&1
  done
  echo "已清理 ${IFACES[*]}"
done
