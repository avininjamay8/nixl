# NIXL + UCX — Working Recipe (internal notes, cluster-specific)

Everything needed to get a real, verified, cross-node NIXL+UCX RDMA
transfer working on our cluster, end to end. Confirmed clean up to 1 GiB,
`--check_consistency=1` passing at every block size from 4KB to 1GiB.

## 1. Environment variables (passed to the nixlbench process)

```bash
UCX_TLS=rc_verbs,tcp,self      # skip UCX's default UD wireup (hangs ~30s on this NIC); go straight to RC
UCX_NET_DEVICES=ionic_0:1,lo   # pin to exactly one rail + loopback (avoids ambiguous multi-rail selection)
UCX_IB_GID_INDEX=1             # correct RoCEv2 GID table entry for this fabric
```

Why each is needed:
- `UCX_TLS`: UCX's default transport selection includes UD (Unreliable
  Datagram) to bootstrap the RC transport. On this cluster's Pensando
  `ionic` NIC, that UD step hangs/times out (~30s). The hardware itself is
  healthy (verified via raw ibverbs UD send/recv) -- it's specifically
  UCX's wireup path that's affected. Forcing the transport list to skip UD
  fixes it.
- `UCX_NET_DEVICES`: pins to one rail so device selection is deterministic
  on this multi-rail (8x ionic) system. Verified via NIC hardware counters
  that traffic is isolated to exactly this one rail -- zero leakage to the
  other 7.
- `UCX_IB_GID_INDEX`: wrong index causes connection failures independent
  of the UD/RC issue above; found via `ibv_devinfo`/`show_gids`.

## 2. Docker container launch flags

```bash
docker run --rm \
  --device /dev/kfd --device /dev/dri \
  --device /dev/infiniband/rdma_cm \
  --device /dev/infiniband/uverbs0 `# repeat for each uverbsN present` \
  --group-add video --group-add render --network host \
  --ipc=host --ulimit memlock=-1:-1 --cap-add=IPC_LOCK \
  --security-opt seccomp=unconfined \
  -v /usr/lib/x86_64-linux-gnu/libionic.so.1:/usr/lib/x86_64-linux-gnu/libionic.so.1:ro \
  -v /usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so:/usr/lib/x86_64-linux-gnu/libibverbs/libionic-rdmav34.so:ro \
  -v /etc/libibverbs.d/ionic.driver:/etc/libibverbs.d/ionic.driver:ro \
  -v "$HOST_PREFIX:/prefix:ro" \
  -e UCX_TLS=rc_verbs,tcp,self -e UCX_NET_DEVICES=ionic_0:1,lo -e UCX_IB_GID_INDEX=1 \
  --entrypoint bash "$IMAGE" -lc '...'
```

Why each is needed:
- `--device /dev/infiniband/rdma_cm` + `uverbs*`: containers need direct
  access to the RDMA character devices to open verbs contexts at all.
- `--ipc=host --ulimit memlock=-1:-1 --cap-add=IPC_LOCK`: RDMA memory
  registration pins (locks) memory pages. Default container memlock limits
  block this.
- `--security-opt seccomp=unconfined`: some verbs/memory-pinning syscalls
  are blocked by the default container seccomp profile.
- The three `-v` bind-mounts: the container image does not ship the host's
  NIC-specific verbs provider driver (`libionic*`). Without these,
  `libibverbs` cannot find a usable device even with the character devices
  present.

## 3. Script-level bug fixed (our own test harness, not a NIXL bug)

Our test scripts (`run_sameNode_loopback_ucx.sh`, `run_crossNode_ucx.sh`,
`ucx_xnode_worker.sh`, all under
`/data/avpaul/disagg_logs/nixlbench_vram/`) had `--check_consistency`
defined as a variable but never actually passed it to the nixlbench
binary -- so earlier "passing" runs were not actually byte-verified.

Fixed by:
- Adding `CHECK_CONSISTENCY=${CHECK_CONSISTENCY:-0}` to each script.
- Adding `--check_consistency "$CHECK_CONSISTENCY"` to the real nixlbench
  invocation.
- Threading `$CHECK_CONSISTENCY` through as an explicit positional arg
  between the driver scripts and `ucx_xnode_worker.sh`.

## 4. Known-good invocation (full 4KB->1GiB sweep, cross-node)

```bash
cd /data/avpaul/disagg_logs/nixlbench_vram
sbatch --export=ALL,CHECK_CONSISTENCY=1 run_crossNode_ucx.sh
```

Defaults already in the script: `START_BLOCK_SIZE=4096`,
`MAX_BLOCK_SIZE=1073741824` (1GiB), `NUM_ITER=64`, `WARMUP_ITER=16`,
`UCX_TLS_OVERRIDE=rc_verbs,tcp,self`. Override via
`--export=ALL,VAR=value,...` as needed.

Result reference: `UCX_PLUGIN_CROSSNODE_VERDICT_12016.txt` and
`ucx_xnode_12016_target.log` under
`/data/avpaul/disagg_logs/nixlbench_vram/` -- full 19-row table, 51.1 GB/s
plateau at 1GiB, zero consistency mismatches.

## 5. Scope notes

- None of items 1-2 required any change to NIXL's own source code
  (`git diff --stat` against upstream `main` shows zero changes under
  `src/plugins/ucx/`). This doc is kept in our own fork for internal reuse,
  not submitted upstream.
- Item 3 is a bug in our own private scripts, outside the NIXL repo
  entirely.
