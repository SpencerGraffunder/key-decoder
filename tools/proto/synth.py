"""Programmatic key-scene renderer per docs/ALGORITHM.md "Validation protocol".

Renders an ID-1 card on a noisy background with a bow-disc + blade key whose
cut-side silhouette is a trapezoid-notch profile with root depths taken from
the system depth table, then warps the whole scene with a random homography
(tilt <= 30 deg, rotation <= 25 deg, card 55-90% of frame width).
Ground truth = warped card quad, true digits, true per-cut root depths.

Conditions (protocol classes + two extra classes needed to test the flag and
headless paths):
  clean, gaussian, blur2, lowres, gradient, shadow, headgray, edgecrop,
  boundary (near-boundary depths re-rolled, + noise/blur), headless (bow
  color == card color so only the blade segments -> dual-direction resolve).
"""
from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEMS_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "KeyCore", "Resources", "keysystems.json"))

IN_MM = 25.4
CARD_MM = (85.60, 53.98)
BASE_SYSTEMS = ("kw1", "sc1", "sc1-6p")
DEFAULT_BLADE_W_IN = 0.343  # spec: use .343" when bladeWidthIn is null

PMM = 15.0          # base scene px per mm
SS = 2              # supersample factor for antialiasing
FRAME_W, FRAME_H = 1920, 1200
LOWRES_W = 1200
CARD_FILL = (0.55, 0.90)

CONDITIONS = ["clean", "gaussian", "blur2", "lowres", "gradient", "shadow",
              "headgray", "edgecrop", "boundary", "headless"]


def load_systems(path: str = SYSTEMS_PATH) -> dict:
    with open(path) as f:
        js = json.load(f)
    return {s["id"]: s for s in js["systems"]}


SYSTEMS = load_systems()


# --------------------------------------------------------------------------
# code / depth sampling
# --------------------------------------------------------------------------

def true_margins(depths, sysd):
    table = np.asarray(sysd["depthsIn"], dtype=float)
    inc = float(sysd["incrementIn"])
    return np.min(np.abs(table[None, :] - np.asarray(depths, float)[:, None]), axis=1) / inc


def sample_code(rng, sysd: dict, boundary: bool):
    """Random code; if boundary=True reroll until >=1 cut sits within +-0.3
    increments of the mid position between two adjacent table depths."""
    table = np.asarray(sysd["depthsIn"], dtype=float)
    inc = float(sysd["incrementIn"])
    n = int(sysd["pinCount"])
    mids = (table[:-1] + table[1:]) / 2.0
    for _ in range(5000):
        digits = rng.integers(0, len(table), size=n)
        if not boundary:
            return digits, table[digits].astype(float)
        depths = table[digits].astype(float).copy()
        j = int(rng.integers(0, n))
        depths[j] = float(rng.choice(mids)) + rng.uniform(-0.25, 0.25) * inc
        margins = true_margins(depths, sysd)
        if np.any((margins >= 0.20) & (margins <= 0.48)):
            digits = np.array([int(np.argmin(np.abs(table - d))) for d in depths])
            return digits, depths


# --------------------------------------------------------------------------
# scene rendering (straight-on, supersampled)
# --------------------------------------------------------------------------

FLANK_SLOPE = 4.5  # dn/dd of the trapezoid flank (4.5 ~= 12.5 deg from
                   # vertical; end mills cut near-vertical flanks)


def _trapezoid_notches(x_grid, centers, ndepths, cutw_px):
    """Depth cut INTO the edge, n(x): trapezoid with flat root = cutWidth and
    near-vertical flanks (root flat matches the end-mill width of a real cut)."""
    n = np.zeros_like(x_grid)
    for xc, nd in zip(centers, ndepths):
        d = np.abs(x_grid - xc)
        prof = np.maximum(0.0, nd - np.maximum(0.0, d - cutw_px / 2.0) / FLANK_SLOPE)
        n = np.maximum(n, prof)
    return n


