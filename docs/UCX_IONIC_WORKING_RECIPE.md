# NIXL + UCX — Working Recipe (internal notes, cluster-specific)

Everything needed to get a real, verified, cross-node NIXL+UCX RDMA
**WRITE** transfer working over the "ionic" NIC fabric on this cluster.

**Verified result:** full 19-row sweep (4KB→1GiB), `--check_consistency=1`,
real second physical node: **48.87 GB/s at 1 GiB** (ramping smoothly from
0.38 GB/s at 4KB — a normal RDMA bandwidth-vs-message-size curve), **zero
consistency mismatches** reported for any block size. Confirmed
independently via `ionic_0` hardware RDMA byte counters
(`/sys/class/infiniband/ionic_0/ports/1/hw_counters/{rx,tx}_rdma_ucast_bytes`)
bracketed before/after the run, matching the expected total transferred
bytes for the sweep.

Known follow-up (does not affect result validity): nixlbench segfaults
during final process teardown, *after* the full table has already printed.
The crash backtrace is confined entirely to `nixlbench`/`libstdc++`, never
`libuct_ib` — a post-completion cleanup bug in nixlbench's own shutdown
path, not in UCX or the RDMA transfer itself.

## 1. Environment variables (passed to the nixlbench process)

```bash
UCX_TLS=rc_verbs,ud_verbs,tcp,self   # rc_verbs = RMA data path; ud_verbs = required bootstrap/aux transport; tcp/self = fallback
UCX_NET_DEVICES=ionic_0:1            # pin to exactly one rail (avoids ambiguous multi-rail selection)
UCX_IB_GID_INDEX=1                   # correct RoCEv2 GID table entry for this fabric
UCX_UD_VERBS_ETH_DGID_CHECK=n        # default (y) silently drops genuinely-arriving UD packets on this ionic setup
```

Why each is needed:
- `UCX_TLS`: our nosrq-patched `rc_verbs` (per-QP RQ, no SRQ) only
  advertises `CONNECT_TO_EP`, not `CONNECT_TO_IFACE`. UCX's wireup logic
  requires a `CONNECT_TO_IFACE`-capable auxiliary transport to bootstrap
  any `CONNECT_TO_EP`-only lane. `tcp` alone does not satisfy that on this
  cluster (`rc_verbs,tcp,self` fails wireup with `"no connect to iface"`);
  `ud_verbs` does, so it must stay in `UCX_TLS`.
- `UCX_NET_DEVICES`: pins to one rail so device selection is deterministic
  on this multi-rail (8x ionic) system.
- `UCX_IB_GID_INDEX`: wrong index causes connection failures independent of
  the issues above; found via `ibv_devinfo`/`show_gids` (index 1 maps to
  the RoCEv2 `::ffff:<fabric-ip>` GID on this cluster).
- `UCX_UD_VERBS_ETH_DGID_CHECK=n`: the critical fix. With the default `y`,
  UCX's `ud_verbs` transport validates the destination GID of each
  incoming packet and silently drops it on mismatch on this ionic
  RoCEv2/multi-rail setup — even though the exact same packets flow
  perfectly over raw `ibv_ud_pingpong` between the same two nodes with the
  same GID. The symptom without this fix: UD endpoints retransmit their
  wireup/data packets forever with exponential backoff, eventually hitting
  `ud_ep.c: Fatal: ... unhandled timeout error`. With `n`, UD (and
  therefore the `rc_verbs` RMA it bootstraps) works immediately.

Raw `ucx_perftest tag_bw` cross-node confirms the fabric path itself is
healthy at **44.45 GB/s, zero errors** (1 MiB messages) independent of
nixlbench/NIXL.

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

The working scripts are checked in at `docs/scripts/` (and mirrored at
`/data/avpaul/disagg_logs/nixlbench_vram/` for live runs):

- `run_crossNode_ucx.sh` — cross-node driver, launched via `sbatch` across
  2 real physical nodes. Derives the TARGET/INIT node pair from
  `SLURM_JOB_NODELIST` so the same script runs against any node pair, not
  just the two it was developed on. Verifies genuine peer pairing (exactly
  one initiator + one target, neither side crashed mid-rendezvous) before
  trusting any printed bandwidth number — nixlbench's own ASIO rendezvous
  has no peer-identity verification, so this check is done externally.
- `ucx_xnode_worker.sh` — per-node worker invoked by the driver. TARGET
  resolves its own fabric IP and a free local port, then writes `IP:PORT`
  to a shared NFS file for INIT to read (avoids value corruption seen when
  passing that value as a bare positional argument through
  `srun -> bash -> docker`). This is also where the UCX env vars (Section 1)
  and Docker flags (Section 2) are applied.

## 4. Known-good invocation (full 4KB→1GiB sweep, cross-node)

```bash
sbatch --export=ALL,CHECK_CONSISTENCY=1 \
  /data/avpaul/disagg_logs/nixlbench_vram/run_crossNode_ucx.sh
```

Defaults already in the script: `START_BLOCK_SIZE=4096`,
`MAX_BLOCK_SIZE=1073741824` (1GiB), `NUM_ITER=64`, `WARMUP_ITER=16`,
`INITIATOR_SEG_TYPE=DRAM`, `TARGET_SEG_TYPE=DRAM`,
`UCX_TLS_OVERRIDE=rc_verbs,ud_verbs,tcp,self`. Override any of these via
`--export=ALL,VAR=value,...` as needed.

