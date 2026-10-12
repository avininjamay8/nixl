#!/bin/bash
#SBATCH -J ucx-loopback
#SBATCH -N1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:1
#SBATCH --time=00:15:00
#SBATCH -w ml-ai-ubuntu-gpu-mi350x8-2304gb-fabric-11
# Same-node UCX comparison test, mirrors run_sameNode_loopback_mori_io.sh exactly
# but with --backend UCX, using the "nosrq" patched UCX (rc_verbs without SRQ,
# see ucx_ionic_nosrq.patch.py) instead of the stock UCX that hit
# NIXL_ERR_REMOTE_DISCONNECT (ud_verbs-only) per NIXL_WAR_STATUS.txt.
set -euo pipefail
LOGROOT=/data/avpaul/disagg_logs/nixlbench_vram
HOST_PREFIX=/data/avpaul/nixlbench-rocm-prefix-nosrq-mori
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
OUT=$LOGROOT/ucx_loopback_${JOB}.log
exec > >(tee -a "$OUT") 2>&1
echo "=== $(date -u) UCX same-node loopback job=$JOB host=$(hostname -s) UCX_TLS=$UCX_TLS ==="

test -x "$HOST_PREFIX/bin/nixlbench" || { echo "FATAL: missing nixlbench at $HOST_PREFIX/bin"; exit 2; }
test -e "$HOST_PREFIX/lib/x86_64-linux-gnu/plugins/libplugin_UCX.so" || { echo "FATAL: missing libplugin_UCX.so"; exit 2; }

MY_IP=$(hostname -I | tr ' ' '\n' | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -E '^192\.168\.50\.' | head -1 || true)
[[ -n "$MY_IP" ]] || { echo "FATAL: no fabric IP found via hostname -I"; exit 2; }
echo "MY_IP=$MY_IP (self-loopback)"
echo "ASIO rendezvous on 127.0.0.1:${ASIO_PORT}"

run_worker() {
  local tag=$1 log=$2
  IBDEV_ARGS=()
  [[ -c /dev/infiniband/rdma_cm ]] && IBDEV_ARGS+=(--device /dev/infiniband/rdma_cm)
  for d in /dev/infiniband/uverbs[0-9]*; do [[ -c "$d" ]] && IBDEV_ARGS+=(--device "$d"); done
  [[ ${#IBDEV_ARGS[@]} -ge 1 ]] || { echo "FATAL[$tag]: no IB chardevs"; return 2; }
  HOST_IONIC=$(readlink -f /usr/lib/x86_64-linux-gnu/libionic.so.1 2>/dev/null || true)
  [[ -n "$HOST_IONIC" && -f "$HOST_IONIC" ]] || { echo "FATAL[$tag]: host libionic missing"; return 2; }
  docker run --rm \
    --device /dev/kfd --device /dev/dri "${IBDEV_ARGS[@]}" \
    --group-add video --group-add render --network host \
    --ipc=host --ulimit memlock=-1:-1 --cap-add=IPC_LOCK \
    --security-opt seccomp=unconfined \
    -v "${HOST_IONIC}:/usr/lib/x86_64-linux-gnu/libionic.so.1:ro" \
    -v /usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so:/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so:ro \
    -v /etc/libibverbs.d/ionic.driver:/etc/libibverbs.d/ionic.driver:ro \
    -v "${HOST_PREFIX}:/prefix:ro" \
    -e UCX_TLS="${UCX_TLS}" \
    -e UCX_NET_DEVICES=ionic_0:1,lo \
    -e UCX_IB_GID_INDEX=1 \
    --entrypoint bash "${IMAGE}" -lc '
      export PATH=/prefix/bin:$PATH
      export LD_LIBRARY_PATH=/prefix/lib:/prefix/lib/x86_64-linux-gnu:/prefix/lib/ucx:/opt/rocm/lib:/opt/rocm/lib64
      echo "['"$tag"'] UCX_TLS=$UCX_TLS UCX_NET_DEVICES=$UCX_NET_DEVICES"
      exec nixlbench --runtime_type ASIO --asio_address 127.0.0.1 --asio_port '"$ASIO_PORT"' \
        --backend UCX \
        --initiator_seg_type "'"$INIT_SEG"'" --target_seg_type "'"$TGT_SEG"'" \
        --op_type WRITE \
        --total_buffer_size "'"$TOTAL_BUF"'" \
        --start_block_size "'"$START_BLOCK"'" --max_block_size "'"$MAX_BLOCK"'" \
        --num_iter "'"$NUM_ITER"'" --warmup_iter "'"$WARMUP"'" \
        --check_consistency "'"$CHECK_CONSISTENCY"'"
    ' >"$log" 2>&1
}

LOG_A=$LOGROOT/ucx_loopback_${JOB}_procA.log
LOG_B=$LOGROOT/ucx_loopback_${JOB}_procB.log
echo "=== launching proc A ==="
run_worker A "$LOG_A" &
PID_A=$!
sleep 3
echo "=== launching proc B ==="
run_worker B "$LOG_B" &
PID_B=$!

EC_A=0; EC_B=0
wait $PID_A || EC_A=$?
wait $PID_B || EC_B=$?

echo "=== proc A exit=$EC_A, proc B exit=$EC_B ==="
echo "--- proc A log ---"; cat "$LOG_A" 2>/dev/null
echo "--- proc B log ---"; cat "$LOG_B" 2>/dev/null

BW=""
for f in "$LOG_A" "$LOG_B"; do
  grep -q 'GB/Sec' "$f" 2>/dev/null && { BW=$(awk -v s="$MAX_BLOCK" '$1==s{print $3; exit}' "$f" 2>/dev/null); [[ -n "$BW" ]] && break; }
done

{
  echo "job=$JOB mode=same_node_loopback_ucx host=$(hostname -s) ip=$MY_IP"
  echo "max_block_size=$MAX_BLOCK seg=${INIT_SEG}->${TGT_SEG}"
  echo "procA_ec=$EC_A procB_ec=$EC_B parsed_bw_gbs=${BW:-NONE}"
  if [[ $EC_A -eq 0 && $EC_B -eq 0 && -n "${BW:-}" ]]; then
    echo "VERDICT: PASS"
  else
    echo "VERDICT: FAIL"
  fi
} | tee "$LOGROOT/UCX_PLUGIN_LOOPBACK_VERDICT_${JOB}.txt"
echo "=== END $(date -u) ==="
