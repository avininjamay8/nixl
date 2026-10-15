#!/usr/bin/env python3
"""Ionic no-SRQ RC WAR, applied to UCX v1.18.1 and v1.22.0 (cwd = ucx root).

MoRI proves RC QPs work with per-QP RQ (ibv_post_recv), no SRQ.
Stock UCX rc_verbs requires SRQ. This WAR:
  1) Enumerate RC without max_srq gate
  2) On ibv_create_srq fail: continue with srq=NULL
  3) QP max_recv_wr = rx queue_len
  4) After each RC QP create: prepost ibv_post_recv to that QP
  5) Keep AM caps (AM must work for NIXL/UCP control)
"""
from pathlib import Path
import sys


def must_replace(path: Path, old: str, new: str, label: str):
    t = path.read_text()
    if old not in t:
        raise SystemExit(f"FAIL {label}: pattern not in {path}")
    path.write_text(t.replace(old, new, 1))
    print(f"OK {label}")


def main():
    # 0) ensure strncmp available for ionic name check
    p = Path("src/uct/ib/rc/verbs/rc_verbs_iface.c")
    t = p.read_text()
    if "#include <string.h>" not in t:
        p.write_text(t.replace("#include ", "#include <string.h>\n#include ", 1))
        print("OK string.h include")
    else:
        print("OK string.h include (exists)")

    # 1) ib_device.c — allow max_srq==0
    must_replace(
        Path("src/uct/ib/base/ib_device.c"),
        """    if (flags & UCT_IB_DEVICE_FLAG_SRQ) {
        if (IBV_DEV_ATTR(dev, max_srq) == 0) {
            ucs_trace("%s:%d does not support SRQ", uct_ib_device_name(dev),
                      port_num);
            return UCS_ERR_UNSUPPORTED;
        }
    }""",
        """    if (flags & UCT_IB_DEVICE_FLAG_SRQ) {
        if (IBV_DEV_ATTR(dev, max_srq) == 0) {
            /* Ionic WAR: max_srq=0 but RC QP + per-QP RQ works (MoRI). */
            ucs_debug("%s:%d max_srq=0 — allowing (ionic no-SRQ RC WAR)",
                      uct_ib_device_name(dev), port_num);
        }
    }""",
        "ib_device max_srq gate",
    )

    # 2) rc_verbs query — no SRQ flag
    must_replace(
        Path("src/uct/ib/rc/verbs/rc_verbs_iface.c"),
        """    return uct_ib_device_query_ports(&ib_md->dev, UCT_IB_DEVICE_FLAG_SRQ,
                                     tl_devices_p, num_tl_devices_p);""",
        """    /* Ionic WAR: enumerate RC ports without requiring SRQ */
    return uct_ib_device_query_ports(&ib_md->dev, 0,
                                     tl_devices_p, num_tl_devices_p);""",
        "rc_verbs query ports",
    )

    # 3a) Base init_rx: soft-fail create_srq (covers perftest + all RC TLs)
    must_replace(
        Path("src/uct/ib/rc/base/rc_iface.c"),
        """    srq                          = ibv_create_srq(pd, &srq_init_attr);
    if (srq == NULL) {
        uct_ib_check_memlock_limit_msg(pd->context, UCS_LOG_LEVEL_ERROR,
                                       "ibv_create_srq()");
        return UCS_ERR_IO_ERROR;
    }
    iface->rx.srq.quota          = srq_init_attr.attr.max_wr;
    *srq_p                       = srq;

    return UCS_OK;
}""",
        """    srq                          = ibv_create_srq(pd, &srq_init_attr);
    if (srq == NULL) {
        /* Ionic WAR: max_srq=0 — continue with srq=NULL; caller uses per-QP RQ */
        uct_ib_check_memlock_limit_msg(pd->context, UCS_LOG_LEVEL_WARN,
                                       "ibv_create_srq() — continuing no-SRQ");
        iface->rx.srq.quota      = 0;
        iface->rx.srq.available  = 0;
        *srq_p                   = NULL;
        return UCS_OK;
    }
    iface->rx.srq.quota          = srq_init_attr.attr.max_wr;
    *srq_p                       = srq;

    return UCS_OK;
}""",
        "rc_iface init_rx soft-fail create_srq",
    )

    # 3b) verbs init_rx: ensure per-QP quota zero when srq NULL
    must_replace(
        Path("src/uct/ib/rc/verbs/rc_verbs_iface.c"),
        """static ucs_status_t
uct_rc_iface_verbs_init_rx(uct_rc_iface_t *rc_iface,
                           const uct_rc_iface_common_config_t *config)
{
    uct_rc_verbs_iface_t *iface = ucs_derived_of(rc_iface, uct_rc_verbs_iface_t);

    return uct_rc_iface_init_rx(rc_iface, config, &iface->srq);
}""",
        """static ucs_status_t
uct_rc_iface_verbs_init_rx(uct_rc_iface_t *rc_iface,
                           const uct_rc_iface_common_config_t *config)
{
    uct_rc_verbs_iface_t *iface = ucs_derived_of(rc_iface, uct_rc_verbs_iface_t);
    ucs_status_t status;

    status = uct_rc_iface_init_rx(rc_iface, config, &iface->srq);
    if (status != UCS_OK || iface->srq == NULL) {
        ucs_warn("%s: no SRQ — per-QP RQ rc_verbs (ionic WAR)",
                 uct_ib_device_name(uct_ib_iface_device(&rc_iface->super)));
        iface->srq                 = NULL;
        rc_iface->rx.srq.quota     = 0;
        rc_iface->rx.srq.available = 0;
        return UCS_OK;
    }
    return UCS_OK;
}""",
        "rc_verbs init_rx per-QP WAR",
    )

    # 4) cleanup_rx null-safe
    must_replace(
        Path("src/uct/ib/rc/verbs/rc_verbs_iface.c"),
        """void uct_rc_iface_verbs_cleanup_rx(uct_rc_iface_t *rc_iface)
{
    uct_rc_verbs_iface_t *iface = ucs_derived_of(rc_iface, uct_rc_verbs_iface_t);

    /* TODO flush RX buffers */
    uct_ib_destroy_srq(iface->srq);
}""",
        """void uct_rc_iface_verbs_cleanup_rx(uct_rc_iface_t *rc_iface)
{
    uct_rc_verbs_iface_t *iface = ucs_derived_of(rc_iface, uct_rc_verbs_iface_t);

    /* TODO flush RX buffers */
    if (iface->srq != NULL) {
        uct_ib_destroy_srq(iface->srq);
        iface->srq = NULL;
    }
}""",
        "rc_verbs cleanup_rx null",
    )

    # 5) fill_attr: per-QP max_recv_wr when no SRQ
    must_replace(
        Path("src/uct/ib/rc/base/rc_iface.c"),
        """void uct_rc_iface_fill_attr(uct_rc_iface_t *iface, uct_ib_qp_attr_t *attr,
                            unsigned max_send_wr, struct ibv_srq *srq)
{
    attr->srq                        = srq;
    attr->cap.max_send_wr            = max_send_wr;
    attr->cap.max_recv_wr            = 0;
    attr->cap.max_send_sge           = iface->config.tx_min_sge;
    attr->cap.max_recv_sge           = 1;""",
        """void uct_rc_iface_fill_attr(uct_rc_iface_t *iface, uct_ib_qp_attr_t *attr,
                            unsigned max_send_wr, struct ibv_srq *srq)
{
    attr->srq                        = srq;
    attr->cap.max_send_wr            = max_send_wr;
    /* Ionic WAR: no SRQ → MoRI-style per-QP RQ (modest cap) */
    attr->cap.max_recv_wr            = (srq == NULL) ? 128 : 0;
    attr->cap.max_send_sge           = iface->config.tx_min_sge;
    attr->cap.max_recv_sge           = 1;""",
        "fill_attr per-QP max_recv_wr",
    )

    # 6) post_recv_always: ibv_post_recv path is QP-scoped — keep srq path;
    #    add helper used from ep init. Patch ep to prepost to QP.
    # Add function before common_prepost_recvs
    p = Path("src/uct/ib/rc/verbs/rc_verbs_iface.c")
    t = p.read_text()
    helper = """
/* Ionic WAR: prepost receives onto a specific RC QP (no SRQ). */
ucs_status_t
uct_rc_verbs_iface_prepost_qp_recvs(uct_rc_verbs_iface_t *iface, struct ibv_qp *qp,
                                    unsigned count)
{
    struct ibv_recv_wr *bad_wr;
    uct_ib_recv_wr_t *wrs;
    unsigned n, posted = 0;
    int ret;

    if ((qp == NULL) || (count == 0)) {
        return UCS_OK;
    }

    while (posted < count) {
        n = ucs_min(count - posted, iface->super.super.config.rx_max_batch);
        if (n == 0) {
            n = 1;
        }
        wrs = ucs_alloca(sizeof(*wrs) * n);
        n = uct_ib_iface_prepare_rx_wrs(&iface->super.super, &iface->super.rx.mp,
                                        wrs, n);
        if (n == 0) {
            break;
        }
        ret = ibv_post_recv(qp, &wrs[0].ibwr, &bad_wr);
        if (ret != 0) {
            ucs_warn("ionic WAR: ibv_post_recv(qp) failed after %u: %m", posted);
            break;
        }
        posted += n;
    }
    if (posted == 0) {
        ucs_error("ionic WAR: posted 0 recvs on QP 0x%x", qp->qp_num);
        return UCS_ERR_IO_ERROR;
    }
    ucs_debug("ionic WAR: preposted %u recvs on QP 0x%x", posted, qp->qp_num);
    return UCS_OK;
}

"""
    if "uct_rc_verbs_iface_prepost_qp_recvs" not in t:
        anchor = "ucs_status_t\nuct_rc_verbs_iface_common_prepost_recvs(uct_rc_verbs_iface_t *iface)\n"
        if anchor not in t:
            raise SystemExit("FAIL: cannot find common_prepost_recvs for helper insert")
        p.write_text(t.replace(anchor, helper + anchor, 1))
        print("OK prepost_qp_recvs helper")
    else:
        print("OK prepost_qp_recvs helper (exists)")

    # common_prepost_recvs: no-op when no SRQ (progress_enable otherwise fails)
    must_replace(
        Path("src/uct/ib/rc/verbs/rc_verbs_iface.c"),
        """ucs_status_t
uct_rc_verbs_iface_common_prepost_recvs(uct_rc_verbs_iface_t *iface)
{
    if (iface->super.rx.srq.quota == 0) {
        return UCS_OK;
    }

    iface->super.rx.srq.available = iface->super.rx.srq.quota;
    iface->super.rx.srq.quota     = 0;
    while (iface->super.rx.srq.available > 0) {
        if (uct_rc_verbs_iface_post_recv_common(iface, 1) == 0) {
            ucs_error("failed to post receives");
            return UCS_ERR_NO_MEMORY;
        }
    }

    return UCS_OK;
}""",
        """ucs_status_t
uct_rc_verbs_iface_common_prepost_recvs(uct_rc_verbs_iface_t *iface)
{
    if (iface->srq == NULL) {
        /* Ionic WAR: receives live on each QP, not a shared SRQ */
        iface->super.rx.srq.quota     = 0;
        iface->super.rx.srq.available = 0;
        return UCS_OK;
    }

    if (iface->super.rx.srq.quota == 0) {
        return UCS_OK;
    }

    iface->super.rx.srq.available = iface->super.rx.srq.quota;
    iface->super.rx.srq.quota     = 0;
    while (iface->super.rx.srq.available > 0) {
        if (uct_rc_verbs_iface_post_recv_common(iface, 1) == 0) {
            ucs_error("failed to post receives");
            return UCS_ERR_NO_MEMORY;
        }
    }

    return UCS_OK;
}""",
        "common_prepost no-SRQ no-op",
    )

    # Declare in header
    h = Path("src/uct/ib/rc/verbs/rc_verbs_impl.h")
    ht = h.read_text()
    decl = """ucs_status_t
uct_rc_verbs_iface_prepost_qp_recvs(uct_rc_verbs_iface_t *iface, struct ibv_qp *qp,
                                    unsigned count);

"""
    if "uct_rc_verbs_iface_prepost_qp_recvs" not in ht:
        a = "ucs_status_t\nuct_rc_verbs_iface_common_prepost_recvs(uct_rc_verbs_iface_t *iface);\n"
        if a not in ht:
            raise SystemExit("FAIL: header anchor missing")
        h.write_text(ht.replace(a, decl + a, 1))
        print("OK header decl")
    else:
        print("OK header decl (exists)")

    # 7) EP init: after QP create, if no SRQ, prepost to QP
    must_replace(
        Path("src/uct/ib/rc/verbs/rc_verbs_ep.c"),
        """    status = uct_rc_verbs_iface_common_prepost_recvs(iface);
    if (status != UCS_OK) {
        goto err_remove_qp;
    }

    uct_rc_txqp_available_set(&self->super.txqp, iface->config.tx_max_wr);""",
        """    if (iface->srq != NULL) {
        status = uct_rc_verbs_iface_common_prepost_recvs(iface);
        if (status != UCS_OK) {
            goto err_remove_qp;
        }
    } else {
        /* Ionic WAR: fill per-QP RQ once (no replenish yet). Single-rail
         * runs need enough credits for wireup + first xfer. */
        unsigned npost = 128;
        status = uct_rc_verbs_iface_prepost_qp_recvs(iface, self->qp, npost);
        if (status != UCS_OK) {
            goto err_remove_qp;
        }
        ucs_warn("ionic WAR: QP 0x%x preposted %u recvs (no SRQ)",
                 self->qp->qp_num, npost);
    }

    uct_rc_txqp_available_set(&self->super.txqp, iface->config.tx_max_wr);""",
        "ep prepost per-QP RQ",
    )

    # 8) post_recv_always: if srq NULL, no-op (per-QP already primed; avoid fatal)
    must_replace(
        Path("src/uct/ib/rc/verbs/rc_verbs_iface.c"),
        """    ret = ibv_post_srq_recv(iface->srq, &wrs[0].ibwr, &bad_wr);
    if (ret != 0) {
        ucs_fatal("ibv_post_srq_recv() returned %d: %m", ret);
    }
    iface->super.rx.srq.available -= count;

    return count;
}""",
        """    if (iface->srq == NULL) {
        /* Ionic WAR: RQ is per-QP; skip shared SRQ replenish */
        return 0;
    }

    ret = ibv_post_srq_recv(iface->srq, &wrs[0].ibwr, &bad_wr);
    if (ret != 0) {
        ucs_fatal("ibv_post_srq_recv() returned %d: %m", ret);
    }
    iface->super.rx.srq.available -= count;

    return count;
}""",
        "post_recv_always no-SRQ skip",
    )

    # 9) poll_rx_common: replenish per-QP RQ (else 16/64 credits die after wireup)
    must_replace(
        Path("src/uct/ib/rc/verbs/rc_verbs_impl.h"),
        """        uct_rc_verbs_iface_handle_am(&iface->super, hdr, wc[i].wr_id, wc[i].qp_num,
                                     wc[i].byte_len, wc[i].imm_data, wc[i].slid);
    }
    iface->super.rx.srq.available += num_wcs;
    UCS_STATS_UPDATE_COUNTER(iface->super.super.stats,
                             UCT_IB_IFACE_STAT_RX_COMPLETION, num_wcs);

out:
    uct_rc_verbs_iface_post_recv_common(iface, 0);
    return num_wcs;
}""",
        """        uct_rc_verbs_iface_handle_am(&iface->super, hdr, wc[i].wr_id, wc[i].qp_num,
                                     wc[i].byte_len, wc[i].imm_data, wc[i].slid);
        if (iface->srq == NULL) {
            /* Ionic WAR: repost one recv onto the QP that completed */
            uct_rc_ep_t *rc_ep = uct_rc_iface_lookup_ep(&iface->super, wc[i].qp_num);
            if (rc_ep != NULL) {
                uct_rc_verbs_ep_t *vep = ucs_derived_of(rc_ep, uct_rc_verbs_ep_t);
                (void)uct_rc_verbs_iface_prepost_qp_recvs(iface, vep->qp, 1);
            }
        }
    }
    if (iface->srq != NULL) {
        iface->super.rx.srq.available += num_wcs;
    }
    UCS_STATS_UPDATE_COUNTER(iface->super.super.stats,
                             UCT_IB_IFACE_STAT_RX_COMPLETION, num_wcs);

out:
    if (iface->srq != NULL) {
        uct_rc_verbs_iface_post_recv_common(iface, 0);
    }
    return num_wcs;
}""",
        "poll_rx per-QP replenish",
    )

    # 10) KEEP AM on rc_verbs with per-QP RQ (MoRI-style). Do NOT strip AM —
    #     RMA-only left UCP with no AM lane → perftest hang / NIXL disconnect.

    print("ALL PATCHES APPLIED (per-QP RQ WAR, AM kept)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