## 5. Scope notes

- None of items 1–3 require any change to NIXL's own source code
  (`git diff --stat` against upstream `main` shows zero changes under
  `src/plugins/ucx/`) — the fix is entirely UCX env vars plus a
  nosrq-SRQ-bypass UCX source patch (`ucx_ionic_nosrq.patch.py`, applied
  when building the UCX prefix, unrelated to NIXL itself) and the benchmark
  driver scripts above. This doc and the scripts are kept in our own fork
  for internal reuse, not submitted upstream.
- Sections 1–4 cover **WRITE** mode only. Section 6 explains why READ is
  slow on this stack and what vLLM disaggregated serving uses instead.

## 6. vLLM disaggregated serving (NIXL KV connector)

**Verified result:** DeepSeek-V3 TP8 1P1D across 2 nodes, KV cache
VRAM-to-VRAM over `rc_verbs`, gsm8k (limit 50) **0.94**. All 400 transfers
(50 requests × 8 TP ranks) succeeded, 0 failed, no recompute fallback;
~1.2 ms per ~35 MB transfer, ~28–31 GB/s per rank (SLURM job 12880).

### READ vs WRITE in vLLM

| vLLM connector | NIXL op | UCX call | Protocol selected (default NIXL settings) |
|---|---|---|---|
| `NixlConnector` / `NixlPullConnector` (decode pulls) | `READ` | `ucp_get_nbx` | `get/am/bcopy`: emulated, **~0.7 GB/s** |
| `NixlPushConnector` (prefill pushes) | `WRITE` | `ucp_put_nbx` | `put/offload/zcopy`: RDMA WRITE, **~30–48 GB/s** |

Root cause of the slow READ: the NIXL UCX backend defaults to
`UCP_ERR_HANDLING_MODE_PEER` (`src/plugins/ucx/ucx_backend.cpp`, backend
param `ucx_error_handling_mode`). In UCX 1.18.1, `proto_multi.c` rejects any
protocol that doesn't declare `UCP_PROTO_COMMON_INIT_FLAG_ERR_HANDLING` when
error handling is enabled. `get/zcopy` and `get/bcopy` (`rma/get_offload.c`)
don't declare it, so the only GET left is `get/am/bcopy` (`rma/get_am.c`).
That isn't an RDMA READ: it sends active messages that consume the
receiver's preposted RQ buffers on the nosrq build, causing RNR retries and
hangs under vLLM load. All `put/offload/*` protocols do declare the flag, so
WRITE stays zero-copy. vLLM doesn't expose `ucx_error_handling_mode`.

Setting `ucx_error_handling_mode=none` does select fast GET (47.8 GB/s in a
standalone NIXL Python probe), but the probe's data check **failed**, so
it's not a usable fix. Use WRITE.

### Recipe (deltas from Sections 1–2)

| Change | Why |
|---|---|
| `kv_connector=NixlPushConnector`, `kv_buffer_device=cuda` | Uses RDMA WRITE (see above); KV stays in VRAM. Limits: no DCP>1, and prefill/decode KV cache layouts must match. |
| `UCX_NET_DEVICES=ionic_<gpu>:1,lo`, set per TP rank | GPU *k* sits on the same PCIe switch as `ionic_k`, and the rails are isolated (`ionic_k` reaches only `ionic_k`). One shared device for all 8 ranks puts every rank on one rail. All 8 ranks share one container env, so a patched `nixl_rocm/_api.py` sets it in `nixl_agent.__init__` from `torch.cuda.current_device()`, before UCX initializes. |
| `UCX_TLS=rc_verbs,ud_verbs,tcp,self,rocm_copy` | Adds `rocm_copy` to Section 1's list. Without it UCX registers VRAM as host memory. |
| `UCX_IB_GPU_DIRECT_RDMA=yes`, `UCX_RNDV_SCHEME=get_zcopy` | The NIC accesses GPU memory directly, with no host bounce. |
| `UCX_IB_GID_INDEX=1`, `UCX_UD_VERBS_ETH_DGID_CHECK=n` | Same as Section 1. |
| Mount the nosrq UCX prefix at both `/nixl-prefix` and `/prefix` | `libnixl` and UCX have `/prefix/...` compiled in for plugin and module discovery. |
| `LD_LIBRARY_PATH=/nixl-prefix/lib:/nixl-prefix/lib/ucx:…`, `UCX_MODULE_DIR=/nixl-prefix/lib/ucx` | Otherwise the image's bundled UCX 1.22 is loaded, which has no working `rc_verbs` on ionic and falls back to TCP/UD. Check that the log shows `UCX Version 1.18.1 (loaded from /nixl-prefix/lib/libucp.so.0)`. |
| `PYTHONPATH=/nixlpy` (NIXL Python bindings built against the same prefix) | Keeps the bindings ABI-matched to the mounted `libnixl`/UCX. |

### Known issues

- `ud_verbs` stays in use as the keepalive lane (`ka(ud_verbs)`). UCX is
  built with assertions enabled, so an endpoint torn down after an error can
  abort a worker at `ud_ep.c:285`. Mitigations not yet validated:
  `UCX_KEEPALIVE_INTERVAL=inf`, or rebuild the prefix with
  `--disable-assertions`.
- vLLM's `kv_load_failure_policy=recompute` hides transfer failures behind
  correct accuracy. Check that successful transfers > 0 in the decode/prefill
  `KV Transfer metrics` lines before trusting a pass.
