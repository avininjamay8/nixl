#!/bin/bash
# One nixlbench process in a container. Started on each node by
# run_crossNode_ucx.sh.
#   rank0: binds the ASIO socket, becomes the nixlbench initiator.
#   rank1: connects to rank0, becomes the nixlbench target.
set -euo pipefail
ROLE=${1:?rank0|rank1}
PORT_FILE=${2:?}
: "${NIXL_PREFIX:?}" "${IMAGE:?}" "${OP_TYPE:?}"

if [[ $ROLE == rank0 ]]; then
  IP=$(hostname -I | tr ' ' '\n' | grep -m1 -E "^${FABRIC_NET:-192\.168\.50\.}")
  PORT=$((40000 + RANDOM % 20000))
  while ss -Htln "sport = :$PORT" | grep -q .; do PORT=$((40000 + RANDOM % 20000)); done
  echo "$IP:$PORT" >"$PORT_FILE"
else
  for _ in $(seq 60); do [[ -s $PORT_FILE ]] && break; sleep 0.5; done
  IFS=: read -r IP PORT <"$PORT_FILE"
fi

DEVS=(--device /dev/kfd --device /dev/dri --device /dev/infiniband/rdma_cm)
for d in /dev/infiniband/uverbs*; do DEVS+=(--device "$d"); done

docker run --rm "${DEVS[@]}" \
  --network host --ipc host \
  --group-add video --group-add render \
  --ulimit memlock=-1:-1 --cap-add IPC_LOCK \
  --security-opt seccomp=unconfined \
  -v "$(readlink -f /usr/lib/x86_64-linux-gnu/libionic.so.1):/usr/lib/x86_64-linux-gnu/libionic.so.1:ro" \
  -v /usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so:/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so:ro \
  -v /etc/libibverbs.d/ionic.driver:/etc/libibverbs.d/ionic.driver:ro \
  -v /boot:/boot:ro \
  -v "$NIXL_PREFIX:/prefix:ro" \
  -e HIP_VISIBLE_DEVICES="${GPU:-0}" \
  -e UCX_TLS=rc_verbs,ud_verbs,tcp,self,rocm \
  -e UCX_NET_DEVICES="${UCX_NET_DEVICES:-ionic_0:1,lo}" \
  -e UCX_IB_GID_INDEX=1 \
  -e UCX_UD_VERBS_ETH_DGID_CHECK=n \
  -e UCX_IB_GPU_DIRECT_RDMA=yes \
  -e UCX_RNDV_SCHEME=auto \
  -e UCX_RMA_PPLN_ENABLE=y \
  -e UCX_PROTO_EMULATION_ENABLE=n \
  -e UCX_PROTO_INFO="${UCX_PROTO_INFO:-n}" \
  -e UCX_LOG_LEVEL=info \
  -e SLURM_JOB_ID="${SLURM_JOB_ID:-}" \
  -e LD_LIBRARY_PATH=/prefix/lib:/prefix/lib/x86_64-linux-gnu:/prefix/lib/ucx:/opt/rocm/lib \
  --entrypoint /prefix/bin/nixlbench "$IMAGE" \
  --runtime_type ASIO --asio_address "$IP" --asio_port "$PORT" \
  --backend UCX \
  --op_type "$OP_TYPE" \
  --initiator_seg_type VRAM --target_seg_type VRAM \
  --total_buffer_size "${TOTAL_BUFFER_SIZE:-1073741824}" \
  --start_block_size "${START_BLOCK_SIZE:-4096}" \
  --max_block_size "${MAX_BLOCK_SIZE:-1073741824}" \
  --num_iter "${NUM_ITER:-16}" --warmup_iter "${WARMUP_ITER:-4}" \
  --check_consistency 1
