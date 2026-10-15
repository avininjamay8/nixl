#!/usr/bin/env python3
"""UCX 1.22: do not RDMA-READ into ROCm memory.

ionic completes an RDMA READ whose local sink is GPU memory, but the data
never lands there (the buffer stays at the pre-fill sentinel). An RDMA WRITE
into that same GPU registration does land. Refuse get/zcopy, get/bcopy and
rndv-get when the local buffer is ROCm so ucp_get falls through to rendezvous
RTR, where the peer RDMA WRITEs into the local buffer. Needs
UCX_RMA_PPLN_ENABLE=y on this platform (RMA rendezvous is otherwise compiled
out unless the CPU is NVIDIA Vera).
"""
from pathlib import Path
import sys

SINK_GUARD = (
    "    /* ionic RDMA READ responses are not placed into GPU memory.\n"
    "     * RDMA WRITE into the same registration is. Refuse a GPU sink so\n"
    "     * GET is served by rendezvous RTR (peer PUT). */\n"
    "    if (init_params->select_param->mem_type == UCS_MEMORY_TYPE_ROCM) {\n"
    "        return;\n"
    "    }\n\n"
)

EDITS = [
    (
        Path("src/ucp/rma/get_offload.c"),
        2,
        "    if (!ucp_proto_init_check_op(init_params, UCS_BIT(UCP_OP_ID_GET))) {\n"
        "        return;\n"
        "    }\n\n",
        "    if (!ucp_proto_init_check_op(init_params, UCS_BIT(UCP_OP_ID_GET))) {\n"
        "        return;\n"
        "    }\n\n" + SINK_GUARD,
    ),
    (
        Path("src/ucp/rndv/rndv_get.c"),
        1,
        "    if (!ucp_proto_rndv_op_check(init_params, UCP_OP_ID_RNDV_RECV,\n",
        SINK_GUARD
        + "    if (!ucp_proto_rndv_op_check(init_params, UCP_OP_ID_RNDV_RECV,\n",
    ),
]


def main():
    for path, n, old, new in EDITS:
        text = path.read_text()
        if text.count(old) != n:
            raise SystemExit(f"FAIL {path}: anchor count {text.count(old)} != {n}")
        path.write_text(text.replace(old, new))
        print(f"OK {path} x{n}")
    print("ALL ROCM GET-VIA-PUT PATCHES APPLIED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
