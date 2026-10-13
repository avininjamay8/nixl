#!/bin/bash
#SBATCH -J ucx-xnode
#SBATCH -N2
#SBATCH -w ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-11,ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-12
#SBATCH --gres=gpu:1
#SBATCH --time=00:15:00
#
# Cross-node NIXL+UCX RDMA WRITE driver (2 real physical nodes) for the
# "ionic" NIC fabric. See docs/UCX_IONIC_WORKING_RECIPE.md for the full
# recipe this script implements.
set -euo pipefail
LOGROOT=/data/avpaul/disagg_logs/nixlbench_vram
HOST_PREFIX=${HOST_PREFIX:-/data/avpaul/nixlbench-rocm-prefix-nosrq}
WORKER=/data/avpaul/disagg_logs/nixlbench_vram/ucx_xnode_worker.sh
IMAGE=${IMAGE:-vllm/vllm-openai-rocm:nightly}
JOB=${SLURM_JOB_ID:-local$$}

MAX_BLOCK=${MAX_BLOCK_SIZE:-1073741824}
START_BLOCK=${START_BLOCK_SIZE:-4096}
NUM_ITER=${NUM_ITER:-64}
WARMUP=${WARMUP_ITER:-16}
TOTAL_BUF=${TOTAL_BUFFER_SIZE:-1073741824}
INIT_SEG=${INITIATOR_SEG_TYPE:-DRAM}
TGT_SEG=${TARGET_SEG_TYPE:-DRAM}
CHECK_CONSISTENCY=${CHECK_CONSISTENCY:-0}
UCX_TLS=${UCX_TLS_OVERRIDE:-rc_verbs,ud_verbs,tcp,self}

OUT=$LOGROOT/ucx_xnode_${JOB}.log
exec > >(tee -a "$OUT") 2>&1
echo "=== $(date -u) UCX CROSS-NODE WRITE job=$JOB nodelist=${SLURM_NODELIST:-?} UCX_TLS=$UCX_TLS ==="

# This cluster's SLURM wrapper ("Spur") doesn't support `scontrol show
# hostnames`, but SLURM_JOB_NODELIST is already a plain comma-separated list
# of full hostnames on this cluster (not SLURM's bracketed compressed form),
# so we split on comma directly. Falls back to the two nodes this script is
# pinned to above if SLURM_JOB_NODELIST is unavailable for some reason.
if [[ -n "${SLURM_JOB_NODELIST:-}" && "$SLURM_JOB_NODELIST" == *,* ]]; then
  IFS=',' read -ra _NODES <<< "$SLURM_JOB_NODELIST"
  NODE_TARGET="${_NODES[0]}"
  NODE_INIT="${_NODES[1]}"
else
  NODE_TARGET=ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-11
  NODE_INIT=ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-12
fi

SRUN=(srun -N1 -n1 --overlap)

test -x "$HOST_PREFIX/bin/nixlbench" || { echo "FATAL: missing nixlbench"; exit 2; }
test -e "$HOST_PREFIX/lib/x86_64-linux-gnu/plugins/libplugin_UCX.so" || { echo "FATAL: missing libplugin_UCX.so"; exit 2; }
chmod +x "$WORKER"

# TARGET resolves its own fabric IP and picks its own free local port (it's
# already running on that node, no extra srun step needed), then writes
# "IP:PORT" to this shared NFS file. INIT just reads it. This keeps exactly
# one srun --overlap step per node and avoids any hardcoded/collision-prone
# port assumptions.
PORT_FILE="$LOGROOT/.asio_port_${JOB}"
rm -f "$PORT_FILE"

LOG_T=$LOGROOT/ucx_xnode_${JOB}_target.log
LOG_I=$LOGROOT/ucx_xnode_${JOB}_init.log

echo "=== launching target on $NODE_TARGET (self-resolves IP+port), port_file=$PORT_FILE ==="
"${SRUN[@]}" -w "$NODE_TARGET" bash "$WORKER" TARGET "$PORT_FILE" \
  "$HOST_PREFIX" "$IMAGE" "$INIT_SEG" "$TGT_SEG" "$TOTAL_BUF" "$START_BLOCK" "$MAX_BLOCK" "$NUM_ITER" "$WARMUP" "$UCX_TLS" "$CHECK_CONSISTENCY" \
  >"$LOG_T" 2>&1 &
PID_T=$!
sleep 6
echo "=== launching initiator on $NODE_INIT, port_file=$PORT_FILE (contents: $(cat "$PORT_FILE" 2>/dev/null)) ==="
"${SRUN[@]}" -w "$NODE_INIT" bash "$WORKER" INIT "$PORT_FILE" \
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

# A clean exit code and a parsed bandwidth number are not sufficient on
# their own: nixlbench's ASIO rendezvous has no peer-identity verification,
# so always confirm neither side crashed/timed out mid-rendezvous and that
# the rank/type pairing is exactly one initiator + one target before
# trusting any printed number.
PAIRING_OK=1
if grep -q "Connection refused\|ASIO Receive timeout\|terminate called" "$LOG_T" "$LOG_I" 2>/dev/null; then
  echo "PAIRING_CHECK: FAIL -- a peer crashed/timed out before completing rendezvous"
  PAIRING_OK=0
fi
RANK_T=$(grep -oP 'rank \K[0-9]+(?=, type)' "$LOG_T" 2>/dev/null | head -1)
RANK_I=$(grep -oP 'rank \K[0-9]+(?=, type)' "$LOG_I" 2>/dev/null | head -1)
TYPE_T=$(grep -oP 'type \K\w+(?=,)' "$LOG_T" 2>/dev/null | head -1)
TYPE_I=$(grep -oP 'type \K\w+(?=,)' "$LOG_I" 2>/dev/null | head -1)
echo "PAIRING_CHECK: target saw rank=${RANK_T:-?}/type=${TYPE_T:-?}; init saw rank=${RANK_I:-?}/type=${TYPE_I:-?}"
if [[ "$RANK_T" != "0" || "$TYPE_T" != "initiator" || "$RANK_I" != "1" || "$TYPE_I" != "target" ]]; then
  echo "PAIRING_CHECK: FAIL -- expected target(rank=0,initiator)/init(rank=1,target)"
  PAIRING_OK=0
fi

{
  IPPORT_RESOLVED=$(cat "$PORT_FILE" 2>/dev/null)
  echo "job=$JOB mode=cross_node_ucx_write target=$NODE_TARGET init=$NODE_INIT asio_ipport=${IPPORT_RESOLVED:-UNKNOWN}"
  echo "max_block_size=$MAX_BLOCK seg=${INIT_SEG}->${TGT_SEG}"
  echo "target_ec=$EC_T init_ec=$EC_I parsed_bw_gbs=${BW:-NONE} pairing_ok=$PAIRING_OK"
  if [[ $EC_T -eq 0 && $EC_I -eq 0 && -n "${BW:-}" && $PAIRING_OK -eq 1 ]]; then
    echo "VERDICT: PASS"
  else
    echo "VERDICT: FAIL"
  fi
} | tee "$LOGROOT/UCX_PLUGIN_CROSSNODE_VERDICT_${JOB}.txt"
echo "=== END $(date -u) ==="
