#!/bin/bash
#SBATCH -J ucx-xnode
#SBATCH -N2
#SBATCH -w ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-11,ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-12
#SBATCH --gres=gpu:1
#SBATCH --time=00:15:00
# Cross-node UCX comparison test (nosrq-patched rc_verbs), mirrors
# run_crossNode_mori_io.sh. Real second physical node, not self-loopback --
# UCX rc_verbs self-connect failed ("no connect to iface") on same node (11984);
# testing whether the limitation is self-connect-specific or fabric-wide.
set -euo pipefail
LOGROOT=/data/avpaul/disagg_logs/nixlbench_vram
HOST_PREFIX=/data/avpaul/nixlbench-rocm-prefix-nosrq-mori
WORKER=/data/avpaul/disagg_logs/nixlbench_vram/ucx_xnode_worker.sh
IMAGE=${IMAGE:-vllm/vllm-openai-rocm:nightly}
JOB=${SLURM_JOB_ID:-local$$}
ASIO_PORT=$((31000 + JOB % 2000))

MAX_BLOCK=${MAX_BLOCK_SIZE:-1073741824}
START_BLOCK=${START_BLOCK_SIZE:-4096}
NUM_ITER=${NUM_ITER:-64}
WARMUP=${WARMUP_ITER:-16}
TOTAL_BUF=${TOTAL_BUFFER_SIZE:-1073741824}
INIT_SEG=${INITIATOR_SEG_TYPE:-DRAM}
TGT_SEG=${TARGET_SEG_TYPE:-DRAM}
CHECK_CONSISTENCY=${CHECK_CONSISTENCY:-0}
UCX_TLS=${UCX_TLS_OVERRIDE:-rc_verbs,tcp,self}
OUT=$LOGROOT/ucx_xnode_${JOB}.log
exec > >(tee -a "$OUT") 2>&1
echo "=== $(date -u) UCX CROSS-NODE job=$JOB nodelist=${SLURM_NODELIST:-?} UCX_TLS=$UCX_TLS ==="

NODE_TARGET=ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-11
NODE_INIT=ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-12

SRUN=(srun -N1 -n1 --overlap)

IP_TARGET=$("${SRUN[@]}" -w "$NODE_TARGET" bash -lc "hostname -I | tr ' ' '\n' | grep -E '^192\.168\.50\.'" | head -1)
IP_INIT=$("${SRUN[@]}" -w "$NODE_INIT" bash -lc "hostname -I | tr ' ' '\n' | grep -E '^192\.168\.50\.'" | head -1)
[[ -n "$IP_TARGET" && -n "$IP_INIT" ]] || { echo "FATAL: could not resolve fabric IPs"; exit 2; }
echo "NODE_TARGET=$NODE_TARGET ip=$IP_TARGET (acceptor)"
echo "NODE_INIT=$NODE_INIT ip=$IP_INIT (connector)"

test -x "$HOST_PREFIX/bin/nixlbench" || { echo "FATAL: missing nixlbench"; exit 2; }
test -e "$HOST_PREFIX/lib/x86_64-linux-gnu/plugins/libplugin_UCX.so" || { echo "FATAL: missing libplugin_UCX.so"; exit 2; }
chmod +x "$WORKER"

LOG_T=$LOGROOT/ucx_xnode_${JOB}_target.log
LOG_I=$LOGROOT/ucx_xnode_${JOB}_init.log

echo "=== launching target on $NODE_TARGET ==="
"${SRUN[@]}" -w "$NODE_TARGET" bash "$WORKER" TARGET "$IP_TARGET" "$ASIO_PORT" \
  "$HOST_PREFIX" "$IMAGE" "$INIT_SEG" "$TGT_SEG" "$TOTAL_BUF" "$START_BLOCK" "$MAX_BLOCK" "$NUM_ITER" "$WARMUP" "$UCX_TLS" "$CHECK_CONSISTENCY" \
  >"$LOG_T" 2>&1 &
PID_T=$!
sleep 6
echo "=== launching initiator on $NODE_INIT ==="
"${SRUN[@]}" -w "$NODE_INIT" bash "$WORKER" INIT "$IP_TARGET" "$ASIO_PORT" \
  "$HOST_PREFIX" "$IMAGE" "$INIT_SEG" "$TGT_SEG" "$TOTAL_BUF" "$START_BLOCK" "$MAX_BLOCK" "$NUM_ITER" "$WARMUP" "$UCX_TLS" "$CHECK_CONSISTENCY" \
  >"$LOG_I" 2>&1 &
PID_I=$!

EC_T=0; EC_I=0
wait $PID_T || EC_T=$?
wait $PID_I || EC_I=$?

echo "=== target exit=$EC_T, initiator exit=$EC_I ==="
echo "--- target log ---"; cat "$LOG_T" 2>/dev/null
echo "--- initiator log ---"; cat "$LOG_I" 2>/dev/null

BW=""
for f in "$LOG_T" "$LOG_I"; do
  grep -q 'GB/Sec' "$f" 2>/dev/null && { BW=$(awk -v s="$MAX_BLOCK" '$1==s{print $3; exit}' "$f" 2>/dev/null); [[ -n "$BW" ]] && break; }
done

{
  echo "job=$JOB mode=cross_node_ucx target=$NODE_TARGET($IP_TARGET) init=$NODE_INIT($IP_INIT)"
  echo "max_block_size=$MAX_BLOCK seg=${INIT_SEG}->${TGT_SEG}"
  echo "target_ec=$EC_T init_ec=$EC_I parsed_bw_gbs=${BW:-NONE}"
  if [[ $EC_T -eq 0 && $EC_I -eq 0 && -n "${BW:-}" ]]; then
    echo "VERDICT: PASS"
  else
    echo "VERDICT: FAIL"
  fi
} | tee "$LOGROOT/UCX_PLUGIN_CROSSNODE_VERDICT_${JOB}.txt"
echo "=== END $(date -u) ==="
