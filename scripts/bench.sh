#!/bin/bash
# sparkDash bench 封装：冷 prefill（16K/64K）+ decode（C1/C8），一次跑全并输出结果。
# 前提: sparkDash 已部署（默认 http://$SPARKDASH_HOST:5555），目标 spark 已注册，端口指向推理栈。
# 用法: SPARKDASH_HOST=ip SPARK=<id> PORT=8888 bash bench.sh
set -u
SD=${SPARKDASH_HOST:?need SPARKDASH_HOST}; SPARK=${SPARK:-spark0}; PORT=${PORT:-8888}

poll() { # $1=job type (prefill-bench|bench)  $2=benchId
  while :; do
    S=$(curl -s "http://$SD:5555/api/sparks/$SPARK/llm/$1/$2")
    echo "$S" | grep -q '"status":"completed"' && { echo "$S"; return; }
    echo "$S" | grep -q '"error":"' && { echo "BENCH-ERROR: $S" >&2; exit 1; }
    sleep "${POLL:-10}"
  done
}

echo "== cold prefill 16K / 64K (independent prompts) =="
ID=$(curl -s -X POST "http://$SD:5555/api/sparks/$SPARK/llm/prefill-bench" -H 'Content-Type: application/json' \
  -d "{\"port\":$PORT,\"contextSizes\":[16384,65536]}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["benchId"])')
poll prefill-bench "$ID" > /tmp/_pf.json
python3 - <<'PY'
import json
for r in json.load(open("/tmp/_pf.json")).get("results", []):
    print("  prefill %dK: %d tok/s" % (r["targetTokens"]//1024, round(r["prefillTps"])))
PY

echo "== decode C1 / C8 (prose, 256 tokens) =="
ID=$(curl -s -X POST "http://$SD:5555/api/sparks/$SPARK/llm/bench" -H 'Content-Type: application/json' \
  -d "{\"port\":$PORT,\"concurrencies\":[1,8],\"maxTokens\":256,\"promptType\":\"prose\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["benchId"])')
poll bench "$ID" > /tmp/_de.json
python3 - <<'PY'
import json
for r in json.load(open("/tmp/_de.json")).get("results", []):
    print("  C%d: mean %.1f / aggregate %.1f tok/s" % (r["concurrency"], r["meanDecodeTps"], r["aggregateDecodeTps"]))
PY
