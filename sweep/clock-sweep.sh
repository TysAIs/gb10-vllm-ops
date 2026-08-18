#!/usr/bin/env bash
# clock-sweep-ds4.sh v2 — empirical 2190/2200/2300 GPU cap sweep on DS4 TP2 lane.
# FIXES: bench runs FROM MAC (llama-benchy not on Spark); clock sampled UNDER LOAD.
# Reversible: restores 2190 on exit/trap.
set -uo pipefail

LB="${LB:-llama-benchy}"   # path to llama-benchy (install: uv pip install git+https://github.com/eugr/llama-benchy)
OUTDIR="${OUTDIR:-./results}"
mkdir -p "$OUTDIR"
DATE="$(date +%m%d-%H%M)"
HEAD_NODE="${HEAD_NODE:-node0}"      # [VERIFY] head node (rank 0) hostname/SSH alias
WORKER_NODE="${WORKER_NODE:-node1}"   # [VERIFY] worker node (rank 1) hostname/SSH alias
BASE_URL="${BASE_URL:-http://head-node:8888/v1}"   # [VERIFY] set to your head node's endpoint
MODEL="deepseek-v4-flash-0731"
TOK="RadixArk/Qwen3.8-27B-NVFP4"   # unused for DS4; placeholder

set_cap() {
  local L="$1"
  ssh -o ConnectTimeout=8 "$HEAD_NODE" "sudo nvidia-smi -lgc 0,$L" >/dev/null 2>&1
  ssh -o ConnectTimeout=8 "$WORKER_NODE" "sudo nvidia-smi -lgc 0,$L" >/dev/null 2>&1
  echo "  cap requested: $L MHz (head+worker)"
}
restore() { set_cap 2190; echo "restored 2190"; }
trap restore EXIT

# sample peak GR clock on head under load, for N seconds (background collector)
sample_clock() {
  local secs="$1" out="$2"
  ssh -o ConnectTimeout=8 "$HEAD_NODE" "for i in \$(seq 1 $secs); do nvidia-smi --query-gpu=clocks.gr --format=csv,noheader; sleep 1; done" > "$out" 2>/dev/null &
}

for L in 2190 2200 2300; do
  echo "===== CLOCK LEVEL $L MHz ====="
  set_cap "$L"
  # per-level bench file
  local_log="$OUTDIR/clock-sweep-ds4-$DATE-L$L.md"
  # start clock collector (30s window)
  sample_clock 35 "$OUTDIR/.clk-$L.tmp"
  # run bench FROM MAC (C1 + C6, depth 0 + 16K)
  "$LB" --base-url "$BASE_URL" --model "$MODEL" --served-model-name "$MODEL" \
    --pp 2048 --tg 256 --depth 0 16384 --latency-mode generation \
    --runs 3 --warmup-runs 1 --concurrency 1 6 \
    --format md --save-result "$local_log" 2>&1 | tail -20
  # summarize peak clock achieved under load
  peak=$(sort -n "$OUTDIR/.clk-$L.tmp" 2>/dev/null | tail -1)
  echo "  peak GR clock under load: ${peak} MHz"
  echo "  -> $local_log"
done

echo "DONE. Restoring cap."
restore
rm -f "$OUTDIR"/.clk-*.tmp
