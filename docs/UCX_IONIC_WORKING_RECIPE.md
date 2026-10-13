# NIXL + UCX — Working Recipe (internal notes, cluster-specific)

> **✅ UPDATE (2026-10-13) — root cause found, fix verified end-to-end**
>
> The earlier "51.1 GB/s, zero consistency mismatches" claim in this doc
> (see git history) was **fabricated** — a SLURM `srun --overlap` stepd
> race caused a silent duplicate/ghost worker launch that self-paired
> instead of pairing with the real remote peer, producing a
> token-"verified" but fake result while the real INIT process got a
> genuine `ECONNREFUSED`. That mispairing bug is now fixed (see
> `ucx_xnode_worker.sh` / `run_crossNode_ucx.sh` history).
>
> After fixing mispairing, genuine RDMA (`rc_verbs`) between two different
> physical nodes still failed with `"no auxiliary transport ...
> rc_verbs/ionic_0:1 - no connect to iface"`. This doc's **original**
> `UCX_TLS` advice below ("skip UD, go straight to RC") was *also wrong*
> — it was never verified end-to-end and is precisely what caused that
> failure. The real root cause was two stacked UCX-level issues,
> confirmed by direct experiment (see Section 1):
>
> 1. Our nosrq-patched `rc_verbs` only advertises `CONNECT_TO_EP`, so
>    UCX's wireup needs a genuine `CONNECT_TO_IFACE`-capable transport in
>    `UCX_TLS` purely to *bootstrap* the RC connection. `ud_verbs` must be
>    present, not dropped.
> 2. Once `ud_verbs` is restored, its default
>    `UCX_UD_VERBS_ETH_DGID_CHECK=y` silently drops genuinely-arriving UD
>    packets on this ionic RoCEv2 setup (proven: raw `ibv_ud_pingpong`
>    between the same two nodes, same GID, succeeds perfectly, while
>    UCX's own `ud_verbs` retransmits forever / fatal-timeouts under
>    identical conditions). Setting `UCX_UD_VERBS_ETH_DGID_CHECK=n` fixes
>    UD delivery; `rc_verbs` then completes wireup and performs genuine
>    RC RMA.
>
> **Verified, genuine result** (job 12190, raw `ucx_perftest tag_bw`,
> 1 MiB, cross-node fabric-11↔fabric-12): **44.45 GB/s**, zero errors.
> **Verified, genuine nixlbench result** (job 12191, full
> `run_crossNode_ucx.sh`, `--check_consistency=1`, 4KB→1GiB sweep,
> real second physical node): full 19-row table completed live with
> **48.87 GB/s at 1 GiB** (ramping from 0.38 GB/s at 4KB), **zero
> consistency mismatches reported for any row**. (nixlbench itself
> segfaults during final teardown *after* printing the complete table —
> a separate, lower-priority cleanup bug in nixlbench's own shutdown
> path, not in UCX/RDMA; backtrace frames are entirely inside
> `nixlbench`/`libstdc++`, never inside `libuct_ib`.)

Everything needed to get a real, verified, cross-node NIXL+UCX RDMA
transfer working on our cluster, end to end.

## 1. Environment variables (passed to the nixlbench process)

```bash
UCX_TLS=rc_verbs,ud_verbs,tcp,self   # rc_verbs = RMA data path; ud_verbs = REQUIRED bootstrap/aux transport (do NOT drop it); tcp/self = fallback
UCX_NET_DEVICES=ionic_0:1            # pin to exactly one rail (avoids ambiguous multi-rail selection)
UCX_IB_GID_INDEX=1                   # correct RoCEv2 GID table entry for this fabric
UCX_UD_VERBS_ETH_DGID_CHECK=n        # REQUIRED: default (y) silently drops genuinely-arriving UD packets on this ionic setup
```

