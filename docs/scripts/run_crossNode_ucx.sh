#!/bin/bash
#SBATCH -J nixlbench-ucx
#SBATCH -N2
#SBATCH --gres=gpu:1
#SBATCH --time=00:20:00
# Cross-node nixlbench, VRAM -> VRAM over UCX rc_verbs. Submit from this dir:
#   sbatch -w <node0>,<node1> --export=ALL,OP_TYPE=READ  run_crossNode_ucx.sh
#   sbatch -w <node0>,<node1> --export=ALL,OP_TYPE=WRITE run_crossNode_ucx.sh
set -euo pipefail
export NIXL_PREFIX=${NIXL_PREFIX:-/data/avpaul/nixlbench-rocm-prefix-ucx122-rtr}
export IMAGE=${IMAGE:-vllm/vllm-openai-rocm:nightly}
export OP_TYPE=${OP_TYPE:-WRITE}
DIR=${SLURM_SUBMIT_DIR:-$PWD}
LOGDIR=${LOGDIR:-$DIR/logs}
JOB=${SLURM_JOB_ID:?}
mkdir -p "$LOGDIR"

# The scheduler on this cluster can start a batch script twice. Two copies
# would share the rendezvous file and pair with each other.
if ! mkdir "$LOGDIR/.lock_$JOB" 2>/dev/null; then
  while [[ ! -e $LOGDIR/.lock_$JOB/done ]]; do sleep 5; done
  exit 0
fi
trap 'touch "$LOGDIR/.lock_$JOB/done"' EXIT

mapfile -t NODES < <(scontrol show hostnames "$SLURM_JOB_NODELIST" 2>/dev/null || true)
((${#NODES[@]} == 2)) || IFS=, read -ra NODES <<<"$SLURM_JOB_NODELIST"

PORT_FILE=$LOGDIR/.asio_$JOB
LOG0=$LOGDIR/${OP_TYPE,,}_${JOB}_rank0.log
LOG1=$LOGDIR/${OP_TYPE,,}_${JOB}_rank1.log
rm -f "$PORT_FILE"

srun -N1 -n1 --overlap -w "${NODES[0]}" bash "$DIR/ucx_xnode_worker.sh" rank0 "$PORT_FILE" >"$LOG0" 2>&1 &
P0=$!
sleep 5
srun -N1 -n1 --overlap -w "${NODES[1]}" bash "$DIR/ucx_xnode_worker.sh" rank1 "$PORT_FILE" >"$LOG1" 2>&1 &
P1=$!
EC0=0 EC1=0
wait $P0 || EC0=$?
wait $P1 || EC1=$?

# A bandwidth table alone is not proof: require one initiator/target pair,
# an rc_verbs inter-node lane, no tcp lane, and no consistency failure.
fail() { echo "VERDICT: FAIL ($1)"; exit 1; }
((EC0 == 0 && EC1 == 0)) || fail "exit $EC0/$EC1"
grep -q "rank 0, type initiator" "$LOG0" || fail "rank0 is not the initiator"
grep -q "rank 1, type target" "$LOG1" || fail "rank1 is not the target"
grep -q "Version 1.22" "$LOG0" || fail "UCX 1.22 not loaded"
grep -q "inter-node cfg.*rc_verbs" "$LOG0" || fail "no rc_verbs lane"
! grep -q "inter-node cfg.*tcp/" "$LOG0" "$LOG1" || fail "tcp lane selected"
! grep -q "Consistency check failed" "$LOG0" "$LOG1" || fail "data mismatch"

echo "op=$OP_TYPE nodes=${NODES[*]} seg=VRAM->VRAM"
awk '/^Block Size/{t=1; next} t && $1 ~ /^[0-9]+$/ {print $1, $3}' "$LOG0" | tee "$LOGDIR/${OP_TYPE,,}_${JOB}.bw"
echo "VERDICT: PASS"