def render_scene(rng, sysd, digits, depths, condition):
    """Returns (scene float HxW @ base scale, card_quad TL,TR,BR,BL in scene px)."""
    p = PMM * SS
    cw, ch = CARD_MM[0] * p, CARD_MM[1] * p
    W, H = int(round(cw * 1.25)), int(round(ch * 1.25))
    ox, oy = (W - cw) / 2.0, (H - ch) / 2.0

    img = rng.normal(140.0, 30.0, (H, W))
    yy, xx = np.mgrid[0:H, 0:W]
    incard = (xx >= ox) & (xx < ox + cw) & (yy >= oy) & (yy < oy + ch)
    img[incard] = rng.normal(245.0, 0.8, int(incard.sum()))

    # ---- key layout, px at supersample scale ----
    blade_w = (sysd.get("bladeWidthIn") or DEFAULT_BLADE_W_IN) * IN_MM * p
    cutw = float(sysd["cutWidthIn"]) * IN_MM * p
    first = float(sysd["firstCutIn"]) * IN_MM * p
    spac = float(sysd["spacingIn"]) * IN_MM * p
    npin = int(sysd["pinCount"])
    blade_len = first + (npin - 1) * spac + 0.22 * IN_MM * p   # tip past last cut
    bow_len, bow_w = 0.55 * IN_MM * p, 0.70 * IN_MM * p
    total = bow_len + blade_len

    flip = (condition == "headless") and (rng.random() < 0.5)

    if condition == "edgecrop":
        # bow hangs 2 mm past a short card edge onto the background
        left_x = (ox - 2.0 * p) if not flip else (ox + cw + 2.0 * p - total)
    else:
        left_x = ox + (cw - total) / 2.0 + rng.uniform(-0.28, 0.28) * IN_MM * p

    if flip:      # blade left, bow right
        blade_x0, blade_x1 = left_x, left_x + blade_len
        bow_x0, bow_x1 = blade_x1, left_x + total
        shoulder_x = blade_x1
        sgn = -1.0
    else:         # bow left, blade right (normal read orientation)
        bow_x0, bow_x1 = left_x, left_x + bow_len
        blade_x0, blade_x1 = bow_x1, left_x + total
        shoulder_x = blade_x0
        sgn = 1.0

    centerline = oy + ch / 2.0 + rng.uniform(-2.0, 2.0) * p
    spine_y = centerline - blade_w / 2.0

    centers = [shoulder_x + sgn * (first + i * spac) for i in range(npin)]
    # depth cut into the edge = blade width - root depth
    ndepths = [float(np.clip(blade_w - float(dv) * IN_MM * p, 0.0, blade_w * 0.85))
               for dv in depths]

    xa, xb = int(np.floor(blade_x0)), int(np.ceil(blade_x1))
    xg = np.arange(xa, xb, dtype=float)
    edge_y = spine_y + blade_w - _trapezoid_notches(xg, centers, ndepths, cutw)

    metal = float(rng.uniform(92, 112))
    if condition == "headgray":
        bowval = 128.0
    elif condition == "headless":
        bowval = 245.0 + rng.normal(0.0, 1.0)   # matches card -> bow invisible
    else:
        bowval = metal * rng.uniform(0.85, 1.0)

    # blade pixels (spine side = top, cut side = bottom)
    cols = np.arange(xa, xb)
    sel = (yy[:, cols] >= spine_y) & (yy[:, cols] < edge_y[None, :])
    sheen = metal + 20.0 * ((yy[:, cols] - spine_y) / blade_w - 0.5)
    img[:, cols] = np.where(sel, np.clip(sheen, 40, 200), img[:, cols])

    # bow: rounded rect, flat end exactly at the shoulder step (see REPORT)
    r = 0.15 * IN_MM * p
    by0, by1 = centerline - bow_w / 2.0, centerline + bow_w / 2.0
    bm = (yy >= by0) & (yy < by1) & (xx >= bow_x0) & (xx < bow_x1)
    # round the two OUTER corners only (the shoulder end stays a sharp step)
    for cy_ in (by0 + r, by1 - r):
        cx_ = bow_x0 + r if not flip else bow_x1 - r
        outside_corner = ((xx < cx_) if not flip else (xx > cx_)) & \
                         ((yy < cy_) if cy_ < centerline else (yy > cy_))
        carve = bm & outside_corner & (np.hypot(xx - cx_, yy - cy_) > r)
        bm = bm & ~carve
    img[bm] = bowval

    img = cv2.resize(img, (W // SS, H // SS), interpolation=cv2.INTER_AREA)

    # ---- condition grading at base scale ----
    yyb, xxb = np.mgrid[0:img.shape[0], 0:img.shape[1]]
    if condition == "gradient":
        g = rng.uniform(40.0, 55.0)
        ang = rng.uniform(0.0, 2 * math.pi)
        t = xxb * math.cos(ang) + yyb * math.sin(ang)
        img = img + g * (t / max(t.max(), 1e-9) - 0.5)
    elif condition == "shadow":
        ys = float(rng.uniform(oy, oy + ch)) / SS
        sigma = rng.uniform(4.0, 8.0) * PMM
        amp = rng.uniform(35.0, 60.0)
        img = img - amp * np.exp(-0.5 * ((yyb - ys) / sigma) ** 2)
    elif condition == "blur2":
        img = cv2.GaussianBlur(img, (0, 0), 2.0)

    card_quad = np.array([[ox, oy], [ox + cw, oy], [ox + cw, oy + ch], [ox, oy + ch]],
                         dtype=float) / SS
    return np.clip(img, 0, 255), card_quad


# --------------------------------------------------------------------------
# homography + photo
# --------------------------------------------------------------------------

def _transform(pts, M):
    """Apply 3x3 homography M to Nx2 points, cv2 column-vector convention:
    x' = M @ [x, y, 1] (NOT the transposed row-vector form)."""
    pts = np.asarray(pts, dtype=np.float64)
    h = pts @ M[2, :2].T + M[2, 2]
    xy = pts @ M[:2, :2].T + M[:2, 2]
    return np.column_stack([xy[:, 0] / h, xy[:, 1] / h])


def plane_homography(rx, ry, rz, focal=2200.0):
    rx, ry, rz = (math.radians(v) for v in (rx, ry, rz))
    cx, cy = FRAME_W / 2.0, FRAME_H / 2.0
    K = np.array([[focal, 0, cx], [0, focal, cy], [0, 0, 1.0]])

    def R(a, axis):
        c, s = math.cos(a), math.sin(a)
        if axis == 0:
            return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], float)
        if axis == 1:
            return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]], float)
        return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], float)

    return K @ R(rz, 2) @ R(ry, 1) @ R(rx, 0) @ np.linalg.inv(K)