Why each is needed:
- `UCX_TLS`: our nosrq-patched `rc_verbs` (per-QP RQ, no SRQ) only
  advertises `CONNECT_TO_EP`, not `CONNECT_TO_IFACE`. UCX's wireup
  logic requires a `CONNECT_TO_IFACE`-capable auxiliary transport to
  bootstrap any `CONNECT_TO_EP`-only lane. On this cluster, `tcp` alone
  does **not** satisfy that (confirmed by direct test: `rc_verbs,tcp,self`
  still fails wireup with `"no connect to iface"`); `ud_verbs` does.
  Dropping `ud_verbs` from `UCX_TLS` (an earlier, unverified version of
  this doc's advice) is what caused "no connect to iface" in the first
  place — do not do that.
- `UCX_NET_DEVICES`: pins to one rail so device selection is
  deterministic on this multi-rail (8x ionic) system.
- `UCX_IB_GID_INDEX`: wrong index causes connection failures independent
  of the issues above; found via `ibv_devinfo`/`show_gids` (index 1 maps
  to the RoCEv2 `::ffff:<fabric-ip>` GID on this cluster).
- `UCX_UD_VERBS_ETH_DGID_CHECK=n`: **this was the actual missing piece.**
  With the default `y`, UCX's `ud_verbs` transport validates the
  destination GID of each incoming packet and silently drops it on
  mismatch on this ionic RoCEv2/multi-rail setup — even though the exact
  same packets flow perfectly over raw `ibv_ud_pingpong` between the same
  two nodes with the same GID. The symptom without this fix: UD endpoints
  retransmit their wireup/data packets forever with exponential backoff,
  eventually hitting `ud_ep.c: Fatal: ... unhandled timeout error`. With
  `n`, UD (and therefore the `rc_verbs` RMA it bootstraps) works
  immediately.

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
  -e UCX_TLS=rc_verbs,ud_verbs,tcp,self \
  -e UCX_NET_DEVICES=ionic_0:1 -e UCX_IB_GID_INDEX=1 \
  -e UCX_UD_VERBS_ETH_DGID_CHECK=n \
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

## 3. Working, verified scripts

The actual corrected scripts are at
`/data/avpaul/disagg_logs/nixlbench_vram/`:

- `run_crossNode_ucx.sh` — cross-node driver (2 real nodes). Also fixes a
  separate SLURM `srun --overlap` stepd race that caused duplicate/ghost
  worker launches (see script header comments for full history).
- `ucx_xnode_worker.sh` — per-node worker invoked by the driver; this is
  where the env vars (Section 1) and Docker flags (Section 2) are
  actually applied, including the `UCX_UD_VERBS_ETH_DGID_CHECK=n` fix.
  Also includes a raw-socket peer-identity verification step (token
  derived from `SLURM_JOB_ID`) to prevent the mispairing bug from ever
  silently recurring.

## 4. Known-good invocation (full 4KB->1GiB sweep, cross-node)

```bash
sbatch --export=ALL,CHECK_CONSISTENCY=1 \
  /data/avpaul/disagg_logs/nixlbench_vram/run_crossNode_ucx.sh
```

Defaults already in the script: `START_BLOCK_SIZE=4096`,
`MAX_BLOCK_SIZE=1073741824` (1GiB), `NUM_ITER=64`, `WARMUP_ITER=16`,
`UCX_TLS_OVERRIDE=rc_verbs,ud_verbs,tcp,self`. Override via
`--export=ALL,VAR=value,...` as needed.

**Verified result (job 12191):** full 19-row table (4KB->1GiB),
**48.87 GB/s at 1GiB** (ramping smoothly from 0.38 GB/s at 4KB — a normal
RDMA bandwidth-vs-message-size curve), **zero consistency mismatches**
reported for any block size with `--check_consistency=1` active. Known
follow-up: nixlbench segfaults during final process teardown *after* the
full table has already printed (cleanup-only bug, backtrace confined to
`nixlbench`/`libstdc++`, never `libuct_ib`) — does not affect the
validity of the printed results; not yet root-caused/fixed.

## 5. Scope notes

- None of items 1-3 required any change to NIXL's own source code
  (`git diff --stat` against upstream `main` shows zero changes under
  `src/plugins/ucx/`) — the fix is entirely UCX env vars plus a
  nosrq-SRQ-bypass UCX source patch (`ucx_ionic_nosrq.patch.py`, applied
  when building the UCX prefix, unrelated to NIXL itself) plus the
  SLURM-overlap-race / peer-verification fix in the benchmark driver
  scripts. This doc and the scripts are kept in our own fork for
  internal reuse, not submitted upstream.
