# Key-decode CV algorithm (normative spec)

This is the single source of truth for the measurement pipeline. The Python
prototype (`tools/proto`) validates it; the Swift implementation (`KeyCore`)
must match it step-for-step. Deviations must be reported, not silent.

Conventions: images are grayscale UInt8, y-DOWN pixel coordinates. All real
units: mm and decimal inches. "Card" = ISO/IEC 7810 ID-1, 85.60 x 53.98 mm.

## Pipeline (photo in → code out)

### 1. Card quad → corrected top-down view
Input: full photo (CGImage / np.ndarray BGR), card quad Q = 4 corners ordered
TL,TR,BR,BL in pixel coords with the long edge (TL→TR) along the card's 85.6 mm
side. Ordering: sort the 4 points by angle around their centroid, then rotate
the order so edge TL→TR is the longest of the two candidate edges; if the
resulting quad is y-down CW flipped, swap TR/BL ordering so the polygon reads
TL→TR→BR→BL clockwise in y-down space.

Output rect: fixed width W_out = 2600 px, H_out = round(W_out * 53.98/85.60) =
1640 px. PADDED WARP (v3): the source quad is grown about the card centroid by
1/(1−2m), m = 0.16, so the corrected frame carries a ring of the photo around
the card; the card itself spans the central (1−2m) region and
pixelsPerMm = W_out·(1−2m) / 85.60 ≈ 20.65. Rationale: keys whose teeth hang
past the card edge survived the warp as cropped blobs; the pad keeps them, and
a padded metric flows through every downstream consumer unchanged. The card
and key sit at slightly different depths (a few mm over ~60 cm), so the card
homography is off by millimeters for the overhang — far inside the depth
window. Legacy unpadded mode (m = 0) remains supported for direct corrected
images; ppm for it stays W_out / 85.60.

Padding is clamped: m_eff = min(m, largest padding whose expanded quad still
fits inside the source photo). Sampling beyond the photo clamps to smeared
edge rows; when those read card-colored the "photo ring" background silently
becomes card face and overhang contrast drops to zero. m_eff = 0 (card fills
the frame) routes the whole pipeline through the legacy unpadded path; m_eff
is returned by correct() and flows into pixelsPerMm and analyzeScene(m:).
Homography: compute 3x3 projective transform mapping the (padded, clamped) Q
→ (0,0),(W_out,0),(W_out,H_out),(0,H_out) via DLT (8-equation linear solve).
Warp with inverse mapping + bilinear sampling (clamp borders).

Card sanity (when the quad came from auto-detection, not the manual handles):
area fraction >= 15% of the image and aspect (long/short edge, edge-mean basis)
in [1.30, 1.90]; BOUNDARY STRENGTH (v3): sample the gradient magnitude along
each quad side (max within ±4 px of the side normal), keep per-side minima,
average the middle two — confident picks need >= 25 (suggestion tier >= 10),
both gates scaled by min(w,h)/620 clamped to [0.45, 1] so low-resolution live
frames keep a working finder. So flat-background hallucination quads from
Vision lose to real edges. GRADIENT-CARD SEGMENTATION: brushed-metal cards
(field photo: 50→250 across the face) trip an object-immune gradient probe
(median-of-row-medians top-vs-bottom and left-vs-right > max(24, 2.5σ)); on
such frames the card background becomes a MEDIAN FIELD (LocalBackground:
30 mm sliding-median on a ≤150-cell grid, bilinearly upsampled — a MEAN
would absorb the key and ghost its shape) and masking switches to
HYSTERESIS WITH GROWTH CAP: pixels above a 2.2σ weak threshold survive only
within 5 px of a strong (Otsu) pixel, so specular stripes / contact-gap
rings paint low-contrast key bodies while cast shadows (broad weak regions
adjacent to the key) cannot piggyback; floor softens to 2.0σ (8–45). FLAT
frames run the v3b single-threshold path verbatim — hysteresis' AA growth
measurably shifted tooth bottoms a full depth digit on synthetic keys. The
overhang rescue zone outside the card is a 30 mm band at outerT (an 8 mm
ring chopped a large bow — 100k px; connectivity can't bridge the 1.5 mm
excluded boundary band). Blobs touching the frame border are rejected on
padded picks (glare strips live there).
Dark-on-dark sensitivity: the
dark metal card on a dark table returned NOTHING with stock contour
settings, so contours contrastAdjustment = 1.0 (rectangle requests expose
no contrast knob — sensitivity comes from contours + quad scoring + prior).
CAPTURE-GUIDE PRIOR: capture-time callers map the on-screen guide outline
(preview-normalized 0.09,0.3205,0.82,0.239 — mirrors the drawn geometry)
into PHOTO space — an aspect-fill preview shows the 3:4 frame's full height
and only previewAspect/0.75 of its width — and multiply candidate scores by
max(0.15, exp(−1.2 d²/σ²)), d = centroid distance to the mapped guide
center: the card near the guide outranks strong-edge clutter. GUIDE-SCAN
FALLBACK: when detection still finds nothing (the dark-card case), the app
runs the real pipeline (keyScore: correct + analyzeScene + blob-size and
spine-quality terms) at guide offsets dy ∈ {±20%, ±10%, 0} and seeds the
corner editor where a key-sized blob actually segments; the plain mapped
guide quad is last resort. The live finder uses a center-blob prior/fallback
in landscape-buffer space (orientation-robust; cosmetic overlay). User quads
from the editor skip sanity gates but get a one-tap aspect warning. Even a
confident detection lands in the corner editor pre-seeded (no auto-skip).

