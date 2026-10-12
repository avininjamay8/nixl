#!/bin/bash
# Per-node worker for run_crossNode_ucx.sh. Mirrors mori_io_xnode_worker.sh.
set -euo pipefail
TAG=${1:?}
ASIO_TARGET_IP=${2:?}
ASIO_PORT=${3:?}
HOST_PREFIX=${4:?}
IMAGE=${5:?}
INIT_SEG=${6:?}
TGT_SEG=${7:?}
TOTAL_BUF=${8:?}
START_BLOCK=${9:?}
MAX_BLOCK=${10:?}
NUM_ITER=${11:?}
WARMUP=${12:?}
UCX_TLS=${13:?}
CHECK_CONSISTENCY=${14:-0}

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
  --entrypoint bash "${IMAGE}" -lc '
    export PATH=/prefix/bin:$PATH
    export LD_LIBRARY_PATH=/prefix/lib:/prefix/lib/x86_64-linux-gnu:/prefix/lib/ucx:/opt/rocm/lib:/opt/rocm/lib64
    echo "['"$TAG"'] NIXL_PLUGIN_DIR default (UCX builtin)"
    exec nixlbench --runtime_type ASIO --asio_address '"$ASIO_TARGET_IP"' --asio_port '"$ASIO_PORT"' \
      --backend UCX \
      --initiator_seg_type "'"$INIT_SEG"'" --target_seg_type "'"$TGT_SEG"'" \
      --op_type WRITE \
      --total_buffer_size "'"$TOTAL_BUF"'" \
      --start_block_size "'"$START_BLOCK"'" --max_block_size "'"$MAX_BLOCK"'" \
      --num_iter "'"$NUM_ITER"'" --warmup_iter "'"$WARMUP"'" \
      --check_consistency "'"$CHECK_CONSISTENCY"'"
  '
