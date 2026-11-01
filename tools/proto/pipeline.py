"""Key-decode CV pipeline — Python prototype of docs/ALGORITHM.md.

Every step boundary is a pure array in / array out so the Swift port can
reimplement step-for-step. Deviations from the spec defaults are marked with
`DEVIATION:` comments and collected in REPORT.md.

Coordinate conventions
----------------------
Corrected image: x right, y down, 2600x1640, PX_PER_IN px/inch.
Rotated blob frame (per blade_geometry()): raw u = du @ e1 (rebased so that
bin 0 == u_rebased 0; store u_off for drawing), v = du @ e2 with
e2 = perp(e1). 'vtop' = smaller v side, 'vbot' = larger v side (v is y-down
like). The KEY direction (bow->tip) is d_raw = +1 (bow at low bins) or
-1 (bow at high bins); it is a separate datum, never baked into the axes.
"""
from __future__ import annotations

import numpy as np
import cv2

# ---------------------------------------------------------------- defaults
W_OUT = 2600
H_OUT = 1640                      # round(2600*53.98/85.6)
PX_PER_MM = W_OUT / 85.60
PX_PER_IN = PX_PER_MM * 25.4

MARGIN_MM = 2.0                   # ignore ring inside corrected card
BAND_MM = 1.5                     # background band just inside the margin
HEAD_FACTOR = 1.9                 # head width > 1.9 x blade median
MAD_CLIP = 2.5                    # spine-fit robust reclip
SCAN_MAX_IN = 0.060               # offset auto-align scan
SCAN_STEP_IN = 0.004
WIN_IN = 0.012                    # depth window half-width (updated by parent
WIN_SPACING_FRAC = 0.25           # 2026-10-31: was 0.030/0.45; see REPORT)
M_HIGH = 0.35                     # table-margin flag thresholds
M_LOW = 0.50
RMS_FACTOR = 0.25                 # profile-noise flag: 0.25 x increment
MIN_AREA_FRAC = 0.015             # key blob min area (card fraction)
MIN_ASPECT = 2.5                  # key blob min aspect
BLADE_RANGE_IN = (0.5, 1.9)       # sane shoulder->tip length
COUNT_FRAC_TRIM = 0.05            # column-count trim (5% of median width px)
HEAD_CAP_TOL_IN = 0.30            # DEVIATION: narrow end-cap allowed before head run


class Fail(Exception):
    """Fail -> manual path (per spec 'Failure' section)."""


def in2px(x_in: float) -> float:
    return x_in * PX_PER_IN


def mm2px(x_mm: float) -> float:
    return x_mm * PX_PER_MM


# ---------------------------------------------------------------- step 1
def order_quad(pts) -> np.ndarray:
    """Sort 4 pts into TL,TR,BR,BL (long edge first, y-down CW). Per spec 1."""
    p = np.asarray(pts, dtype=float).reshape(4, 2)
    c = p.mean(0)
    ang = np.arctan2(p[:, 1] - c[1], p[:, 0] - c[0])
    p = p[np.argsort(ang)]                    # y-down: ascending angle = visual CW
    e = [np.linalg.norm(p[(i + 1) % 4] - p[i]) for i in range(4)]
    if e[2] > e[0]:                           # make edge 0 a long edge
        p = np.roll(p, 2, axis=0)
    x, y = p[:, 0], p[:, 1]
    shoelace = np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y)
    if shoelace < 0:                          # y-down TL,TR,BR,BL has shoelace > 0
        p = p[[0, 3, 2, 1]]                   # swap TR/BL
    return p


def quad_sanity(quad, img_shape) -> bool:
    """Auto-detect sanity: area frac >= 15%, edge-mean aspect in [1.30, 1.90]."""
    q = np.asarray(quad, float)
    area = 0.5 * abs(np.sum(q[:, 0] * np.roll(q[:, 1], -1) - np.roll(q[:, 0], -1) * q[:, 1]))
    h, w = img_shape[:2]
    if area / (h * w) < 0.15:
        return False
    e = [np.linalg.norm(q[(i + 1) % 4] - q[i]) for i in range(4)]
    return 1.30 <= ((e[0] + e[2]) / 2) / max((e[1] + e[3]) / 2, 1e-6) <= 1.90


def correct(img, quad):
    """Card quad -> straight 2600x1640 top-down view (spec step 1)."""
    g = img[..., 0] if img.ndim == 3 else img
    q = order_quad(quad).astype(np.float32)
    dst = np.array([[0, 0], [W_OUT, 0], [W_OUT, H_OUT], [0, H_OUT]], np.float32)
    M = cv2.getPerspectiveTransform(q, dst)
    return cv2.warpPerspective(g, M, (W_OUT, H_OUT), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_REPLICATE)