def warp_scene(rng, scene, card_quad, lowres=False):
    """Random homography; returns (photo float, gt quad TL,TR,BR,BL)."""
    Hp = None
    for _ in range(300):
        f = rng.uniform(*CARD_FILL)
        rz = rng.uniform(-25, 25)
        rx = rng.uniform(-24, 24)
        ry = rng.uniform(-24, 24)
        c = card_quad.mean(axis=0)
        A = np.vstack([cv2.getRotationMatrix2D((0.0, 0.0), rz, 1.0), [0, 0, 1]])
        S = np.array([[f, 0, 0], [0, f, 0], [0, 0, 1.0]])
        T1 = np.array([[1, 0, -c[0]], [0, 1, -c[1]], [0, 0, 1.0]])
        P = plane_homography(rx, ry, rz)
        q = _transform(card_quad, P @ A @ S @ T1)
        mn, mx = q.min(0), q.max(0)
        if mx[0] - mn[0] > 0.955 * FRAME_W or mx[1] - mn[1] > 0.955 * FRAME_H:
            continue
        tx = FRAME_W / 2 - (mn[0] + mx[0]) / 2 + rng.uniform(-1, 1) * max(0.0, 0.93 * FRAME_W - (mx[0] - mn[0])) / 2
        ty = FRAME_H / 2 - (mn[1] + mx[1]) / 2 + rng.uniform(-1, 1) * max(0.0, 0.93 * FRAME_H - (mx[1] - mn[1])) / 2
        T2 = np.array([[1, 0, tx], [0, 1, ty], [0, 0, 1.0]])
        Hp = T2 @ P @ A @ S @ T1
        quad = _transform(card_quad, Hp)
        mn, mx = quad.min(0), quad.max(0)
        if mn[0] > 6 and mn[1] > 6 and mx[0] < FRAME_W - 6 and mx[1] < FRAME_H - 6:
            break
    else:
        raise RuntimeError("could not build a valid homography")

    photo = cv2.warpPerspective(scene.astype(np.float32), Hp, (FRAME_W, FRAME_H),
                                flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                                borderValue=0.0)
    alpha = cv2.warpPerspective(np.ones(scene.shape, np.float32), Hp, (FRAME_W, FRAME_H),
                                flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                                borderValue=0.0)
    outside = rng.normal(140.0, 30.0, photo.shape)
    photo = photo * np.clip(alpha, 0, 1) + outside * np.clip(1.0 - alpha, 0, 1)

    if lowres:
        s = LOWRES_W / FRAME_W
        photo = cv2.resize(photo, (LOWRES_W, int(round(FRAME_H * s))),
                           interpolation=cv2.INTER_AREA)
    quad = _transform(card_quad, Hp)
    if lowres:
        quad *= LOWRES_W / FRAME_W
    return np.clip(photo, 0, 255), quad


