#!/bin/bash
# Per-node worker for run_crossNode_ucx.sh. One invocation runs on each of
# the two physical nodes (TARGET and INIT roles).
#
# TARGET resolves its own fabric IP and picks its own free local port (it is
# already running on the target node, so no extra srun step is needed to do
# this), then writes "IP:PORT" to the shared NFS port file. INIT polls that
# file and reads it. Passing the resolved value through a file instead of a
# positional argument avoids value corruption observed when passing it
# through srun -> bash -> docker as a bare argument.
set -euo pipefail
TAG=${1:?}
PORT_FILE=${2:?}
HOST_PREFIX=${3:?}
IMAGE=${4:?}
INIT_SEG=${5:?}
TGT_SEG=${6:?}
TOTAL_BUF=${7:?}
START_BLOCK=${8:?}
MAX_BLOCK=${9:?}
NUM_ITER=${10:?}
WARMUP=${11:?}
UCX_TLS=${12:?}
CHECK_CONSISTENCY=${13:-0}

if [[ "$TAG" == TARGET* ]]; then
  ASIO_TARGET_IP=$(hostname -I | tr ' ' '\n' | grep -E '^192\.168\.50\.' | head -1)
  [[ -n "$ASIO_TARGET_IP" ]] || { echo "FATAL[$TAG]: could not resolve own fabric IP"; exit 2; }
  ASIO_PORT=""
  for _ in $(seq 1 20); do
    candidate=$((40000 + RANDOM % 20000))
    if ! ss -tln 2>/dev/null | awk -v p=":$candidate\$" '$4 ~ p' | grep -q .; then
      ASIO_PORT=$candidate
      break
    fi
  done
  [[ -n "$ASIO_PORT" ]] || { echo "FATAL[$TAG]: could not find a free local port"; exit 2; }
  echo "${ASIO_TARGET_IP}:${ASIO_PORT}" > "$PORT_FILE"
  echo "[$TAG] resolved own IP=$ASIO_TARGET_IP, picked free port=$ASIO_PORT, wrote $PORT_FILE"
else
  for _ in $(seq 1 40); do
    [[ -s "$PORT_FILE" ]] && break
    sleep 0.5
  done
  IPPORT=$(cat "$PORT_FILE" 2>/dev/null)
  [[ -n "$IPPORT" ]] || { echo "FATAL[$TAG]: could not read IP:PORT from $PORT_FILE"; exit 2; }
  ASIO_TARGET_IP=${IPPORT%%:*}
  ASIO_PORT=${IPPORT##*:}
fi
[[ -n "${ASIO_PORT:-}" && -n "${ASIO_TARGET_IP:-}" ]] || { echo "FATAL[$TAG]: empty IP/port"; exit 2; }

IBDEV_ARGS=()
[[ -c /dev/infiniband/rdma_cm ]] && IBDEV_ARGS+=(--device /dev/infiniband/rdma_cm)
for d in /dev/infiniband/uverbs[0-9]*; do [[ -c "$d" ]] && IBDEV_ARGS+=(--device "$d"); done
[[ ${#IBDEV_ARGS[@]} -ge 1 ]] || { echo "FATAL[$TAG]: no IB chardevs on $(hostname -s)"; exit 2; }
HOST_IONIC=$(readlink -f /usr/lib/x86_64-linux-gnu/libionic.so.1 2>/dev/null || true)
[[ -n "$HOST_IONIC" && -f "$HOST_IONIC" ]] || { echo "FATAL[$TAG]: host libionic missing on $(hostname -s)"; exit 2; }

echo "[$TAG] host=$(hostname -s) asio_target=$ASIO_TARGET_IP:$ASIO_PORT UCX_TLS=$UCX_TLS"

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
  -e UCX_UD_VERBS_ETH_DGID_CHECK=n \
  --entrypoint bash "${IMAGE}" -lc '
    export PATH=/prefix/bin:$PATH
    export LD_LIBRARY_PATH=/prefix/lib:/prefix/lib/x86_64-linux-gnu:/prefix/lib/ucx:/opt/rocm/lib:/opt/rocm/lib64
    exec nixlbench --runtime_type ASIO --asio_address '"$ASIO_TARGET_IP"' --asio_port '"$ASIO_PORT"' \
      --backend UCX \
      --initiator_seg_type "'"$INIT_SEG"'" --target_seg_type "'"$TGT_SEG"'" \
      --op_type WRITE \
      --total_buffer_size "'"$TOTAL_BUF"'" \
      --start_block_size "'"$START_BLOCK"'" --max_block_size "'"$MAX_BLOCK"'" \
      --num_iter "'"$NUM_ITER"'" --warmup_iter "'"$WARMUP"'" \
      --check_consistency "'"$CHECK_CONSISTENCY"'"
  '
