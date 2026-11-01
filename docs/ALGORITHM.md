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
1640 px. pixelsPerMm = W_out / 85.60 ≈ 30.37 (constant for the pipeline; the
photo's native resolution does not matter).

Homography: compute 3x3 projective transform mapping Q → (0,0),(W_out,0),
(W_out,H_out),(0,H_out) via DLT (8-equation linear solve). Warp with inverse
mapping + bilinear sampling (clamp borders).

Card sanity (when the quad came from auto-detection, not the manual handles):
area fraction >= 15% of the image and aspect (long/short edge, edge-mean basis)
in [1.30, 1.90]; else treat detection as failed → manual path.

### 2. Key mask (on the corrected image)
1. Ignore a 2.0 mm inner margin of the corrected card image (card edges,
   printed borders) — set those pixels to background.
2. Background level B = median of a 1.5 mm band just inside the ignored margin
   (card face color).
3. Diff D = |g − B| (absolute luminance difference). This catches darker metal,
   darker or lighter plastic heads, and bright specular metal on a light card.
4. Threshold D with Otsu.
5. Morphological close (3x3, 2 iterations) then open (3x3, 1 iteration).
6. Keep the largest connected component (8-connected). If its area < 1.5% of
   card area or its bounding-box aspect along its principal axis < 2.5, fail →
   manual path.
7. Fill holes (background components not connected to the image border).

### 3. Blade geometry
From the key mask CC:
1. Principal axis θ = orientation of the largest eigenvector of the pixel
   covariance. Sign is resolved so the bow/wide end is at LOW u (see 3d).
2. Rotate coords: u = along axis (0 at blob centroid), v = perpendicular.
3. Column profile: for every u bin (1 px) that has mask pixels, record
   v_top(u) = min v, v_bot(u) = max v, width w(u) = v_bot − v_top.
   Trim u range to where column pixel count >= 5% of the median blade width in
   px (kills fringe).
4. Blade width W_b = median of w over all bins. Head/bow region: contiguous
   end region where w > 1.9 × W_b. The blade band = complement.
   - Head present on one end → that end is BOW side (u small after sign flip).
   - No head (plastic blends into the card): both ends are blade ends; resolve
     direction later (3f).
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
pick δ maximizing Σ_i depth(u_i + δ). (Cuts are deepest at their centers.)

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
nearest table depth| RMS, then the offset scan within it.

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
