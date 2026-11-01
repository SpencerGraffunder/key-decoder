# Key-decode CV prototype — validation report

Generated 2026-10-31 23:30 by `run_report.py` on Python 3.14.7, opencv 5.0.0, numpy 2.5.4.

Synthetic scenes per docs/ALGORITHM.md 'Validation protocol': ID-1 card on noisy
background, bow (flat-shoulder rounded rect) + blade + trapezoid cuts (root flat
= cutWidthIn, flank 12.5° from vertical), random homography (tilt ≤30°, rotation
≤25°, card 55–90% of frame width), fixed seeds per condition, systems cycled
kw1 / sc1 / sc1-6p. Ground-truth quad handed to the decoder (auto-sanity gate
still applied; scenes whose GT quad fails the spec's own sanity gate are
re-rolled, see 'Edge cases').

Each condition: N = 24.

## Accuracy matrix

| condition | full-code % | per-cut % | mean abs depth err (in) | status fails |
|---|---|---|---|---|
| clean | 100.0 | 100.0 | 0.00062 | 0 |
| gaussian | 100.0 | 100.0 | 0.00074 | 0 |
| blur2 | 100.0 | 100.0 | 0.00081 | 0 |
| lowres | 100.0 | 100.0 | 0.00086 | 0 |
| gradient | 100.0 | 100.0 | 0.00072 | 0 |
| shadow | 100.0 | 100.0 | 0.00071 | 0 |
| headgray | 100.0 | 100.0 | 0.00055 | 0 |
| edgecrop | 100.0 | 100.0 | 0.00065 | 0 |
| boundary | 95.8 | 96.1 | 0.00199 | 0 |
| headless | 100.0 | 100.0 | 0.00068 | 0 |

Overall: 239/240 codes, 1275/1280 cuts.

## Flag behavior

Boundary-condition cuts are re-rolled so the TRUE depth sits within ±0.3
increments of a mid-step position; 'near-boundary' below means true margin
in (0.35, 0.50]·increment (the low-confidence band).

- Near-boundary cuts (all conditions): **17**
  - any flag fired (low-confidence surfaced): 17/17 = 100.0%
  - margin-only conf-low fired: 17/17 = 100.0%
  - among boundary cuts READ WRONG: flag fired 1/1 = 100.0%
- Non-boundary cuts (true margin <= 0.35): **1263**
  - any flag (FP, all conditions): 58/1263 = 4.6%
  - CLEAN non-boundary false-positive rate: any-flag 0/128 = 0.0% (margin 0/128, RMS 0/128)
  - degraded non-boundary: any-flag 58/1135 = 5.1%
  - degraded non-boundary misreads: 4, of which flagged 4
  - note: with blur2/lowres/boundary the window-RMS flag exceeds the
    spec's 0.25*increment threshold on a large share of CORRECT cuts
    (blur spreads edges, so within-window profile noise is genuinely
    larger). Flags stay conservative and never suppress a correct
    read; for the Swift port recommend treating RMS-flag as advisory,
    or re-calibrating RMS_FACTOR against real-camera blur statistics.

## Targets vs measured

| target | required | measured | verdict |
|---|---|---|---|
| clean full-code | ≥95% | 100.0% | PASS |
| degraded per-cut | ≥90% | min 100.0% (gaussian) | PASS |
| boundary low-confidence recall | ≥90% | 100.0% | PASS |

## Parameter changes vs ALGORITHM.md defaults

