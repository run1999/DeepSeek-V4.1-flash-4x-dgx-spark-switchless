#!/usr/bin/env python3
"""向上游 start.sh 注入 EXTRA_DOCKER_ENV 通用透传（head 数组段 + worker 展开段）与
DSV41_SHARED_PAD_K env 注入。幂等：已注入则跳过。用法: python3 patch-start-sh.py <start.sh>"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "start.sh"
s = open(path).read()

HEAD_ANCHOR = """  if [[ -n "${EXTRA_SGLANG_ARGS:-}" ]]; then
    _a+=(-e "EXTRA_SGLANG_ARGS=$EXTRA_SGLANG_ARGS")
  fi
"""
HEAD_INJECT = HEAD_ANCHOR + """  if [[ -n "${EXTRA_DOCKER_ENV:-}" ]]; then
    local _kv
    for _kv in $EXTRA_DOCKER_ENV; do _a+=(-e "$_kv"); done
  fi
"""

WORKER_ANCHOR = """        -e EXTRA_SGLANG_ARGS=$(printf '%q' "${EXTRA_SGLANG_ARGS:-}") \\
"""
WORKER_INJECT = WORKER_ANCHOR + """$(for _kv in ${EXTRA_DOCKER_ENV:-}; do echo "        -e \\"$_kv\\" \\\\"; done)
"""

changed = False
if "EXTRA_DOCKER_ENV" not in s:
    assert s.count(HEAD_ANCHOR) == 1, "head anchor not found"
    s = s.replace(HEAD_ANCHOR, HEAD_INJECT)
    assert s.count(WORKER_ANCHOR) == 1, "worker anchor not found"
    s = s.replace(WORKER_ANCHOR, WORKER_INJECT)
    changed = True

# DSV41_SHARED_PAD_K: default + head -e + worker -e (idempotent)
if "DSV41_SHARED_PAD_K" not in s:
    a1 = 'DSV41_CACHE_WAYS="${DSV41_CACHE_WAYS:-4}"\n'
    assert s.count(a1) == 1, "ways anchor"
    s = s.replace(a1, a1 + 'DSV41_SHARED_PAD_K="${DSV41_SHARED_PAD_K:-0}"\n')
    a2 = '    -e "DSV41_CACHE_GIB=$DSV41_CACHE_GIB"\n'
    assert s.count(a2) == 1, "head cache env anchor"
    s = s.replace(a2, a2 + '    -e "DSV41_SHARED_PAD_K=$DSV41_SHARED_PAD_K"\n')
    a3 = "        -e DSV41_CACHE_WAYS=$DSV41_CACHE_WAYS \\\\\n"
    assert s.count(a3) == 1, "worker cache env anchor"
    s = s.replace(a3, a3 + "        -e DSV41_SHARED_PAD_K=$DSV41_SHARED_PAD_K \\\\\n")
    changed = True

open(path, "w").write(s)
print("patched" if changed else "already patched (no-op)")