# ---------------------------------------------------------------- step 2
def background_level(card):
    m = int(round(mm2px(MARGIN_MM)))
    b = int(round(mm2px(MARGIN_MM + BAND_MM)))
    band = np.concatenate([card[m:b, :].ravel(), card[-b:-m, :].ravel(),
                           card[:, m:b].ravel(), card[:, -b:-m].ravel()])
    return float(np.median(band))


def key_mask(card, B=None):
    """Spec step 2: margin ignore -> B -> |g-B| -> Otsu -> close/open ->
    largest CC -> sanity -> hole fill. Returns (mask uint8, info)."""
    info = {}
    if B is None:
        B = background_level(card)
    info["B"] = B
    d = cv2.absdiff(card, np.full_like(card, int(round(B))))
    m = int(round(mm2px(MARGIN_MM)))
    d[:m, :] = 0; d[-m:, :] = 0; d[:, :m] = 0; d[:, -m:] = 0
    t, fg = cv2.threshold(d, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    info["otsu"] = t
    k = np.ones((3, 3), np.uint8)
    fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, k, iterations=2)
    fg = cv2.morphologyEx(fg, cv2.MORPH_OPEN, k, iterations=1)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(fg, 8)
    if n <= 1:
        raise Fail("mask-empty")
    i = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    blob = ((lab == i).astype(np.uint8)) * 255
    area_frac = stats[i, cv2.CC_STAT_AREA] / float(W_OUT * H_OUT)
    info["area_frac"] = area_frac
    if area_frac < MIN_AREA_FRAC:
        raise Fail("blob-too-small")
    ev = np.linalg.eigvalsh(_cov2(blob.astype(bool)))[::-1]
    aspect = float(np.sqrt(ev[0] / max(ev[1], 1e-9)))    # DEVIATION: eigenvalue-ratio
    info["aspect"] = aspect                              #   basis (not rotated bbox)
    if aspect < MIN_ASPECT:
        raise Fail("blob-aspect")
    blob = fill_holes(blob)
    return blob, info


def fill_holes(mask):
    h, w = mask.shape
    ff = mask.copy()
    mm = np.zeros((h + 2, w + 2), np.uint8)
    cv2.floodFill(ff, mm, (0, 0), 255)
    return cv2.bitwise_or(mask, cv2.bitwise_not(ff))


def _cov2(boolmask):
    ys, xs = np.nonzero(boolmask)
    pts = np.column_stack([xs, ys]).astype(np.float64)
    return np.cov(pts.T)


# ---------------------------------------------------------------- step 3
def robust_line(x, y, clip=MAD_CLIP):
    """LS fit, drop |resid| > clip*MAD once, refit. Returns (a, b, rms)."""
    a, b = np.polyfit(x, y, 1)
    r = y - (a * x + b)
    mad = np.median(np.abs(r - np.median(r)))
    keep = np.abs(r) <= max(clip * mad, 1e-6)
    if keep.sum() >= max(10, 0.2 * len(x)):
        a, b = np.polyfit(x[keep], y[keep], 1)
        r = y - (a * x + b)
    return float(a), float(b), float(np.sqrt(np.mean(r * r)))


