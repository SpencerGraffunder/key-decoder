# SOURCES — published bitting data per keyway

Cross-check record for every number shipped in `KeyCore/Resources/keysystems.json`.
Conventions: root depths measured from the blade bottom/spine to the cut root; first cut
(TFC) from the shoulder to first-cut center; spacing (BCC) center-to-center; codes read
bow-to-tip unless noted. Pages fetched 2026-10-31. Where the exact wording is from a
search-engine OCR of a scanned PDF it is marked *(OCR)*.

---

## KW1 — Kwikset Classic

**Shipped:** 5 pin · first cut .247 · spacing .150 · increment .023 · depths 1–6 =
.329/.306/.283/.260/.237/.214 · MACS 4 · cut width .080 · shoulder stop.

- https://www.lockwiki.com/index.php/Kwikset_Classic
  -> Keying table: cut positions ".247, .397, .547, .697, .847, .997" (exact .150 deltas);
  depths 1–6 .329→.214; summary row "1176, KW1 | ~.498 | .247 | .150 (Root to Root) |
  .023 (Depth Increment) | .080 (Cut Width) | 4"; "five pin stacks"; "MACS of 4";
  seventh depth (".191") only with master pins/construction balls.
  -> **agrees** with every shipped value.
- https://bryan-wendt.com/docs/resources/pinning-specs
  -> Kwikset row: pin .115, increment .023, depths 1–6 (.329–.214), MACS 4, 90°,
  flat .050, shoulder stop, TFC .247, BCC .150.
  -> **agrees**, except root **flat** .050 vs shipped cut **width** .080 — these are two
  different quantities (cut-root flat vs saw kerf); not a contradiction but the app must
  document which one `cutWidthIn` means.
- https://sac.user.atomicradi.us/home/Main/LockPinSizes
  -> "First cut .247\" from shoulder, .15\" centers, .023\" increment, MACS 4,
  progression 1"; depth table 1 .329 … 6 .214, plus 7 = .191.
  -> **agrees**.
- http://lsamichigan.org/Tech/Kwikset_KeySpecs.pdf (scanned Kwikset factory key-spec sheet)
  -> *(OCR)* "MACS: 4 … increment: .023 … progression: single step … blade width: .335 …
  depth tolerance + .003 … spacing tolerance ±.004"; cut-position stack ".247 / .397 /
  .547 / (.697) / .847"; bottom pins 1 .172 … 6 .287; notes older Kwikset .031 depth
  system (Corbin/Russwin residential 1966–1992 reuse note).
  -> **agrees** on increment/MACS/positions/depths; scanned sheet read via OCR, verify
  against a paper copy when possible.
- https://www.yumpu.com/en/document/view/28923900/ilco-ezar-code-card-reference-application-guide-english-kaba-ilco
  (Kaba/Ilco official "Ilco EZ-Code Card Reference/Application Guide")
  -> North American cylinder data cards: "Kwikset A1176 2279 .247 .150 .023 .329 1-7 A 0"
  (columns: stop-to-first-cut, spacing of cuts, depth increment, depth of first cut,
  number of depths). Ilco's machine database publishes **spacing .150** for Kwikset.
  -> **agrees**. (Titan row also .150 spacing.)
- https://www.framon.com/pdfs/manuals/Framon-Depth-and-Space-Manual.pdf
  + https://mbausa.com/content/Framon-2-Code-Machine-Information.pdf
  -> Framon Code Machine spacing-block inventory: block #1 includes .156; block #2
  includes .150; blocks #1–#6 contain **.150, .155, .156, .157, .1615 … — no .153 block
  exists** in the published list.
  -> **agrees** with .150; positive evidence against a machine-published .153.
- https://www.americankeysupply.com/pages/pin-size-key-depth-reference-005
  -> "Kwikset | MACS = 5 | .023\" depth increment | .247\" to first cut | .150\" between
  cut centers".
  -> **agrees** except MACS: publishes **5** where factory sheet/lockwiki/atomicradi/
  bryan-wendt say **4**. Shipped 4 (majority + factory).
- http://www.2gatherup.com/locks/pins.jsp
  -> "Kwikset KW1 (5 pins 1 through 6 MACS 4)" bitting generator.
  -> **agrees** (pin count, codes, MACS).