### 2. Key mask (on the corrected image, v3)
Legacy unpadded frames (m = 0) follow steps 1–7 with the SINGLE card-face
background; padded frames (m = 0.16) differ where noted.
1. Card rectangle C = central (1−2m) region on padded frames, else the whole
   frame minus a 2.0 mm inner margin (card edges, printed borders).
2. Card-face background B = median of a 1.5 mm band just inside C's edge;
   sigma = 1.4826 × MAD of the same band (card texture level). On padded
   frames also sample B_out = median of everything outside C but inside a
   guarded frame edge (the photo's table/surroundings).
3. Diff D = |g − B| inside C, |g − B_out| outside C (padded frames). A key
   overhanging the edge therefore segments against the table, teeth included.
4. SPATIAL threshold (padded frames): t = max(Otsu over pixels inside C,
   clamp(3.5·sigma, 12, 80)) as before, but pixels OUTSIDE C mask against
   t_out = clamp(0.55·t, 20, 120) instead. One global threshold cannot serve
   both regimes — a dark key on a dark table has ~50-level table contrast
   while the card-side Otsu lands at 70+, and a dual-reference
   max(|g−B|,|g−B_out|) would rate the light card itself as high-contrast
   against a dark table and mask the whole card. The floor rejects soft cast
   shadows (15–25 levels on real captures); a real key sits 60+ levels out.
5. Morphological close (3x3, 2 iterations) then open (3x3, 1 iteration). On
   padded frames, pixels excluded BEFORE thresholding: a 1 px band along the
   INSIDE of C's border (warp seams, corner-rounding table slivers — wider
   bands slice a straddling key into two components and morphology cannot
   rebridge them; residual sliver rings are < 0.4% area and step 6 removes
   them) and a 3 px band along the frame border (clamped-warp garbage).
6. detachWeakBridges (padded frames only — legacy frames put the table at
   diff≈0, so the pass would only cost): erode 2×, drop components < 0.4%
   area, dilate survivors 2 rings back, AND with the mask — specks and thin
   shadow bridges snap off.
7. Connected-component pick: among components with area >= 1.5% of CARD area
   (scale the frame fraction by (1−2m)² on padded frames), aspect
   sqrt(λ1/λ2) >= 2.5. Legacy score: area x (1 + 0.06·(aspect−2.5), cap
   +1.5) x gaussian(center distance; the
   capture UI guides keys to the card center). A split ring/fob (rounder,
   sometimes larger) must not hijack the key; text bands and accessories lose
   to center + elongation. On padded frames scoring flips emphasis
   (elongBoost): shape enters as ^0.1 (near-flat tie-breaker) and the center
   gaussian is squared — an off-center seam or text ring is long and thin by
   construction, so shape-dominant scoring hands it the key. If nothing is elongated keep the largest; below
   the area floor or aspect < 2.5 with no head → fail, manual path. A seed
   point (user "that's my key" tap) overrides the pick entirely (floor 0.4%).