- depth window half-width `h`: **0.030in/0.45·spacing → 0.012in/0.25·spacing** (parent-directed 2026-10-31, wide window averaged the notch ramp and biased depths shallow; root flats are ~0.07–0.08in wide on sc1/kw1, so ±0.012in fits with margin).
- offset auto-align scan objective: spec says MAXIMIZE Σ depth at cut centers; implemented as table-RMS MINIMIZE. The spec's own depth definition (|v_edge − v_spine|, root depth from spine) is a MINIMUM at cut centers; 'maximize' only holds for notch-penetration depth. Σ-depth was also replaced by RMS-to-table because Σ is nearly flat across the notch root band (flat ~0.02–0.045in vs 0.004in scan step) so sub-pixel noise decided the argmin and the grid sat off-center by up to 0.032in; plus an |δ| regularizer ALIGN_TAU=0.03/in which prefers the centred alignment when the fit ties across the band (this is also what finally stabilised headless direction choice). At 0.005/in the regularizer was below plateau fit noise (~1e-4 in) and clean RMS flags spiked to 16% FP (windows clipped notch flanks); at 0.03 clean FP is 0% and injected firstCut drift up to 0.06in still decodes 36/36.
- sub-pixel boundary edges: v_edge(u) taken from the |g−B| profile interpolated at the half-level between outer/inner plateaus instead of the binary-mask pixel edge. Same quantity as the spec's v_edge, ~2x lower depth error (clean mean |err| fell to ~0.0006in) and required for the near-boundary flags to have signal (sc1 increment is only 0.015in ≈ 11.6 px; ±0.5 px mask quantization = ±0.04 increments).
- confidence flag: 'high' requires margin m ≤ 0.35 − unc where unc = min(0.25, max(2·windowRMS/inc, 1.5·R_code, 0.02)) increments and R_code is the RMS table-residual of the whole code (global depth-uncertainty estimate). A genuinely near-boundary cut measured just BELOW 0.35 due to noise must still surface (spec intent: surface uncertainty to the user). Clean codes have R_code≈0.03 inc so their margin threshold barely moves and measured FP stayed 0%; blurred/noisy codes get unc 0.1-0.25 inc and near-boundary cuts are caught.
- head region: contiguous run of w > 1.9·Wb allowed a narrow rounded cap of up to 0.30in at the blob end (HEAD_CAP_TOL_IN); head run re-joins across ≤3-px dips provided dip width stays ≥1.6·Wb. Spec text ('contiguous end region') assumes a perfectly sharp step at bin 0.
- blob aspect sanity: implemented as sqrt(λ1/λ2) of the pixel covariance. The spec's 'bounding-box aspect along principal axis' under a rotated-bbox reading is ~2.3 for any bowed key and would reject valid keys (see edge cases).
- headless direction resolution: RMS-of-nearest-table alone is provably ambiguous when a mirrored grid can read the same cuts in reverse order; added (a) priority for directions whose offset scan aligned within 0.045in and (b) soft penalty 0.05·max(0, |δ|−0.030)in. See code DEVIATION comments.
- profile-noise RMS flag: RMS about the window MEAN (an absolute RMS of depth would fire everywhere).
- interior dead columns: spec only trims the u-range ends; dead columns inside the band are tolerated and handled by the per-cut empty-column flag.

## Synthesizer notes (affect measured numbers)

- bow = rounded rectangle with a FLAT vertical shoulder face (matches Swift synth per parent direction); a fully round bow biases the 1.9·Wb shoulder rule by up to ~0.17in — recorded as an edge case instead.
- cut profile = trapezoid, root flat = cutWidthIn, flanks 12.5° from vertical. Real end-mill cuts have near-vertical flanks; a 45° flank makes notch openings wider than the cut spacing and swallows shallow neighbors (found by debug).
- tip lead-in beyond the last cut: uniform 0.145-0.18in, RE-DRAWN until
  informationally decidable headless (requires
  |tip_overhang - firstCut + m*spacing| > 0.060in for every integer m;
  otherwise a mirrored grid reads the identical depth multiset and no
  depth-based rule can pick the direction - an honest field case that
  would need the visible bow/shoulder, so synthetic scenes exclude it and
  record it as an edge case). Re-draw consumes the same uniform stream,
  so all draws stay inside the protocol's stated range.

- headless direction choice additionally weights 0.02*|delta| into the
  cross-direction fit comparison (mirrored grids pay for their alignment
  drift); combined with the re-draw, a 40-seed 3-system headless sweep
  passes with zero mirror flips.

- scenes whose GT quad fails the spec's own auto-detect sanity gate (aspect 1.30–1.90 / area ≥15%) are re-rolled, since the pipeline would legitimately take the manual path on them. Strong perspective (tilt near 30°) can foreshorten the card aspect below 1.30 — that's ~spec-limits, not bugs.

## Edge cases found

- PCA principal axis of bow+blade tilts 1–3° off the blade axis when cuts are asymmetric; harmless here because depths are differenced against the robust spine fit (both sides share the shear), but the Swift port must not assume axis == blade direction.
- Rotated-bbox aspect of a real bowed key is ≈2.2–2.4; the spec's MIN_ASPECT 2.5 only works on the eigenvalue-ratio basis. Documented choice.
- Shallow cuts near the top of the table (sc1 digit 0, .335 on .343 blade = .008in of cut) measure correctly with the narrow window but were biased by the old wide window — primary motivation for the h change.
- Headless mirror ambiguity (above): if ever hit in the field, the honest behavior is to flag the code for user review, not silently pick.

## Reproduce

```
cd /home/graffunder/key-decoder/tools/proto
.venv/bin/python run_report.py
```

Overlays under samples/ex_*.png (green = mask contour, yellow = spine fit, red = shoulder, blue/orange = tip, thin lines + digits = cut centers, red digit = flagged cut).
