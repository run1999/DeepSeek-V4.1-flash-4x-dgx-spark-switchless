#!/bin/bash
# 环配置（第一 rail）：pair 边用 PCIe1口1(enp1s0f1np1)、cross 边用 PCIe1口0(enp1s0f0np0)。
# 环序 node0-node1-node2-node3-node0；pair 边=(0,1),(2,3)，cross 边=(1,2),(3,0)。
# 会 flush 上述两口上的既有地址（若承载其他业务请先评估）；第二 rail 见 ring-up4.sh。
# 用法: HOSTS="ip0 ip1 ip2 ip3" [SSH_USER=user] bash {name}   （在管理节点执行）
# 前提: 目标机 sudoers NOPASSWD；管理节点到四台 ssh 免密。
set -u
PAIR_IF=enp1s0f1np1
CROSS_IF=enp1s0f0np0
PAIR_IP=(10.10.10.1 10.10.10.2 10.10.30.3 10.10.30.4)
CROSS_IP=(10.10.40.1 10.10.20.2 10.10.20.3 10.10.40.4)
H=(${HOSTS:-spark0 spark1 spark2 spark3})
U=${SSH_USER:-$(id -un)}
R() { ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$1]} "$2" 2>&1; }
SUDO() {
  local i=$1; shift
  R "$i" "sudo -n $*; rc=\$?; exit \$rc"
}

echo "##### 1) 配环地址（pair=PCIe1口1, cross=PCIe1口0, MTU 9000）"
for i in 0 1 2 3; do
  printf 'node%s: ' $i
  SUDO $i "ip link set $PAIR_IF mtu 9000 up" >/dev/null 2>&1
  SUDO $i "ip link set $CROSS_IF mtu 9000 up" >/dev/null 2>&1
  SUDO $i "ip addr flush dev $PAIR_IF" >/dev/null 2>&1
  SUDO $i "ip addr flush dev $CROSS_IF" >/dev/null 2>&1
  SUDO $i "ip addr add ${PAIR_IP[$i]}/24 dev $PAIR_IF"
  SUDO $i "ip addr add ${CROSS_IP[$i]}/24 dev $CROSS_IF"
  R $i "ip -4 -br addr | grep -oE '10\.10\.[0-9]+\.[0-9]+' | tr '\n' ' '"
  echo
done

echo; echo "##### 2) GID slot3 校验（在用 HCA）"
for i in 0 1 2 3; do
  printf 'node%s: ' $i
  R $i 'for hca in rocep1s0f0 rocep1s0f1; do
          g=$(cat /sys/class/infiniband/$hca/ports/1/gids/3 2>/dev/null)
          t=$(cat /sys/class/infiniband/$hca/ports/1/gid_attrs/types/3 2>/dev/null)
          printf "%s=%s(%s) " "$hca" "${g: -11}" "$t"
        done; echo'
done

echo; echo "##### 3) 邻接验证（jumbo 8972）"
for i in 0 1 2 3; do
  a=$(( (i+1)%4 )); b=$(( (i+3)%4 ))
  if [ $((i%2)) -eq 0 ]; then ta=${PAIR_IP[$a]}; tb=${CROSS_IP[$b]}; else ta=${CROSS_IP[$a]}; tb=${PAIR_IP[$b]}; fi
  printf 'node%s -> node%s / node%s: ' $i $a $b
  R $i "ping -c2 -W2 -M do -s 8972 $ta >/dev/null 2>&1 && echo -n 'A_OK ' || echo -n 'A_FAIL '
        ping -c2 -W2 -M do -s 8972 $tb >/dev/null 2>&1 && echo 'B_OK' || echo 'B_FAIL'"
done