8. Fill holes (background components not connected to the image border).

### 3. Blade geometry
From the key mask CC:
1. Principal axis θ = orientation of the largest eigenvector of the pixel
   covariance. Sign is resolved so the bow/wide end is at LOW u (see 3d).
2. Rotate coords: u = along axis (0 at blob centroid), v = perpendicular.
3. Column profile: for every u bin (1 px) that has mask pixels, record
   v_top(u) = min v, v_bot(u) = max v, width w(u) = v_bot − v_top.
   Trim u range to where column pixel count >= 5% of the median blade width in
   px (kills fringe).
4. Blade width W_b = 25th percentile of w over all bins (a plain median breaks
   when the bow covers > 50% of the blob, which a 1.05" bow vs 1.63" blade
   routinely does; the bow only shifts the upper tail, so p25 stays on the
   blade). Head/bow region: run of bins with w > 1.9 × W_b anchored at a blob
   end, validated against prototype (tools/proto/REPORT.md): a rounded/tapered
   cap of any width ≤ 0.30" at the outer end is skipped before the run starts;
   the run re-joins across dips ≤ 3 px whose columns stay ≥ 1.6 × W_b; the
   head counts as PRESENT only if the run spans ≥ 0.10". The blade band =
   complement.
   - Head present on one end → that end is BOW side (u small after sign flip).
   - No head (plastic blends into the card, OR the bow hangs off the card edge
     with the whole cut row on it — a supported capture mode): both ends are
     blade ends; resolve direction later (3f).
5. Spine side = the side (top/bot) with smaller robust residual when a line is
   fitted to its profile over the blade band. Line fit: least squares, then one
   pass dropping points with |residual| > 2.5×MAD, refit. Cut side = other side.
6. Shoulder position u_s:
   - Head present: u at the head/blade step = first blade-band bin after the
     head region.
   - No head: u_s = blade-end on the BOW side. Bow side when headless is
     resolved in the alignment step (3f): try both directions, pick the one
     with lower grid-fit residual.
7. Tip position u_t = far blade end on the opposite side. Blade length check:
   (u_t − u_s) in px → inches; sane range [0.5", 1.9"], else warn.

### 4. Cut centers + depths
Grid from the chosen key system S (inches, converted with pxPerMm):
u_i = u_s + (firstCut + i*spacing) * ppm, i = 0..pinCount−1 (alignment =
shoulder). For alignment = tip: u_i measured back from u_t.

