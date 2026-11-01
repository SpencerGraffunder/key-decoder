# Key Decoder

Decode a key's bitting code from a photograph — and keep the decoded keys in a
private, on-device library.

Key Decoder is free: no ads, no subscriptions, no in-app purchases, no accounts,
no backend, no analytics, and no network calls. Everything — card detection,
measurement, storage — runs on the device, offline.

**Intended use:** keys you own or are authorized to copy. See [LEGAL.md](LEGAL.md);
the app shows this notice on first launch.

![iOS](https://img.shields.io/badge/iOS-17%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## What it does

1. Photograph a key lying flat on an ID-1 card (credit card, 85.60 × 53.98 mm)
   used as the scale reference.
2. The app finds the card, computes a perspective-corrected top-down view, and
   derives pixels-per-mm. Card detection can always be fixed by dragging four
   corner handles.
3. The key blade is segmented, the shoulder and spine are located, and the root
   of each cut is measured against real-world units.
4. A review screen shows the corrected image with draggable markers (shoulder,
   spine, one per cut), live measurements in thousandths of an inch, and the
   decoded digit for each cut. Low-confidence cuts are flagged, never hidden.
5. Pick the key system (auto-suggested, manual override available) — v1 ships
   **Kwikset KW1** and **Schlage SC1/SC1-6pin**.
6. The result code (e.g. `3-5-2-4-1`) can be copied/shared as text.
7. Keys save to a searchable library with photos, label, tags, notes and
   timestamps; the whole library exports to JSON (re-importable) or CSV.
   Face ID / Touch ID lock is optional.

## Build and run

Requires the current stable Xcode (16+) on macOS. The Xcode project is generated
from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open KeyDecoder.xcodeproj
```

Run the `KeyDecoder` scheme on a simulator or device (set a signing team for a
device). All targets build with zero warnings under `-warnings-as-errors` in CI.

### CI artifact (GitHub Actions)

`.github/workflows/ios.yml` builds on `macos-15` on every push/PR to `main`:

- **test** job — unit tests on the iPhone 17 simulator.
- **ipa** job — one artifact, the unsigned `KeyDecoder.ipa`
  (`Payload/KeyDecoder.app`, built with `CODE_SIGNING_ALLOWED=NO`).

The IPA is **unsigned** (the project assumes no paid Apple developer account).
Re-sign at install time with a free Apple ID using AltStore / Sideloadly /
Twine, or build from Xcode with your personal team for a 7-day signed build.

## Photographing a key for best results

- Take the key **off its ring**; a fob or split ring skews segmentation.
- Use a **plain, lightly textured card** (a worn white card beats a glossy
  brand-new one; shiny metallic card finishes are the hardest case).
- Lay the key **flat, fully inside the card**, blade parallel to a card edge.
- **Soft, broad light** from roughly above; avoid direct flash (specular blowout
  on metal) and side light (cast shadows). The camera overlay shows a
  "too tilted / too dark / hold steady" hint while framing.
- Fill the frame: the card should cover most of the screen.
- Any measurement you are unsure about can be adjusted manually on the review
  screen — every automatic step has a manual path.

## Architecture

```
KeyCore (framework, no UI)        KeyDecoderApp (SwiftUI, MVVM)
├── Geometry / Homography3        ├── Capture/  camera + card editor + flow
├── Perspective (warp, scale)     ├── Review/   marker overlays, manual entry
├── KeyMask (segmentation)        ├── Library/  grid/list/detail, export
├── BladeGeometry (axis,spine,    ├── Result/   code + confidence
│   head, column profile)         ├── Model/    SwiftData + on-disk JPEGs
├── CutMeasurement (grid, digits) ├── Settings/ biometric lock, JSON import
├── AutoSuggest (system fit)      └── Support/  Info.plist, legal notice
├── MeasurementPipeline
└── KeySystem (+ keysystems.json)
```

- **The CV pipeline is a separate pure-function module** (`KeyCore`): image in,
  measurements out; no UIKit/SwiftUI imports; everything computed in real units
  derived from the card scale (`ALGORITHM_SCALE_PX_PER_MM = 2600 / 85.60`), never
  in raw pixels. `docs/ALGORITHM.md` is the normative spec — step-for-step,
  including every threshold and the headless-blob direction heuristic.
- **Vision vs. OpenCV:** only *card rectangle detection* uses Apple's Vision
  (`VNDetectRectanglesRequest`) — it is excellent at that one job and is
  on-device, dependency-free and OS-supported. Everything else (segmentation,
  blade geometry, cut measurement) is small deterministic pure Swift so the
  tests below can exercise the exact shipped code with synthetic images.
  OpenCV was rejected as a dependency: cross-compiled binary weight, supply-chain
  surface, and it would not have improved the hard cases (glare is handled by
  guidance + manual paths, not by a fancier threshold).
- **Units:** all measurements are inches/mm from the card calibration. The depth
  sampling window is `min(0.012 in, 0.25 × spacing)` centered on each cut so the
  average never includes the V-ramp flanks (see `docs/ALGORITHM.md` §4).
- **Storage:** SwiftData; JPEGs stored on disk in Application Support, referenced
  by filename. CloudKit iCloud sync is intentionally not implemented in v1 (it
  would require an entitlement-backed container; there is no partial free tier
  worth half-implementing) — the JSON export/import is the backup path.
- **Privacy:** no network permission is even requested; there are no URLs in the
  app. Camera/photo-library usage strings state exactly why they are needed.
- **Accessibility:** Dynamic Type throughout, VoiceOver labels on every control,
  light/dark support, and a reduced-motion-respecting UI.

## Key systems (data-driven)

Systems live in `KeyCore/Resources/keysystems.json` — no code changes needed to
add one. Each definition carries: id, name, brand, manufacturer code, alignment
(`shoulder` or `tip`), pin count, first-cut offset, spacing, increment,
first/last code, per-code depth table, blade width, cut width, MACS, status and
a `sources[]` note per number.

**To add a system:** append an entry with `"status": "draft"`, run the app, and
verify against a real key you own before promoting it to `"verified"`. The v1
drafts included for Yale Y114, Sargent R6, Arrow B and Master standard are
deliberately marked draft because their numbers were not verified against a
manufacturer sheet for this project.

## Tests

```bash
xcodebuild test -project KeyDecoder.xcodeproj -scheme KeyDecoder \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

- Unit tests: depth-table lookup (exact / boundary / out-of-table), geometry and
  homography round-trips, card-aspect gate, signal helpers, JSON/CSV export and
  import round-trips (including duplicate-skip and on-disk photo rewrites).
- **Synthetic ground truth:** `Tests/SyntheticKeyTests.swift` draws cards + keys
  with known bittings at the exact pipeline scale, warps them through a known
  perspective quad, and requires end-to-end recovery — clean, noisy, gradient,
  shadowed, headless and low-res cases — plus "clean synthetic cuts must not be
  flagged" (the confidence flags must stay silent when the fit is solid).
- The CV algorithm was prototyped and measured in Python/OpenCV first (see
  `docs/PROTOTYPE_RESULTS.md`); the Swift port keeps the same math and the same
  tests. What runs where is stated honestly in that document.

## Accuracy

The depth digit for every cut should be correct on well-taken photos; near a
depth boundary the cut is marked with a warning and the manual path is offered.
The app never presents a guessed code as certain: per-cut confidence comes from
the distance (in increments) to the nearest depth-table boundary, plus
grid-fits-blade and blade-length sanity checks.

## Known limitations

- Signed distribution is out of scope: no paid developer account means the CI
  IPA must be re-signed for install (AltStore/Sideloadly) or built in Xcode.
- Automatic card detection needs Vision (iOS 17+); detection quality drops on
  glossy/metallic card finishes — the manual four-corner path exists for this.
- One key per photo. Partially visible keys and keys hanging off the card give
  warnings rather than measurements.
- Colored-plastic key heads are handled by the blade-only blob fallback, but a
  head whose color matches the card can still defeat segmentation — manual
  review (or re-shooting on a different card) is the recovery path.
- Worn/rounded cut roots measure shallow-biased by a few thousandths; the review
  screen's per-cut flags make this visible rather than silently "corrected".
- Mac-type bitting (Paracentric/high-security) and dimple/laser keyways are not
  measurable from a single top-down photo; they are out of scope.

## Unverified checklist

Things to check with real keys before trusting the numbers:

- [ ] Every published KW1/SC1 number in `keysystems.json` against a current
      manufacturer/locksmith spec sheet (values and sources are inline; the
      KW1 spacing 0.150 in vs. the commonly-copied 0.153 in is the main fork —
      documented in the JSON source note).
- [ ] Real-photo accuracy across lighting conditions (the synthetic suite is
      ground truth, not a substitute for camera noise, grain, and glare).
- [ ] SC1 on 6-pin blanks and on keyways where literature disagrees
      (0.156 in spacing is contested by some sources for certain 6-pin SC10 keyways).
- [ ] Devices: iPhone 15/16/17 camera pipeline, macro distance behavior.
- [ ] Draft systems (Yale/Sargent/Arrow/Master) — verify or delete before
      shipping them as anything but draft.