- https://clksupplies.com/products/kwikset-kw1-space-depth-keys
  -> KW1 space & depth set "Spaces: 5 — Depths: 1-7" (set sold to depth 7).
  -> **agrees** on 5 cuts; extra depth #7 = construction/master-key depth (.191), not in
  shipped array — see open questions.
- https://notes.abgup.com/manufacturing/tools/lockpicks/pin-tumbler-locks/
  -> "KW1 … Center-to-center spacing 0.123\"" (derived as pin dia 0.115 + 0.008 clearance).
  -> **differs** — this is pin-chamber pitch/clearance arithmetic, not the published
  cut-to-cut spacing; rejected as out-of-spec for this quantity.

**KW1 spacing verdict (.150 vs .153):** **Ship .150.** Kwikset's own spec positions
(.247→.397→.547→.697→.847, exact .150 deltas), Ilco data card 2279 (.150), lockwiki
(.150 root-to-root), AKS (.150), atomicradi (.15), bryan-wendt (.150), and the absence of
any .153 spacing block in Framon's published inventory all say .150. **No manufacturer or
key-machine publication found that prints .153 for Kwikset**; the only .153 seen anywhere
is Weslock's spacing in bryan-wendt's matrix (likely source of the mix-up). A legacy
"Universal" key-machine setup chart
(https://a-us.storyblok.com/f/1015476/x/15122f1359/universal-manual.pdf) lists Kwikset
1176 with TFC .247 and depths 1–7 but its space-disc column OCRs ambiguously ("150"/"180")
— treat as too noisy to cite either way.

**Cross-check verdict: VERIFIED** — every shipped value independently published by ≥3
sources incl. the Kwikset factory sheet and Ilco's own machine data; the .153 variant is
unsourced and rejected.

---

## SC1 — Schlage Classic (5-pin and 6-pin)

**Shipped:** 5 or 6 pin · first cut .231 · spacing .156 · increment .015 · codes 0–9 =
.335/.320/.305/.290/.275/.260/.245/.230/.215/.200 · MACS 7 · blade width .343 ·
cut width .070 (see caveat) · depth tol +.002/−0 · spacing tol ±.001.

- https://commercial.schlage.com/content/dam/allegion-us-2/web-files/schlage/technical-documents/Schlage_Primus_Service_Manual_108482.pdf
  (Schlage factory service manual; identical table also in
  https://commercial.schlage.com/content/dam/allegion-us-2/web-files/schlage/technical-documents/Schlage_Everest_Full_Size_Cylinder_Service_Manual_108484.pdf,
  http://lsamichigan.org/Tech/SchlagePrimusSvcManual_06-26-13.pdf and the scan
  http://lsamichigan.org/Tech/SCHLAGE_KeySpecs.pdf)
  -> "MACS = 7 · Increment: 0.015\" · Progression: Two Step · Blade Width: .343\" ·
  Depth Tolerance: + .002\" - 0 · Spacing Tolerance: ± .001\" · Root Depths 0 .335 …
  9 .200", cut positions ".2310 / .3872 / .5434 / .6996 / .8558 / 1.0120" (deltas
  .1562 ≈ .156), 100° angle, root flat .031, "Cuts are read and written bow to tip."
  -> **agrees** with all shipped geometry; .156 is the rounded published spacing (exact
  cumulative positions are +.1562 per cut).
- https://mbausa.com/content/Framon-2-Code-Machine-Information.pdf
  -> "Schlage cylinder keys use .231\" starting cut and .156\" spacing."
  -> **agrees**.
- https://www.framon.com/pdfs/manuals/Framon-Depth-and-Space-Manual.pdf
  -> worked Schlage example: starting cut .231 from shoulder, spacing block ".156"
  ("The starting cut for Schlage is .231 from the shoulder… rotate spacing block until
  .156 spacing side is up"); #2 depth .305.
  -> **agrees**.
- https://bryan-wendt.com/docs/resources/pinning-specs
  -> Schlage Classic: .115 pin, .015, 0–9 (.335–.200), MACS 7, 100°, flat .031,
  TFC .231, BCC .156.
  -> **agrees**.
- https://www.lockpicking101.com/viewtopic.php?f=42&t=58069
  -> hobbyist CNC build post with full chart: shoulder .231, centers .156, inc .015,
  depths {0.335…0.200}, MACS 7, 100°, root width .031.
  -> **agrees** (community corroboration).
- https://github.com/ewust/keys/blob/master/Schlage%20SC1.scad
  -> OpenSCAD parametric SC1: shoulder .231, cut_spacing .156, cut_depth .015.
  -> **agrees**.
- http://www.2gatherup.com/locks/pins.jsp
  -> "Schlage Classic SC1 (5 pins 0 through 9 MACS 7)", SC4 for 6-pin.
  -> **agrees** on pin count/codes/MACS.

**Caveat:** shipped `cutWidthIn = 0.070` is **not** a Schlage-published number — the
factory sheet publishes a 100° root with **.031 flat** (kerf ≈ .07–.08 is the practical
cutter width, unsourced). See open questions.

**Cross-check verdict: VERIFIED** — matches the Schlage factory specification verbatim
across four factory documents plus two key-machine maker publications. (sc1-6p shares the
same chart; the 6th cut at .231 + 5×.156 ≈ 1.012 appears as "1.0120" in Schlage's own
position list, so the 6-pin extension is also published.)

---

## Yale Y114

**Shipped (draft):** 5 pin · first cut .214 · spacing .150 · increment .019 · codes 0–9 =
.320…(.019)…→ .149 · MACS 4 · cut width .034.

- https://bryan-wendt.com/docs/resources/pinning-specs
  -> "Yale Standard | .115 | .019 | 0–9 (.320\"–.149\") | 4–5 | 90° | .034 | Shoulder |
  .214 | .150".
  -> **agrees** — this is the sole source for the shipped row.
- https://www.assaabloy.com/hk/en/product-assets/cylinder/yale4/assets/documents/Yale_Cylinders_and_Keys_Catalog.pdf
  (Yale "Cylinders and Keys" / Cylinders & Keying Manual; mirrors:
  https://www.grainger.ca/ec/pdf/Cylinders-And-Keying-Manual.pdf,
  https://media.topnotchinc.com/docs/catalogs/Cylinders%20and%20Keys.pdf)
  -> Yale **.019** family: "MACS: 5* · Increment: .019\" · Progression: Two Step ·
  Blade Width: .320\" ± .002\""; depths "0 .320 … 9 .149"; cut centers from shoulder
  ".200 / .365 / .530 / .695 / .860 / 1.025 / 1.190" (**spacing .165**); label
  "95° .054\" .165\""; 7 pin positions shown; bottom pins .182… .353.
  -> **differs from shipped**: TFC **.200** (not .214), spacing **.165** (not .150),
  MACS **5** (not 4), root flat **.054** at **95°** (not .034/90°). Depths and increment
  **agree**.
- https://sac.user.atomicradi.us/home/Main/LockPinSizes
  -> "First cut .206\" from shoulder, .165\" centers, .019\" increments, MACS 7,
  progression 2"; depths 0 .320 … 9 .149.
  -> depths/increment **agree**; TFC .206 and BCC .165 **differ** from shipped; MACS 7.
- https://www.americankeysupply.com/pages/pin-size-key-depth-reference-005
  -> "Yale | MACS = 5 | .019\" depth increment | .206\" to first cut | .164\" between cut
  centers"; depths .320→.149.
  -> depths/increment **agree**; TFC .206 / spacing .164 / MACS 5 **differ** from shipped
  (cluster with official, not with shipped).
- lsamichigan Tyler J. Thomas, *Key Bitting Specifications*
  (http://lsamichigan.org/Tech/KeyBittingSpecifications-TylerJThomas.pdf, "Yale .019" p. 81)
  -> *(OCR)* "Increment: .019 … T.F.C: .200\" … B.C.C: .165\""; depths 0 .320 … 9 .149;
  bottom pins .182–.353, masters .038–.152.
  -> **agrees** with the factory manual, **differs** from shipped TFC/spacing.
- Naming check: https://www.yalehome.com/it/en/products/mechanical/padlocks/rectangular-padlocks/y114-series
  and https://www.bellittiserrature.it/docs/cataloghi/YALE.pdf
  -> "Y114" is Yale's European rectangular brass **padlock series**; catalog lists
  "N. Perni 5" (5 pins) and key blanks Y114/50/100, Y114/80/100, YPADBLANK5/6. Confirms
  the Y114 name = 5-pin EU padlock, **not** the US .019 cylinder family; no published
  bitting depth/space chart found for the EU Y114 blank.

**Cross-check verdict: CONFLICT** — the shipped geometry (TFC .214, spacing .150, MACS 4,
flat .034) is found **only** in bryan-wendt; Yale's own factory chart and three
independent charts put the .019 family at TFC .200 (or .206), spacing .165/.164, MACS 5
(atomicradi: 7). Only increment .019 and the depth ladder .320→.149 (codes 0–9) are
robust. The "Y114" name itself denotes the EU padlock line (5-pin per Yale catalogs),
whose bitting data is unpublished. **Shipped row needs re-derivation** — see open
questions.

---

## Sargent R6 (SARGENT R-family keyway)

**Shipped (draft):** 6 pin · first cut .215 · spacing .156 · increment .020 · codes 1–9 =
.330/.310/.290/.270/.250/.230/.210/.190/.170 · MACS 7 · cut width .050.

- https://objects.eanixter.com/PD512437.PDF (SARGENT "Cylinders and Components" official
  catalog; mirrors:
  https://plytix-files.com/api/v1.1/file/public_files/pim/assets/82/7f/a7/5d/5da77f82f33326bf4de6241c/texts/fc/85/65/68/686585fc92c536b9cc931e0a/SARGENT_Cylinders_and_Components_Catalog.pdf,
  https://www.allmar.com/products/data/uploads/Sargent_Conventional_Cylinder_Catalogue.pdf,
  https://store.jlmwholesale.com/Documents/SARGENTCYLDATA.pdf)
  -> "Cut# 1 2 3 4 5 6 7 8 9 10 / X .330 .310 .290 .270 .250 .230 .210 .190 .170 .150 ·
  Depth tolerance ± .002\", spacing tolerance ± .001\" · Above bitting dimensions are for
  SARGENT cylinders in the following keyway families: A, B, C, G, H, K, L, N, R, V ·
  6 PIN POSITIONS Shown, depth and spacing are the same for 5 & 7 pin · SMALL FLAT .051"
  (78°/79° angles on drawing); plytix copy adds "Note: Maximum Adjacent Cut Specification
  (MACS) = 7". Bottom pins #1 .170 … #10 .350, all .115 dia.
  -> **agrees** with shipped increment/spacing-range/MACS/depths 1–9 (official extends to
  code 10 = .150); root flat **.051** vs shipped .050 (trivial).
- https://www.locksmithledger.com/keys-tools/article/10294115/sargent-key-cutting-by-locksmith-unlimited
  -> "Official Sargent dimensioning from shoulder to first cut is **.215 +/- .001** and
  cut-to-cut spacing is **.156**. Sargent sectional keyways use depth increments of
  **.020**. The official Sargent depth for a '1' cut is **.330 +/- .002**." MACS 7.
  -> **agrees** with shipped values; explicitly resolves the .215-vs-.216 / .330-vs-.328
  dispute in the factory's favor.
- https://trea.com/information/manual-punch-press-for-keys/patentgrant/0fbaf227-cbe4-440a-bb33-341fa5c5ad44
  (US patent, Pro-lok Blue Punch improvement)
  -> "the center line of the first position P 1 is exactly **0.215** inches from the top
  shoulder. The incremental spacing is **0.156** inch"; "incremental depth of cut is
  **0.020** inch"; blank top-to-bottom 0.330 so code 1 = .330 root, codes → 0.150;
  pins "51 mil wide flat bottom and a 78-79° bottom angle"; MACS seven.
  -> **agrees**.
- https://sac.user.atomicradi.us/home/Main/LockPinSizes
  -> "First cut .216\" from shoulder, .156\" centers, .02\" increment, MACS 7"; depth
  table 1 .328 … 9 .168, 10 .148.
  -> **agrees** on spacing/increment/MACS; **differs** by −.001 TFC and −.002 on every
  depth vs the official set (a widely-repeated older chart; same offset in AKS below).
- https://www.americankeysupply.com/pages/pin-size-key-depth-reference-005
  -> "Sargent | MACS = 7 | .020\" depth increment | .216\" to first cut | .156\" between
  cut centers"; depths .328→.148.
  -> **agrees** with the −.002/.−.001 chart cluster; **differs** from official by that
  offset.
- https://bryan-wendt.com/docs/resources/pinning-specs
  -> Sargent: .020, 1–9 (.330–.170), MACS 7, flat .050, TFC .215, BCC .156.
  -> **agrees** (matches official numbers).
- https://idoc.pub/documents/new-15-bumpkey-template-and-instructions-diskkkt-qn8528ymxyn1
  -> community depth/space template: "STD Sargent .216 / .156 / #10 .148".
  -> **agrees** with the −.001/−.002 cluster (informational).
- R6 naming: https://thebuilderssupply.com/abh-6750-standard-trim-for-non-abh-mortise-lock-sargent-r6-7a0s0a-strike-satin-brass
  -> door-hardware convention: "6750: Sargent®, Trim Only, **R6** …" — "R6" is the
  retrofit keyway/cylinder code for Sargent (R-family, 6-pin) mortise cylinders.
  -> supports R6 = SARGENT R-family 6-pin; **needs cross-check** against SARGENT's own
  catalog keyway tables (SARGENT lists R sections like RA…RM; "R6" itself is the
  hardware-industry code).

**Cross-check verdict: VERIFIED** for the geometry (increment .020, spacing .156, TFC
.215, codes .330→.150, MACS 7, .051 flat/78–79°) — SARGENT's own catalog appears in four
mirrors plus a US patent and trade-press confirmation of the exact TFC. Note the
persistent alternate chart cluster (.216 / 1 = .328) that is −.001/−.002 off official;
shipped follows official. **Needs cross-check:** 6-pin count for "R6" (retail-hardware
convention only; R-family ships in 5/6/7-pin bodies).

---

## Arrow B / LA (Arrow conventional large-pin)

**Shipped (draft):** 5 pin · first cut .264 · spacing .155 · increment .014 · codes 0–9 =
.324/.310/.296/.282/.268/.254/.240/.226/.212/.198 · MACS 7 · cut width .052.

- https://s3.amazonaws.com/s3-absupply-net/pdf/arrow_conventional_key_specifications.pdf
  (Arrow Conventional caliper sheet, extracted from PDF)
  -> Depths (to blade bottom): 0 .312 · 1 .298 · 2 .284 · 3 .270 · 4 .256 · 5 .242 ·
  6 .228 · 7 .214 · 8 .200 · 9 .186 (= .014 step). Spacing, top shoulder to cut center:
  1 .265 · 2 .420 · 3 .575 · 4 .730 · 5 .885 · 6 1.040 (= **.155** step, **TFC .265**).
  -> **agrees** on increment/spacing; **differs** from shipped depths (−.012 across the
  board) and TFC (.265 vs .264).
- https://sac.user.atomicradi.us/home/Main/LockPinSizes
  -> "First cut .265\" from shoulder, .155\" centers, .014\" increment, MACS 7,
  progression 2"; depths 0 .312 … 9 .186; masters .028/.056/.084/.112.
  -> **agrees with Arrow's sheet**, **differs** from shipped depths/TFC.
- https://www.americankeysupply.com/pages/pin-size-key-depth-reference-005
  -> "Arrow | MACS = 7 | .014\" depth increment | .265\" to first cut | .155\" between
  cut centers"; depth column ends 8 = .200, 9 = .186.
  -> **agrees with Arrow's sheet**, **differs** from shipped depths.
- lsamichigan Tyler J. Thomas *Key Bitting Specifications* (Arrow pages;
  http://lsamichigan.org/Tech/KeyBittingSpecifications-TylerJThomas.pdf)
  -> *(OCR)* "8 .200 / 9 .186 … B.C.C: .155\" … Bottom Pins .180 .194 .208 … .306 …
  Master Pins .028–.126".
  -> **agrees with Arrow's sheet**, **differs** from shipped depths.
- https://bryan-wendt.com/docs/resources/pinning-specs
  -> Arrow: .014, 0–9 (**.324–.198**), MACS 7, flat .052, TFC **.264**, BCC .155.
  -> matches **shipped** — the shipped depth table traces to this row alone; its depths
  sit .012 above Arrow's own factory sheet (unexplained by any other source).
- https://foleybelsawlocksmithing.com/products/arrow-ar4-depth-and-spacing-key-set-0-9
  -> "Arrow AR4 Large Pin … .014\" increments. Cut on a 6 pin AR4 1179A key blank but
  will also work on E,F,G,H,J,K,L,P and R sections. Arrow New Large Pin depths."
  -> **agrees** on .014 increment and keyway-family breadth (depths implied = the
  .312-based "New Large Pin" chart).

**Cross-check verdict: CONFLICT** — shipped depths (.324→.198) and TFC .264 come only
from bryan-wendt; Arrow's factory caliper sheet plus atomicradi, AKS and Tyler-Thomas
consistently publish **0 = .312 → 9 = .186 with TFC .265** (spacing .155 and MACS 7 are
consistent everywhere). Recommend re-shipping Arrow on the factory table. "Arrow B/LA"
naming is itself unresolved — see open questions.

---

## Master Lock standard padlock (No. 3 / No. 175 style, 1K/17K blanks)

**Shipped (draft):** 4 pin · first cut .185 · spacing .125 · increment .015 · codes 0–7 =
.285/.270/.255/.240/.225/.210/.195/.180 · MACS 4 · cut width .040.

- https://cdn.masterlock.com/masterlock/resources/documents/pdf/keying/7000-0031_Technical_Manual_pg_25.pdf
  (Master Lock Commercial Security Products Technical Manual, "Bitting Specifications"
  p. 25 — table extracted from PDF text)
  -> "1K | .281 | 0 .2720 · 1 .2565 · 2 .2410 · 3 .2255 · 4 .2100 · 5 .1945 · 6 .1790 ·
  7 .1635 | Spacing Stop To First Cut **.187** | Spacing Cut To Cut **.125** | Used in
  Master Lock 1,2,3,4,5,6,11,77,33,34,35,36,37,39,425,475" (step .0155). Same depth
  column and .187/.125 for 15K (No. 15), 17K (No. 17), 27K (Nos. 21–31,101,220,230),
  2K (MK variants), 900K (retail contractor grade). No MACS published for these blanks.
  -> **agrees** on spacing .125 and 8 codes (0–7); **differs** from shipped: depth column
  **.2720→.1635** (not .285→.180), TFC **.187** (not .185), step **.0155** (not .015).
- https://cdn.masterlock.com/masterlock/resources/documents/pdf/7000-0031_Technical_Manual.pdf
  (full manual, also via https://cdn.masterlock.com/masterlock/resources/documents/pdf/Master-Lock-Commercial-Technical-Service-Manual.pdf)
  -> "Master Lock keys are coded from bow to tip and with a few exceptions, the increment
  used is **.0155\"**."
  -> **agrees** with pg-25 table; **differs** from shipped .015.
- https://bryan-wendt.com/docs/resources/pinning-specs
  -> "Master Lock (Standard) | .093 / .115 | .015 | 0–7 (.285–.180) | MACS 4 | 90° |
  .040 | Shoulder | .185 | .125".
  -> matches **shipped** — sole published source for the shipped variant of this row;
  conflicts with Master's own table on depths/TFC/increment; only source seen that gives
  a MACS (4) for standard Master keyways.
- https://kstoerz.com/locksport/bitting
  -> decoder utility lists system "Master 1K, 2K, 15K, 17K, 27K, 52K, 81KM, 900K
  (caveat emptor!!)" — confirms the blank-family naming used above (tables are
  script-loaded; not quoted).
  -> informational.
- Pin count, No. 3: https://www.motion.com/products/sku/02623715 -> "Number Of Pins 4 …
  Four-pin cylinder … Series No 3"; and https://cdn.webshopapp.com/shops/34658/files/234456397/masterlock-catalgoue-de-en.pdf
  (Master Lock catalogue) -> "■ 3 — 4-pin cylinder with reserved key profile and 1,400
  unique safety key codes".
  -> **agrees**: No. 3 = 4-pin (2 independent sources).
- Pin count, No. 175: not stated in the technical manual's bitting table (175 does not
  appear in the 1K model list; 17K covers No. 17). **Needs cross-check** — commonly said
  to be 4-pin, but no manufacturer spec found here.

**Cross-check verdict: CONFLICT** — the shipped row (depths .285→.180, TFC .185, .015,
MACS 4) is single-sourced (bryan-wendt) and conflicts with Master's own technical manual
for the classic padlock blanks (.2720→.1635, .0155 step, TFC .187). Spacing .125 and No.
3 = 4-pin are the only independently confirmed values. Re-ship from 7000-0031 p. 25
(1K row) before promotion; MACS stays **SINGLE-SOURCE** either way.

---

## ISO/IEC 7810 ID-1 (card size reference)

**Shipped/used:** 85.60 × 53.98 mm.

- https://webstore.iec.ch/en/publication/11595 (IEC publication page for ISO/IEC
  7810:2003, official abstract)
  -> "four different sizes of identification cards with a nominal thickness of 0,76 mm
  and dimensions of: ID-000 25 mm x 15 mm, **ID-1 85,60 mm x 53,98 mm**, ID-2 105 mm x
  74 mm, ID-3 125 mm x 88 mm".
  -> **agrees** — citable official-source quote.
- https://en.wikipedia.org/wiki/ISO/IEC_7810 (live page fetched)
  -> "ID-1 format specifies a size of 85.60 by 53.98 millimetres (3+3⁄8 in × 2+1⁄8 in)
  and rounded corners with a radius of 2.88–3.48 mm"; thickness "760±80 μm"
  (0.68–0.84 mm); aka CR-80 / TD1.
  -> **agrees**.
- https://www.iso.org/standard/70483.html (ISO/IEC 7810:2019, 4th ed., current)
  -> standard's catalog entry (full text paywalled; dimensions per 2003 abstract above
  are unchanged in 2019 for ID-1).
  -> pointer citation for the current edition.

**Cross-check verdict: VERIFIED** — 85.60 × 53.98 mm per ISO/IEC 7810 ID-1, quoted from
the official IEC abstract and corroborated by Wikipedia (which also gives corner radius
and thickness tolerances).

---

## Open questions

1. **Yale identity:** decide whether the app targets the US Yale .019 cylinder family
   (factory chart: TFC .200, BCC .165, MACS 5, blade .320, 95°/.054 root, codes 0–9
   .320→.149, 5/6/7 pin) or the European Y114 padlock line (5-pin per Yale catalog,
   flat nickel-plated blank, bitting chart **unpublished**). Shipped row is re-derivation
   required either way; it currently copies the one outlier source.
2. **Arrow depth table:** shipped .324→.198 @ TFC .264 (bryan-wendt-only) vs factory
   .312→.186 @ TFC .265 — recommend adopting the factory sheet; verify on a real AR1/AR4
   key with calipers. Also resolve "Arrow B / LA": conventional B-section (large-pin
   .014 chart above) vs SFIC "B" keyway (Best A2, .0125 increment, tip-stop) — completely
   different geometry.
3. **Master row:** re-ship from 7000-0031 p.25 (1K: .2720→.1635 step .0155, TFC .187,
   BCC .125, bow-to-tip); MACS (4) is single-sourced; confirm No. 175 pin count and key
   blank (175 not listed in 1K model list; 17K covers No. 17).
4. **Sargent depth datum:** two published clusters — official .330/TFC .215 vs widely
   copied .328/TFC .216. Shipped uses official; a caliper check on a factory Sargent key
   should settle it. Also confirm "R6" 6-pin claim against a SARGENT cylinder catalog
   keyway table (R sections ship 5/6/7-pin).
5. **SC1 `cutWidthIn` 0.070** is not a Schlage-published number (factory sheet: 100°
   root, .031 flat). Decide whether the field means cutter kerf or cut-root flat and
   label it in the README/schema; same ambiguity for KW1 (.080 kerf per lockwiki vs .050
   flat per bryan-wendt).
6. **Kwikset MACS 4 vs 5:** American Key Supply prints 5; factory sheet/lockwiki/
   atomicradi/bryan-wendt print 4. Shipped 4; note the dissent.
7. **Depth 7 on KW1:** factory/lockwiki/CLK list a 7th depth (.191) used with master
   pins/construction balls — should the decoder flag code 7 as out-of-normal-range
   rather than invalid?
8. **Sargent codes 10 / "0":** SARGENT chart runs to cut 10 = .150 and keys exist with
   "0"/10 cut codes; shipped array stops at 9 (.170). Add code 10 if R keys with 10 cuts
   are in scope.
9. **Tyler J. Thomas, *Key Bitting Specifications*** (lsamichigan PDF) has dedicated
   pages (Kwikset .023 p.57, Master 1176 p.62, Sargent .020 p.74, Yale .019 p.81) and is
   a strong second-pass authority; only OCR excerpts were accessible this pass — pull the
   full PDF and reconcile the Arrow/Yale/Master rows against it.