# --------------------------------------------------------------------------
# sample API
# --------------------------------------------------------------------------

@dataclass
class Sample:
    photo: np.ndarray           # uint8 gray
    quad: np.ndarray            # 4x2 gt card corners TL,TR,BR,BL
    sysid: str
    sysd: dict
    digits: np.ndarray          # true digits (nearest-table for boundary cuts)
    depths: np.ndarray          # true root depths (inches)
    margins: np.ndarray         # true |depth-nearest|/increment
    boundary_cut: np.ndarray    # bool per cut: true margin in (0.35, 0.5]
    condition: str


def make_sample(sysid: str, condition: str, seed: int) -> Sample:
    rng = np.random.default_rng(seed)
    sysd = SYSTEMS[sysid]
    digits, depths = sample_code(rng, sysd, boundary=(condition == "boundary"))
    margins = true_margins(depths, sysd)

    noise_sigma = 6.0 if condition == "gaussian" else (4.0 if condition == "boundary" else 0.0)

    scene, card_quad = render_scene(rng, sysd, digits, depths, condition)
    photo, quad = warp_scene(rng, scene, card_quad, lowres=(condition == "lowres"))
    if noise_sigma > 0:
        photo = photo + rng.normal(0.0, noise_sigma, photo.shape)
        photo = np.clip(photo, 0, 255)
    if condition == "boundary":
        photo = cv2.GaussianBlur(photo.astype(np.float32), (0, 0), 1.2)

    return Sample(photo=np.round(photo).astype(np.uint8), quad=quad, sysid=sysid,
                  sysd=sysd, digits=np.asarray(digits, int),
                  depths=np.asarray(depths, float), margins=np.asarray(margins, float),
                  boundary_cut=(margins > 0.35) & (margins <= 0.5), condition=condition)


if __name__ == "__main__":
    os.makedirs(os.path.join(HERE, "samples"), exist_ok=True)
    s = make_sample("kw1", "clean", 1)
    print("photo", s.photo.shape, "quad", np.round(s.quad, 1).tolist())
    print("digits", s.digits, "depths", np.round(s.depths, 3))
    cv2.imwrite(os.path.join(HERE, "samples", "debug_sample.png"), s.photo)
