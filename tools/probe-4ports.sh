#!/bin/bash
# 四口邻接探测：四台机器 × 每台 4 个光口的完整邻接矩阵。
# 每口临时配独立 /24 地址互 ping，测完撤销，不触碰已有地址。
# 用法: HOSTS="ip0 ip1 ip2 ip3" [SSH_USER=user] bash {name}   （在管理节点执行）
# 前提: 目标机 sudoers NOPASSWD；管理节点到四台 ssh 免密。
set -u
H=(${HOSTS:-spark0 spark1 spark2 spark3})
U=${SSH_USER:-$(id -un)}

cat > /tmp/ifq.sh <<'EOS'
#!/bin/bash
# env: IDX=0..3  ACTION=add|del|ping
DEVS="enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1"
case "$ACTION" in
  add|del)
    n=13
    for d in $DEVS; do
      sudo -n ip addr "$ACTION" 10.99.$n.$((IDX+1))/24 dev $d 2>/dev/null
      n=$((n+1))
    done ;;
  ping)
    for d in $DEVS; do
      case $d in
        enp1s0f0np0)   n=13 ;;
        enp1s0f1np1)   n=14 ;;
        enP2p1s0f0np0) n=15 ;;
        enP2p1s0f1np1) n=16 ;;
      esac
      printf '%s' "$d="
      for j in 1 2 3 4; do
        [ "$j" = "$((IDX+1))" ] && { printf '%s ' "--"; continue; }
        ping -c1 -W1 10.99.$n.$j >/dev/null 2>&1 && printf '%s ' "OK" || printf '%s ' "."
      done
      printf '; '
    done ;;
esac
true
EOS

for i in 0 1 2 3; do
  scp -q -o BatchMode=yes -o ConnectTimeout=8 /tmp/ifq.sh $U@${H[$i]}:/tmp/ </dev/null 2>/dev/null
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$i]} "IDX=$i ACTION=add bash /tmp/ifq.sh" >/dev/null 2>&1
done

echo "邻接矩阵（每台每个口 -> 到 node0..node3；OK=有线直达）"
echo "口名: enp1s0f0np0=PCIe1口0  enp1s0f1np1=PCIe1口1  enP2p1s0f0np0=PCIe2口0  enP2p1s0f1np1=PCIe2口1"
echo
for i in 0 1 2 3; do
  echo "----- node$i -----"
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$i]} "IDX=$i ACTION=ping bash /tmp/ifq.sh" 2>&1
done
for i in 0 1 2 3; do
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 $U@${H[$i]} "IDX=$i ACTION=del bash /tmp/ifq.sh" >/dev/null 2>&1
done
echo; echo "(临时地址已撤销)"
