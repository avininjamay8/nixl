#!/usr/bin/env python3
"""Plot nixlbench READ vs WRITE bandwidth from run_crossNode_ucx.sh output.

    plot_nixlbench_bw.py logs/read_<job>.bw logs/write_<job>.bw out.svg
"""
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load(path):
    rows = [line.split() for line in open(path) if line.strip()]
    return [int(r[0]) for r in rows], [float(r[1]) for r in rows]


def label(n):
    for unit, size in (("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if n >= size:
            return f"{n // size} {unit}"
    return f"{n} B"


def main(read_bw, write_bw, out):
    fig, ax = plt.subplots(figsize=(10.4, 5.6))
    for path, name, marker in ((read_bw, "READ", "o"), (write_bw, "WRITE", "s")):
        size, gbps = load(path)
        ax.plot(size, gbps, marker=marker, linewidth=2, label=name)
    ax.set_xscale("log", base=2)
    ax.set_xticks(size[::2], [label(s) for s in size[::2]], rotation=30)
    ax.set_xlabel("Block size")
    ax.set_ylabel("Bandwidth (GB/s)")
    ax.set_title("nixlbench VRAM -> VRAM, UCX 1.22.0 rc_verbs, 2 nodes, 1 ionic rail")
    ax.grid(True, which="major", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(out, metadata={"Date": None})


if __name__ == "__main__":
    main(*sys.argv[1:4])