def blade_geometry(mask):
    """Spec step 3: PCA axis, column profiles, head, spine side, shoulder,
    tip. All arrays indexed by rebased column bin (0..nb-1 slice lo..hi)."""
    ys, xs = np.nonzero(mask > 0)
    pts = np.column_stack([xs, ys]).astype(np.float64)
    c = pts.mean(0)
    cov = np.cov((pts - c).T)
    ev, evec = np.linalg.eigh(cov)
    e1 = evec[:, int(np.argmax(ev))]
    e2 = np.array([-e1[1], e1[0]])

    du = pts - c
    u = du @ e1
    v = du @ e2
    u_off = int(np.floor(u.min()))
    ub = np.round(u).astype(np.int64) - u_off
    v_off = int(np.floor(v.min())) - 1
    vr = np.round(v).astype(np.int64) - v_off      # only used for min/max scatter
    nb = int(ub.max()) + 1
    vtop = np.full(nb, np.iinfo(np.int64).max)
    vbot = np.full(nb, np.iinfo(np.int64).min)
    np.minimum.at(vtop, ub, vr)
    np.maximum.at(vbot, ub, vr)
    cnt = np.bincount(ub, minlength=nb).astype(np.float64)

    present = cnt > 0
    w = np.where(present, vbot - vtop, np.nan).astype(float)
    med_w = float(np.nanmedian(w[present]))
    ok = present & (cnt >= COUNT_FRAC_TRIM * med_w)
    lo = int(np.argmax(ok)); hi = int(nb - 1 - np.argmax(ok[::-1]))
    bins = np.arange(lo, hi + 1)
    ws = w[lo:hi + 1]
    # DEVIATION: spec trims only the ends; interior dead columns are tolerated
    # here and flagged per-cut ('empty column' flag).

    # ---- head: contiguous wide run anchored at one end ----
    thr = HEAD_FACTOR * med_w
    cap_px = in2px(HEAD_CAP_TOL_IN)
    head = None
    for side in ("low", "high"):
        seq = np.arange(len(bins)) if side == "low" else np.arange(len(bins) - 1, -1, -1)
        j = None
        for cap, jj in enumerate(seq):
            if ws[jj] > thr:
                j = jj
                break
            if cap >= len(bins) - 1:
                break
        if j is None or min(j, len(bins) - 1 - j) > cap_px:
            continue
        if side == "low":
            end = j
            while True:
                dip = next((m for m in range(end + 1, min(end + 4, len(bins))) if ws[m] > thr), None)
                if dip is None:
                    break
                if ws[end + 1: dip].size and np.nanmax(ws[end + 1: dip]) < 1.6 * med_w:
                    break                            # genuine separation -> blade
                end = dip
            head = dict(side=side, start=j, end=end)
        else:
            end = j
            while True:
                dip = next((m for m in range(end - 1, max(end - 4, -1), -1) if ws[m] > thr), None)
                if dip is None:
                    break
                if ws[dip + 1: end].size and np.nanmax(ws[dip + 1: end]) < 1.6 * med_w:
                    break
                end = dip
            head = dict(side=side, start=end, end=j)

    head_present = head is not None
    if head_present:
        d_raw = 1 if head["side"] == "low" else -1   # key direction bins axis
        u_s = int(bins[head["end"] + 1]) if d_raw > 0 else int(bins[head["start"] - 1])
        u_t = int(bins[-1]) if d_raw > 0 else int(bins[0])
        band = (bins >= u_s) if d_raw > 0 else (bins <= u_s)
    else:
        d_raw = 1                                    # provisional; 3f resolves later
        u_s, u_t = int(bins[0]), int(bins[-1])
        band = np.ones(len(bins), bool)

    # ---- spine side: robust line over blade band on each side ----
    xb = bins[band].astype(float)
    fa = robust_line(xb, vtop[lo:hi + 1][band].astype(float))
    fb = robust_line(xb, vbot[lo:hi + 1][band].astype(float))
    if fa[2] <= fb[2]:
        spine_side, cut_side = "top", "bot"
        sa, sb, srms, crms = fa[0], fa[1], fa[2], fb[2]
    else:
        spine_side, cut_side = "bot", "top"
        sa, sb, srms, crms = fb[0], fb[1], fb[2], fa[2]

    blade_len_in = abs(u_t - u_s) / PX_PER_IN
    warn = None if BLADE_RANGE_IN[0] <= blade_len_in <= BLADE_RANGE_IN[1] \
        else f"blade-len {blade_len_in:.3f}in"

    return dict(c=c, e1=e1, e2=e2, u_off=u_off, v_off=v_off,
                bins=bins, lo=lo, hi=hi,
                vtop=vtop[lo:hi + 1], vbot=vbot[lo:hi + 1], cnt=cnt[lo:hi + 1],
                w=ws, med_w=med_w, band=band,
                head=head, head_present=head_present, d_raw=d_raw,
                u_s=u_s, u_t=u_t, spine_side=spine_side, cut_side=cut_side,
                spine_a=sa, spine_b=sb, spine_rms=srms, cut_rms=crms,
                blade_len_in=blade_len_in, warn=warn)


# ---------------------------------------------------------------- step 4/5
def depth_at(g, u_bin):
    """depth_px at a rebased column: extreme cut-side boundary minus spine fit.
    vtop/vbot/spine-line are all in the same rebased-v space, so the offsets
    cancel; no conversion needed."""
    j = int(round(u_bin)) - g["lo"]
    if j < 0 or j >= len(g["bins"]) or g["cnt"][j] <= 0:
        return np.nan
    if g["cut_side"] == "bot":
        ev = float(g["vbot"][j])
    else:
        ev = float(g["vtop"][j])
    sf = g["spine_a"] * u_bin + g["spine_b"]
    d = (ev - sf) if g["cut_side"] == "bot" else (sf - ev)
    return float(d)


def measure_window(g, u_center, h_px):
    lo_i = int(np.floor(u_center - h_px)); hi_i = int(np.ceil(u_center + h_px))
    vals = []
    empty = False
    for u in range(lo_i, hi_i + 1):
        d = depth_at(g, u)
        if np.isnan(d):
            empty = True
        else:
            vals.append(d)
    if not vals:
        return np.nan, np.nan, True
    va = np.asarray(vals, float)
    return float(np.median(va)), float(np.sqrt(np.mean((va - va.mean()) ** 2))), empty