Offset auto-align (removes shoulder-position error, up to ±0.060"): scan δ in
[−0.060", +0.060"] step 0.004"; depth_at(u) is defined in the next paragraph;
pick δ minimizing RMS_i |depth(u_i + δ) − nearest table depth| + 0.03·|δ| per
inch. (Prototype deviation, see REPORT.md: maximizing Σ depth parks the windows
on the blade floor between cuts, and Σ is flat across the notch root band so
sub-pixel noise decides the argmin; the |δ| regularizer breaks remaining ties
toward the centered alignment and stabilizes the headless direction choice.)

Depth per cut: window half-width h = min(0.012", 0.25*spacing) in px (the window
must stay on the cut's flat root bottom; a wider window averages the ramp flanks
and biases depths shallow). For each
column u in [u_i−h, u_i+h] take the extreme cut-side boundary v (max v if cut
side is bottom); depth_px(u) = |v_edge(u) − v_spine_fit(u)|; take the MEDIAN
over the window (robust to the flat bottom of the cut). depth_in = depth_px /
ppm / 25.4.

Confidence per cut:
- Table margin: m = |depth_in − nearest_table_depth| / increment.
  m ≤ 0.35 → high; m ≤ 0.5 → low-confidence (near boundary between two
  depths → surface to the user as flagged); > 0.5 → out-of-table warning
  (show nearest but flag hard).
- Profile noise: RMS of depth_px over the window > 0.25 × increment → flag.
- Any column in window with no mask pixels → flag.

Direction (headless case) is picked jointly with the offset scan: evaluate the
grid fit in both axis directions, pick the direction with lower total |depth −
nearest table depth| RMS, then the offset scan within it. Mirrored grids can
read the same depth multiset in reverse (provably ambiguous), so add
0.05·max(0, |δ| − 0.030") to the cross-direction comparison (the offset scan
itself only aligns within ±0.060"). If a real headless key is still ambiguous
(tip overhang ≈ firstCut ± m·spacing within 0.060"), the honest behavior is to
flag the code for user review, not silently pick.

### 5. Depth → digit
Digit = argmin over the system's depth table. Never round outside the table
without the out-of-table flag. Code string = digits joined by "−", bow-side
cut first (matches industry read order).

### 6. Auto-suggest (key system)
Independent of any one table: estimate the actual cut spacing from the profile
via 1-D autocorrelation of (depth(u) − its robust line) over the blade band,
peak location = spacing (in inches); count scallops = local maxima count of
depth(u) after smoothing at 0.5×spacing, requiring prominence > 0.4 ×
expected increment. Candidate systems scored by |detected spacing − S.spacing|
penalty plus measured-depth RMS residual under S's table; top suggestion +
runner-up shown in the UI, manual override always available. If detected
scallop count > 0 it also gates pin count (count != S.pinCount → deprioritize).

**Stamp channel (extension over the original spec).** The corrected card view
is also run through Vision text recognition (`BowStampReader`). Normalized OCR
strings (uppercase alphanumerics) are matched against each system's id and its
`stamps` aliases in `keysystems.json` (`BowStamp.match`). A stamped hit outranks
all geometry scoring — factory engraving is stronger evidence than a fit
residual — and the ranked top-3 are shown as chips carrying their evidence
(`stamped "KW1" on the bow` / `spacing ~0.151 in · 5 cuts`). Like every other
suggestion this stays advisory: the user confirms via the chip or the system
menu.

## Validation protocol (Python prototype + Swift unit tests)

Synthetic ground truth (programmatic, no camera):
- Render an ID-1 card (white face, slight texture-free) on a noisy background,
  a KW1- or SC1-shaped key (bow disc + rectangular blade width .343", cuts =
  trapezoid notches, cut width .080"/.070", depth per the system table) with a
  random-ish code; warp the whole scene by a random homography (tilt ≤ 30°,
  card fills 55–90% of frame, rotation ≤ 25°).
- Known: the quad (from the warp), the true code, true per-cut depths.

Conditions (≥20 samples each, fixed seed): clean, gaussian-noise, blur(2px),
low-res (1200 px wide photo), brightness gradient (lighting), shadow band,
dark head (plastic bow #202020 on white card — tests headless path when it
matches card... use mid-gray #808080 instead for "colored head"), card-edge
crop (key extends 2 mm past card onto background — mask trim must save it).

Report: full-code accuracy and per-cut accuracy per condition; the flags
(low-confidence) must fire on the near-boundary forced cases (codes chosen to
sit ±0.3 of a boundary when noise applied).

## Parameters (defaults; tune in prototype, feed back here)
- W_out 2600, card margin ignore 2.0 mm, border band 1.5 mm, Otsu on |diff|,
  close 3x3×2, open 3x3×1, min blob 1.5% card area, head width factor 1.9,
  spine-fit MAD clip 2.5, offset scan ±0.060" step 0.004", window h =
  min(0.030", 0.45·spacing), margin flags 0.35 / 0.50, noise RMS flag 0.25·inc.

## Failure → manual path (every one of these must fall through, not dead-end)
Card quad missing/insane; key blob missing/too small/aspect < 2.5; blade
length outside [0.5",1.9"]; fewer scallops detected than pinCount; user
review screen always works with manual handles (quad) and manual markers
(shoulder line, spine line, per-cut center + optional direct digit entry).
