#!/bin/bash
# 环配置（第二 rail，增量）：启用 PCIe2 双口，与 PCIe1 同构冗余（pair 位口1 / cross 位口0）。
# 每条环边由此获得两条物理直连（双 rail），配合 ring-nccl 的 NCCL_RING_EDGE_DEVS 使用。
# 不触碰 PCIe1 与既有地址，服务可在线执行；先用 probe-4ports.sh 确认 PCIe2 接线与 PCIe1 同构。
# 用法: HOSTS="ip0 ip1 ip2 ip3" [SSH_USER=user] bash {name}   （在管理节点执行）
# 前提: 目标机 sudoers NOPASSWD；管理节点到四台 ssh 免密。
set -u
PAIR2_IF=enP2p1s0f1np1
CROSS2_IF=enP2p1s0f0np0
# 子网编号 .1/.2/.3/.4 = node0..node3
PAIR2_IP=(10.10.11.1 10.10.11.2 10.10.31.3 10.10.31.4)
CROSS2_IP=(10.10.41.1 10.10.21.2 10.10.21.3 10.10.41.4)
H=(${HOSTS:-spark0 spark1 spark2 spark3})
U=${SSH_USER:-$(id -un)}
R() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$1]} "$2" 2>&1; }
SUDO() {
  local i=$1; shift
  R "$i" "sudo -n $*; rc=\$?; exit \$rc"
}

echo "##### 1) 配 PCIe2 双口（增量，MTU 9000）"
for i in 0 1 2 3; do
  printf 'node%s: ' $i
  SUDO $i "ip link set $PAIR2_IF mtu 9000 up" >/dev/null 2>&1
  SUDO $i "ip link set $CROSS2_IF mtu 9000 up" >/dev/null 2>&1
  SUDO $i "ip addr add ${PAIR2_IP[$i]}/24 dev $PAIR2_IF" 2>/dev/null
  SUDO $i "ip addr add ${CROSS2_IP[$i]}/24 dev $CROSS2_IF" 2>/dev/null
  R $i "ip -4 -br addr | grep -oE '10\.10\.[0-9]+\.[0-9]+' | tr '\n' ' '"
  echo
done

echo; echo "##### 2) GID slot3 校验（四块 HCA；空槽=需 gid-fix.sh）"
for i in 0 1 2 3; do
  printf 'node%s: ' $i
  R $i 'for hca in rocep1s0f0 rocep1s0f1 roceP2p1s0f0 roceP2p1s0f1; do
          g=$(cat /sys/class/infiniband/$hca/ports/1/gids/3 2>/dev/null)
          t=$(cat /sys/class/infiniband/$hca/ports/1/gid_attrs/types/3 2>/dev/null)
          printf "%s=%s(%s) " "$hca" "${g: -11}" "$t"
        done; echo'
done

echo; echo "##### 3) 第二 rail 邻接验证（jumbo 8972）"
for i in 0 1 2 3; do
  a=$(( (i+1)%4 )); b=$(( (i+3)%4 ))
  if [ $((i%2)) -eq 0 ]; then ta=${PAIR2_IP[$a]}; tb=${CROSS2_IP[$b]}; else ta=${CROSS2_IP[$a]}; tb=${PAIR2_IP[$b]}; fi
  printf 'node%s -> node%s / node%s: ' $i $a $b
  R $i "ping -c2 -W2 -M do -s 8972 $ta >/dev/null 2>&1 && echo -n 'A_OK ' || echo -n 'A_FAIL '
        ping -c2 -W2 -M do -s 8972 $tb >/dev/null 2>&1 && echo 'B_OK' || echo 'B_FAIL'"
done
echo; echo "回退: HOSTS=... bash -c 'for i in 0 1 2 3; do ssh ${HOSTS%% *} true; done' # 见 ring-down.sh"