def scan_align(g, sysd, d_raw, anchor=None, scan=True):
    """Offset auto-align + per-cut depths for one key direction.
    DEVIATION: spec says *maximize* summed depth at cut centers; with root
    depth = |v_edge - v_spine| cuts are MINIMA (depth measured from spine),
    so we MINIMIZE. Equivalent to the spec's intent under notch depth."""
    table = np.asarray(sysd["depthsIn"], float)
    first = float(sysd["firstCutIn"]); spac = float(sysd["spacingIn"])
    n = int(sysd["pinCount"])
    if anchor is None:
        anchor = g["u_s"]
    h_px = in2px(min(WIN_IN, WIN_SPACING_FRAC * spac))

    def centers(dv):
        return [anchor + d_raw * (in2px(first + i * spac) + dv * PX_PER_IN)
                for i in range(n)]

    deltas = np.arange(-SCAN_MAX_IN, SCAN_MAX_IN + 1e-9, SCAN_STEP_IN) if scan else np.array([0.0])
    best = None
    for dv in deltas:
        tot, bad = 0.0, 0
        cs = centers(dv)
        for uc in cs:
            d = depth_at(g, uc)
            if np.isnan(d):
                bad += 1
            else:
                tot += d
        if bad == n:
            continue
        score = tot + bad * 1e6
        if best is None or score < best[0]:
            best = (score, dv)
    delta = best[1] if best is not None else 0.0

    cuts = []
    for uc in centers(delta):
        med, rms, empty = measure_window(g, uc, h_px)
        if np.isnan(med):
            cuts.append(dict(u=uc, depth_in=np.nan, digit=None, margin=np.inf,
                             conf="empty", rms=np.nan, empty=True,
                             rms_flag=False, flagged=True))
            continue
        depth_in = med / PX_PER_IN
        resid = np.abs(table - depth_in)
        j = int(np.argmin(resid)); m = float(resid[j] / float(sysd["incrementIn"]))
        conf = "high" if m <= M_HIGH else ("low" if m <= M_LOW else "out")
        rms_flag = rms > RMS_FACTOR * in2px(float(sysd["incrementIn"]))
        cuts.append(dict(u=uc, depth_in=depth_in, digit=j, margin=m, conf=conf,
                         rms=rms, empty=empty, rms_flag=bool(rms_flag),
                         flagged=bool(conf != "high" or rms_flag or empty)))
    dd = np.asarray([c["depth_in"] for c in cuts if np.isfinite(c["depth_in"])])
    if len(dd):
        nearest = table[np.argmin(np.abs(table[None, :] - dd[:, None]), axis=1)]
        fit = float(np.sqrt(np.mean((dd - nearest) ** 2)))
    else:
        fit = np.inf
    fit += 10.0 * (n - len(dd)) / n          # penalize directions losing cuts
    return delta, cuts, fit


# ---------------------------------------------------------------- top level
def decode(photo, quad, sysd, sanity_check=True):
    """photo (uint8 gray|bgr) + quad -> code + per-cut detail (spec steps 1-5)."""
    out = dict(status="ok", warnings=[])
    q = order_quad(quad)
    if sanity_check and not quad_sanity(q, photo.shape):
        out.update(status="fail", reason="quad-insane")
        return out
    card = correct(photo, q)
    try:
        mask, minfo = key_mask(card)
    except Fail as e:
        out.update(status="fail", reason=str(e))
        return out

    g = blade_geometry(mask)
    if g["warn"]:
        out["warnings"].append(g["warn"])

    tried = []
    if g["head_present"]:
        cand = [(g["d_raw"], g["u_s"])]
    else:
        cand = [(1, int(g["bins"][0])), (-1, int(g["bins"][-1]))]   # spec 3f
    results = []
    for d_raw, anchor in cand:
        delta, cuts, fit = scan_align(g, sysd, d_raw, anchor)
        tried.append(dict(d_raw=d_raw, fit=fit, delta_in=delta))
        results.append((fit, d_raw, delta, cuts))
    results.sort(key=lambda r: r[0])
    fit, d_raw, delta, cuts = results[0]

    if any(c["digit"] is None for c in cuts):
        code = None
    else:
        code = "-".join(str(c["digit"]) for c in cuts)   # bow-side cut first
    out.update(code=code, cuts=cuts, d_raw=d_raw, delta_in=delta,
               head_present=g["head_present"], spine_side=g["spine_side"],
               blade_len_in=g["blade_len_in"], mask_info=minfo, dir_fits=tried,
               debug=dict(card=card, mask=mask, geom=g, cuts=cuts, delta=delta))
    return out


def uv_to_xy(g, u, v_rebased):
    """Rebased rotated coords (as stored in the geometry dict) -> corrected
    image pixel xy, for overlay drawing."""
    u_true = u + g["u_off"]
    v_true = v_rebased + g["v_off"]
    return g["c"] + u_true * g["e1"] + v_true * g["e2"]
