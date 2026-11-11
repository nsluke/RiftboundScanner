# RiftboundScanner

A prototype recogniser for [Riftbound](https://playriftbound.com) (Riot's League of
Legends trading card game) cards, written in Swift. Give it a photo of one card and
it names the printing: set, collector number, alternate-art or signature variant.

It exists so that a TCG Archivist CSC100 feeder, which is only a Bluetooth-driven
card feeder plus a phone stand, can be driven by a custom iOS app that recognises
Riftbound cards instead of Magic ones. The recogniser is the half that needs no
hardware; the CoreBluetooth feeder driver is a separate piece.

Two targets live in this package:

- **`RiftboundRecognizer`**, a library that uses only Foundation, CoreGraphics,
  Core Image, ImageIO, Accelerate, CryptoKit and Vision, so it drops into an iOS
  app unchanged.
  `Scripts/check-platform-neutral.sh` fails the moment a UI framework is imported.
- **`riftscan`**, a macOS command-line tool around it: `riftscan identify photo.jpg`
  prints the top matches with scores, and the other subcommands build the index,
  generate a synthetic test set and measure accuracy.

## How it works

1. **Locate.** Vision's `DetectRectanglesRequest` finds card-shaped rectangles.
   Candidates are ranked by confidence, closeness to the 63 : 88 card aspect ratio
   and size, because the detector also reports the card's inner frame, its
   illustration, and rectangles merged with background edges. In a cluttered
   scene the detector can lose the card completely (an ablation on the synthetic
   set showed background clutter, not blur, noise, lighting or rotation, is what
   defeats it), so Vision's objectness saliency is run as well: its box around the
   most salient object, combined with the known card aspect ratio, fixes the card's
   size and rotation angle but not the rotation direction, so two fitted quads are
   added as lower-confidence candidates.
2. **Hypothesise.** Each rectangle candidate is tried as found *and* expanded
   outwards by the printed frame's measured insets (the detector often locks onto
   the gold inner frame, and the set/collector code is printed outside it in the
   black border); saliency-fitted quads are already the card's outline. The whole
   image is tried last, which is what wins for an already-cropped input, but it
   only competes with located cards when its best descriptor score reaches 0.8:
   a photo's background routinely scores a coincidental 0.6–0.7 against some
   unrelated printing, which must not outrank a located card. Every hypothesis is
   rectified and scored on descriptors; the best two also get OCR, and the
   hypothesis whose best match scores highest is reported.
3. **Rectify.** `CIPerspectiveCorrection` warps the quad onto a fixed 756 × 1056
   portrait canvas (exactly 63 : 88). A card lying on its side is turned portrait
   first; landscape Battlefield cards are indexed turned a quarter turn clockwise, so
   every entry is portrait like the physical card.
4. **Describe.** On the canvas, and again on the canvas turned 180° (a feeder takes
   cards either way up): a difference hash and a DCT perceptual hash of the whole
   card, a difference hash of the illustration region, and Vision's 768-element
   image feature print.
5. **Search.** Brute-force nearest neighbours over the index (1,408 printings is
   about a million multiply-adds). Score = 0.5 · feature-print cosine + 0.2 · dHash +
   0.15 · pHash + 0.15 · art dHash, each similarity in 0…1. The best of the two
   rotations is kept per entry, which also tells us the card's orientation.
6. **Read the code.** `RecognizeTextRequest` OCRs the four edge bands of the canvas
   (bottom, top, left, right, each rotated upright). Whichever band yields a code
   like `OGN • 007a/298`, `OGN • 299*/298` or `RAD • R01 • EN` confirms the
   orientation and the layout. A lenient parser repairs the usual misreads
   (`0GN`, `OO1`, missing separators) against the index: a reading counts only
   when some printing carries that set, number and variant *and* its denominator
   does not contradict the set (`VEN • 040/221` is a misread, since `/221` is
   Spiritforged's; `068/266`, a denominator no set prints, is just a misread
   denominator and the key stands), so a shape-valid number no card has
   (`VEN-R040`) reads as no code. The parser also lists the index-known codes
   one digit confusion away from the reading (`1` ↔ `2`, `7` ↔ `1`, the misread
   measured on real scans: `024` for `014`), ranked, as **alternatives**; the
   reading records whether its code is the **literal** text or such an
   alternative (taken when the literal text names no printing). A guess is only
   ever positive evidence: it credits the card it names and penalises nothing.
7. **Re-rank.** The top 12 descriptor candidates are adjusted by how the read code
   relates to theirs, scaled by OCR confidence: literal exact match +0.5, exact
   match through a digit alternative +0.3, same number but a different suffix
   (`299` vs `299*`) +0.2, same number in another set −0.15, any other
   disagreement −0.4. A confident code reading therefore outranks a slightly
   better descriptor match, which is what separates printings that share an
   illustration: standard vs signature, or the same rune reprinted in another
   set. The smaller alternative bonus lets the descriptors overrule a one-digit
   misread (the card that looks like `014` beats the `024` the OCR saw) without
   letting a guess manufacture confidence: a match through an alternative is
   flagged on the result and must never count as a confident identification.
   An optional `RecognitionHints(expectedSet:)` (a sealed box holds one set)
   adds a flat +0.05 to candidates in that set, enough to break a descriptor tie
   between same-art printings in different sets, and stops the parser from
   *repairing* a reading into another set; a cleanly read code of another set
   still counts.

8. **Learn.** Confirmed scans become *exemplars*: real-photo feature prints keyed
   by `ArtGroup` (the printing with its total and `a`/`*` suffix stripped, so every
   printing of one illustration shares them). An `ExemplarIndex` overlay fuses
   into the descriptor score as `max(reference, 0.95 · exemplar cosine)`; each
   match reports both its `referenceScore` and the fused `descriptorScore`.
   Everything that chooses *where* the card is (hypothesis ordering, the
   whole-image rule, the winning hypothesis) uses reference scores only, so
   exemplars can change which card wins but never where it was found, and an
   empty overlay changes nothing at all. Which confirmed scans become
   exemplars is decided by `ExemplarAdmission`, a pure gate (ADR-002 section 7,
   rules 1–8) that the collection server ports to Python; the two are held to
   one fixture, `Tests/Fixtures/admission-cases.json`, and one similarity
   contract. See `docs/learning-policy.md` and `docs/learning-eval.md`.

The result carries the ranked matches (each with its code agreement and whether
that agreement came from the literal reading or an alternative), where the card
was found (and its corner quad when a card was detected), the code that was read,
where it came from (an edge band of the canvas, or the whole photo as a fallback),
its literal/alternative origin and ranked alternatives, the rectified canvas, the
query descriptor in the orientation of the winning match (the one to compare
with a reference or keep as an exemplar), the engine fingerprint that produced
it, and a summary of every hypothesis for diagnostics.

## Getting started

Requires Xcode 26 or later (the Swift-native Vision API needs macOS 15 / iOS 18;
the package builds with tools version 6.2).

Fetch the community catalog and one reference image per printing. Both land in
gitignored folders (`data/cards.json`, `cache/images/`, about 1.2 GB) and are
treated as untrusted downloads: nothing is executed and each image is checked for
a PNG/JPEG signature before it is kept.

```bash
python3 -I Scripts/fetch-images.py
```

Build the index once. It reads every cached image, puts it on the canvas, computes
the descriptors in parallel and writes `cache/index.json` (about 6.4 MB; roughly
five seconds on an M-series Mac). Rebuild it whenever the catalog or the canvas
specification changes; the file embeds the card metadata, so recognition needs
no catalog at run time. The index also records the **calibration print**: the
feature print of a procedural, Riot-free card drawn by `CalibrationCanvas`, which
identifies the embedding the building machine's Vision model produced (the SDK's
`Revision` enum has one case and cannot). Indexes built before this field existed
still load; the format version is unchanged.

```bash
swift run -c release riftscan build-index
```

Identify a photo:

```bash
swift run -c release riftscan identify path/to/photo.jpg --top 3
```

```
Photo: synthetic/moderate/000-unl-157-219.jpg (1536×2048), identified in 0.41 s
Card:  rectangle detected (confidence 1.00)
Code:  UNL-157/219 read from "UNL • 157/219" (confidence 1.00, upright, portrait layout, edge band, literal)
       could also be UNL-127/219

 #  Code          Name                          Score  Desc   FP    dH    pH    Art   OCR
 1  UNL-157/219   Scrutinizing Sergeant         1.447  0.947  0.98  0.95  0.91  0.94  exact
 2  UNL-127/219   …                             0.912  0.612  …                       exact*
 …
    * matched a digit alternative of the reading, not the reading itself
```

`--expect-set UNL` passes the set hint described above. `--json` prints the same
as JSON (plus `quad`, `codeSource`, `codeOrigin` (`literal`/`alternative`),
`codeAlternatives` (best first, the read code first), `expectedSet`, the
`descriptor` orientation and digest, the `engine` fingerprint, and per match
`codeOrigin` and the `referenceScore` and `exemplarSimilarity` beside the fused
`descriptorScore`), `--verbose` lists every hypothesis that was tried, and
`--save-rectified out.png` writes the winning canvas so you can see what the
hasher and the OCR saw. `--overlay overlay.json` (or a phone-side `.bin`) fuses
learned exemplars into the scores after checking its calibration print against
this machine's, and `--policy policy.json` applies a `LearningPolicy` file
(`docs/learning-policy.md`).

Check what this machine's Vision model makes of the calibration canvas, and
whether it matches the index:

```bash
swift run -c release riftscan check-revision --index cache/index.json   # --json for machine comparison, --no-vector to skip the 768 floats
```

It prints the engine fingerprint (package version, platform, OS version), the
print's dimension and 16-byte hash, the cosine similarity to the index's stored
print, and the vector itself. Run it on the Mac and the equivalent path on the
phone to learn whether the two embed images the same way before trusting a
Mac-built index or phone-learned exemplars across the gap.

Run the tests (Swift Testing; the Vision-backed ones are tagged `vision`):

```bash
swift test
```

### Learning evaluation

The scans pulled from the phone (`scans/<batch>/`, see "Reviewing the
results") double as the recogniser's labelled test set and as the raw material
for learned exemplars. Five commands turn them into numbers; the protocol and
the measured results are in `docs/learning-eval.md`.

```bash
swift run -c release riftscan import-scans scans --output evaluation/manifest.json   # one case per human-judged scan
swift run -c release riftscan build-overlay evaluation/manifest.json --leave-one-out \
  --output evaluation/overlay.json --dump evaluation/admissions.json              # gate every scan, one overlay per held-out batch
swift run -c release riftscan evaluate evaluation/manifest.json --dump evaluation/baseline.json --label baseline
swift run -c release riftscan evaluate evaluation/manifest.json --batch <held-out batch> \
  --overlay evaluation/overlay-holdout-<prefix>.json --dump evaluation/fold.json --label fold
swift run -c release riftscan report evaluation/fold.json --baseline evaluation/baseline.json
swift run -c release riftscan admission-report evaluation/admissions.json
swift run -c release riftscan gate-diff Tests/Fixtures/admission-cases.json --server http://riftbound.lan
```

- `import-scans` reads v1 and v2 `scans.json` files, keeps the scans whose
  latest decision was made by a person (`human`, `audit`, `spotCheck`, or the
  `legacy` decision a v1 verdict stands for), labels each with the decision's
  card, weights audit cases `1 / auditRate` (the policy's, 0.3) and the rest
  1, loads each photo at 4096 px to record its size, carries the capture
  quality as the app decodes it (`legacy` when the record states none) beside
  the quality a crop record and photo size would derive, and writes a
  manifest stamped with the platform (`macOS`).
- `build-overlay` runs the Mac recogniser once over every photo, builds the
  gate's inputs (placement, code source, origin and agreement, reference
  similarity and every code alternative the reading offered against the
  index, the oriented feature print) and
  runs the Swift gate per fold: `--exclude-batch` for one fold, or
  `--leave-one-out` for one fold per batch. It prints the exemplar count per
  fold and **fails (exit 1) when a fold yields zero exemplars**, after writing
  everything. `--accept-legacy`, `--derive-capture-quality` and
  `--training-quality standard` are measurement-only relaxations for the
  pre-ledger batches (recorded in the dump; never ship an overlay built with
  them).
- `evaluate` gained `--overlay`, `--policy`, `--exclude-batch` (drop a batch's
  exemplars from the overlay), `--batch` (only that batch's cases) and
  `--dump`; it reports raw and weighted top-1/top-3, the confident tier's
  precision and coverage (with the 95 % Wilson lower bound) and how often an
  exemplar lifted the winner.
- `report` re-tallies dumps and compares each with a baseline on their shared
  cases, stating whether the shipping rule (top-1 and confident precision not
  lower than baseline) holds.
- `admission-report` prints the impostor similarity distribution (p50/p95/p99
  between scans of different art groups), the reference floor's ROC and the
  gate's outcomes by reason.
- `gate-diff` posts every gate call (the fixture's cases, or a dump's folds
  replayed) to the server's `POST /api/learning/admit/dry-run` and reports
  mismatches; exit 1 on any.

## Measured accuracy

`riftscan synth` renders reference cards into fake photographs: a cluttered
background, random scale, rotation (half of them upside down, some on their side),
perspective jitter, uneven lighting, colour temperature, exposure, glare, Gaussian
blur, sensor noise, vignetting and JPEG compression, at three severities. Every
photo is reproducible from the seed recorded in `synthetic/manifest.json`.

```bash
swift run -c release riftscan synth --count 100 --seed 42
swift run -c release riftscan evaluate synthetic            # --group harsh for one tier, --verbose for every case
```

Measured on 2026-11-03 with seed 42, 100 photos per tier, 262 distinct printings,
on an Apple-silicon Mac (macOS 26.6, Xcode 27.2):

| Tier     | Photos | Top-1   | Top-3   | What the tier throws at the card |
|----------|--------|---------|---------|----------------------------------|
| mild     | 100    | 98.0 %  | 100.0 % | card 55–75 % of the frame height, ±8°, 30 % upside down, perspective jitter ≤ 2 %, blur ≤ 0.6 px, light colour shifts and vignette |
| moderate | 100    | 96.0 %  | 98.0 %  | 40–75 %, ±20°, 50 % upside down, 10 % on their side, jitter ≤ 6 %, blur 0.5–1.8 px, glare, colour casts, JPEG quality ≥ 0.65 |
| harsh    | 100    | 72.0 %  | 79.0 %  | 30–70 %, ±35°, 20 % on their side, jitter ≤ 11 %, blur 1.5–3.5 px, vignette up to full strength, strong glare and casts, JPEG quality ≥ 0.4 |
| all      | 300    | 88.7 %  | 92.3 %  | |

Photos are 1536 × 2048 (phone photos are downsampled to 2048 px on the long side
before recognition anyway). Identification takes about 0.9–1.1 s per photo on
this machine, most of it the serialised OCR of up to two hypotheses; set
`ScoringPolicy.ocrHypothesisCount` to 1 to roughly halve that.

What the misses are:

- **mild (2):** both are printings that share their illustration with another
  (`SFD-232` vs `SFD-232*`, `VEN-195` vs `VEN-195*`). Descriptors tie, and in one
  case the OCR read the number but missed the tiny `*`, so the standard printing
  took the exact-match bonus.
- **moderate (4):** two cards the locator never found (not in the top 12), one
  signature twin, one correct card at rank 3.
- **harsh (28):** 21 are cards the locator never found; the tier's near-total
  vignette and glare defeat both the rectangle detector and the saliency box.
  None of the harsh misses had a readable code: 1.5–3.5 px of blur at 2 MP
  leaves the 2 mm code illegible, so the descriptors are on their own.

For scale, the same pipeline scored 79 % / 61 % / 35 % top-1 before the saliency
fallback and the whole-image rule were added; those two changes are what made
the difference on cluttered backgrounds.

Re-measured on 2026-11-07 on the same seed-42 set, before and after the OCR
hygiene change (index-aware vocabulary, digit alternatives, literal/alternative
split; ADR-002 P2), on the same Mac the same afternoon: before, mild 98 / 100,
moderate 97 / 99, harsh 68 / 77, overall 87.7 / 92.0 (top-1 / top-3); after,
mild 98 / 100, moderate 98 / 99, harsh 67 / 77, overall 87.7 / 92.0. One moderate
case was recovered (the OCR read `RAD-162` for `RAD-161`; the `2` → `1`
alternative now reaches the card) and one harsh case was lost (a garbled
`RAD-256`, which no printing carries, now yields the guess `RAD-156` and its
smaller bonus outweighed a weak descriptor match for the true `RAD-158`); the
harsh tier's codes are illegible by construction, so a guess there is as likely
to hurt as to help, and the `expectedSet` hint does not apply to a mixed set.

Real photos: none yet. Put photos of your own cards in `samples/`, named by catalog
id or printed code (see `samples/README.md`), and `riftscan evaluate samples`
scores them the same way. Until then the numbers above only say how the pipeline
copes with the distortions the generator knows about; glossy-card reflections,
sleeves, motion blur and the feeder's actual lighting are untested.

## Using it from an iOS app

- Build `cache/index.json` on a Mac and ship it in the app bundle (or download it);
  `CardIndex.read(from:)` loads it. Reference images are not needed at run time.
- `CardRecognizer.live(index:)` wires the production graph; every collaborator is an
  initializer parameter, so an app can swap the locator, OCR or scoring policy.
- `recognizer.replacing(index:overlay:policy:excludedBatches:)` swaps the data a
  recogniser matches against while keeping its collaborators, including the one
  `VisionTextRecognizer` whose limiter keeps Vision OCR from crashing; this is how
  a downloaded `ExemplarIndex` overlay or `LearningPolicy` goes live at run time.
- `identify(_:)` is `@concurrent`: call it from the main actor with the camera
  frame as a `CGImage` and await the result; the heavy Vision and Core Image work
  never runs on the main actor.
- The library has no UI dependencies and no third-party packages.

## The iOS app

`App/` is a SwiftUI test harness for the recogniser: a viewfinder with a card
guide, a review sheet that shows the captured photo, the rectified card, the top
candidates and the code the OCR read, and a scan log. Every scan is saved with
its photo, the rectified canvas, the top five candidates with scores, and your
verdict (correct, corrected to another printing, or rejected), grouped into
batches so lighting setups can be compared. The History tab shows per-batch
accuracy and can export a batch as a zip; the Collection tab shows the
server's holdings (see below).

Verdicts are an append-only log (`docs/adr/002-collection-system.md`, decision
6). Each `ScanRecord` carries `decisions`: one `Decision` per verdict with a
`seq` (1, 2, 3…), a snapshot `cardID` of what was confirmed, a `source`
(`human`, `autoAccepted`, `audit`, `spotCheck` or `legacy`), the time, and two
`Override`s (`{"inherit":true}` or `{"value":…}`) for the finish and the
printing to ledger. `verdict`/`verdictAt` are still written, derived from the
last decision. Only the store appends decisions, through
`ScanStoring.decide(_:in:_:)`; `verdict`, `verdictAt` and `decisions` are
`private(set)`, and `Scripts/check-verdict-writers.sh` fails CI if anything
outside `ScanRecord.swift` assigns them. `update(_:)` refuses a record whose
log is not what is on disk plus new decisions (`ScanStoreError.staleRecord`),
so two screens holding copies cannot overwrite each other's verdicts. Records
also carry the recogniser's `analysis` (winning oriented descriptor, corner
quad, code source and alternatives, a shortlist of up to 12 candidate ids with
score components; no images or URLs), the `engine` stamp (package version,
calibration hash, platform, OS, overlay and policy versions) and a
`captureQuality` (`standard` for a guide crop at full resolution, about
1454 × 2030 px; `legacy` otherwise). Batches carry a `purpose` (`collection`
or `calibration`), an optional `product` and `defaultFinish`, and a
`trainingQuality`. Every new key is optional on decode: a v1 `scans.json`
decodes with a synthesised seq-1 `legacy` decision per judged scan, `legacy`
capture quality and no analysis, and a v1 `batch.json` is a `calibration`
batch with `legacy` training quality, so nothing recorded before the ledger
existed is ever ledgered or learned from. The implicit first batch is
`calibration` too; a `collection` batch starts only from the start-run sheet.

**The confident tier** (ADR-002, decision 9) is `ScanConfidence` under a
`ConfidenceRule` built from the installed `LearningPolicy.confidence` and the
server's audit count (`App/Sources/Scans/ScanConfidence.swift`). A scan is
confident only when a code was read *literally* (a candidate matched through a
parser repair is `codeRepaired`), it names the top candidate exactly, the
score clears `minimumFusedScore` (1.0), and no shortlisted card of a
*different* `ArtGroup` has a learned `exemplarSimilarity` of at least 0.88 that
beats the top's own best descriptor evidence by 0.10 (`exemplarDisagrees`);
same-art siblings such as `sfd-014` and `sfd-014a` never veto each other. There
is no descriptor floor. Each candidate records `codeOrigin` (`alternative`
when written; absent means literal). Confident scans are sampled for a human
audit deterministically from the scan id (UUID first byte modulo 10 against
the rate in tenths: 0.3 until the server reports 300 random audits, then 0.1):
"Accept N confident · M held for audit" on the run strip skips the sample,
the review queue shows the uncertain scans first and then the audit rows with
an Audit badge, and their verdicts are `audit` decisions. "Spot-check 10"
re-checks a sample of the run's accepted scans as `spotCheck` decisions, which
the server records but never counts. The Settings tab's Learning card shows
the server's 95 % Wilson lower bound from `GET /api/learning/stats`
(`LearningStats`: `wilson_lower_bound`, `confidence_level`, `random_audits`,
`random_audits_wrong`, `unresolved_wrong_audits`, `spot_checks`,
`human_labels`, `sittings`, `exemplars`, …) as "Precision ≥ 98.1 % (95 %)",
healthy while the bound is at least 97 % and no wrong audit is unresolved.

**Starting and reviewing a run** (ADR-002 §6, decisions 3, 13, 14 and 16).
The batch menu's "Start run…" sheet (`StartRunSheet`) asks for a label, the
purpose (Collection or Calibration), the product (a sealed box with its set,
loose cards, or something named) and the default finish, shows the engine
line, and remembers everything but the label in `UserDefaults`
(`DefaultsRunSetupStore`, key `scanner.lastRunSetup`) so the next box takes
one tap. A sealed-box batch hands the recogniser
`RecognitionHints(expectedSet:)` on every identify. The run-complete strip
sorts this run's pending scans into five tiers (`ScanTier`, `App/Sources/Scans/ScanTier.swift`):
*Confident* (literal exact code, score over the bar, printing settled),
*Needs a look* (any `UncertaintyReason` but the variant), *Pick printing*
(the code's variant disagreed, or, in a collection batch that is not a sealed
box, a vault sibling the recogniser cannot see such as a promo is possible),
*Possible duplicate* and *Unknown* (no candidate). "Accept N confident · M
held for audit" accepts the confident tier alone; the review queue runs the
other tiers in capture order, then the possible duplicates, then the audit
rows. `DuplicateGuard` runs at identify time against the run's last five
scans: a feature-print cosine of at least 0.985 to a scan with the same top
`ArtGroup` sets `analysis.duplicateOf`, and the queue asks "Same card as the
previous scan? Keep both / Drop"; Drop writes `rejected(duplicateCapture)`,
which owes the ledger nothing. The queue pre-selects the inherited finish
(`effectiveFinish`, else the batch default for a both-finish printing) and
shows a Normal/Foil toggle only when `FinishPolicy` says `prompt` or
`unknown`; `PrintingPickerView` offers `CardVault.siblings(of:)` as chips with
the recognised printing (or the log's `effectivePrintingCode`) pre-selected,
promo siblings behind "Other printings…" for a sealed box. A decision writes
`Override.set` only for a value the user changed, so re-confirming a promo
scan in a spot-check leaves the promo effective; choosing a chip the index
also knows (an alternate art) is a correction to that card, choosing one it
cannot see (`OGN-066-P`) keeps `confirmedCardID` on the recognised card and
sets `ledgerPrintingCode`, which `LedgerDeltaBuilder` sends as the `card_key`.
The fix sheet explains the server's `unknown_card` and `duplicate_mismatch`
outcomes for a scan the overview flagged. Collection -> "Add card" queues a
`manual:<uuid>` ledger item for any vault printing (`AddCardSheet`,
`ManualItemStore`, see the sync section). `sh Scripts/check-review-accessibility.sh`
checks that every one of these views names its controls for VoiceOver; the
manual check is to turn VoiceOver on and swipe through the review screen of a
possible duplicate: the badge, the duplicate row, each printing chip (with
"selected"), each finish and Keep both / Drop are all announced.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `App/project.yml`; the card index is bundled from `cache/index.json`, so
build it first. From the repository root:

```bash
swift run -c release riftscan build-index            # once, or after a catalog change
(cd App && xcodegen generate)
xcodebuild -project App/RiftboundScannerApp.xcodeproj -scheme RiftboundScannerApp \
  -destination 'id=<device udid>' -derivedDataPath App/DerivedData -allowProvisioningUpdates build
xcrun devicectl device install app --device <device udid> \
  App/DerivedData/Build/Products/Debug-iphoneos/RiftboundScannerApp.app
```

`xcrun devicectl list devices` prints the UDID. Unit tests for the app (scan log
coding incl. the v1 and v2 fixtures, the file store, decisions through the
store, the confident tier with the 024/014 veto fixture and crafted audit ids,
the scanner model with stubbed camera and recogniser, the review queue's audit
and spot-check rows, the five scan tiers, the duplicate guard, the inherited
finish and printing overrides, the start-run memory, the manual add, the
server client against a stubbed `URLProtocol`, endpoint discovery with an
injected clock, the ledger delta builder, the syncing store and the sync
engine against a scripted server with a hand-advanced clock) run on a
simulator; `sh Scripts/check-verdict-writers.sh` and
`sh Scripts/check-review-accessibility.sh` are the matching CI greps:

```bash
xcodebuild test -project App/RiftboundScannerApp.xcodeproj -scheme RiftboundScannerApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath App/DerivedData
```

### The Mac app

`RiftboundScannerMac` (macOS 15) is the same app on a laptop, with the iPhone
as its camera through Continuity Camera: run batches with the feeder, then
review them with the keyboard. It builds from the same `App/Sources`; where the
platforms differ the code says so in small seams rather than forked screens:
`Shared/PlatformModifiers.swift` (inline titles, keyboards, sheet sizes),
`Shared/SystemSettingsPane.swift` (where a permission is granted),
`PlatformDependencies` in `AppDependencies.swift` (the Mac's camera picker),
`CameraPreview` (a `UIView` or an `NSView`) and `#if os(macOS)` blocks in
`CaptureEngine` and `ScannerView`. The tests are shared too and run natively on
the Mac against the Mac app.

```bash
(cd App && xcodegen generate)
xcodebuild -project App/RiftboundScannerApp.xcodeproj -scheme RiftboundScannerMac \
  -destination 'platform=macOS' -derivedDataPath App/DerivedData -allowProvisioningUpdates build
# Run it from Applications: from under ~/Documents its Bonjour browse is refused (ADR-004).
ditto "App/DerivedData/Build/Products/Debug/Riftbound Scanner.app" "/Applications/Riftbound Scanner.app"
open "/Applications/Riftbound Scanner.app"
xcodebuild test -project App/RiftboundScannerApp.xcodeproj -scheme RiftboundScannerMac \
  -destination 'platform=macOS' -derivedDataPath App/DerivedData -allowProvisioningUpdates
```

**The camera.** `LiveCameraDiscovery` follows `AVCaptureDevice.DiscoverySession`
over Continuity Camera iPhones, external and built-in cameras (Desk View is
left out). `CameraSelection` prefers the camera you last picked, else an iPhone,
else an external camera, else the built-in one, and an iPhone that joins after
launch replaces a built-in camera picked in the meantime. A camera in use that
disconnects is *lost*, never silently replaced: feeding stops at once
(`AutoScanEnd.cameraDisconnected`), photos already taken are still identified,
and scanning resumes when it reconnects or you pick another camera from the
toolbar menu. No camera, refused permission (with a button to the Privacy &
Security pane), starting and failed are each their own screen.

Measured on Luke's iPhone 16 Pro (10 Nov 2026): over Continuity Camera it offers
at most 1920 × 1440, rejects the `.photo` preset and has no torch, and a Mac
session re-applies its preset whenever its graph is rebuilt, so a hand-set
format does not stay. The engine therefore runs at `.high` (1920 × 1080, the
card keeps all its pixels; only the margin beside it shrinks) with Center Stage
turned off. A Mac guide crop's long edge is about 1400 px, short of the
1800–2200 px `CaptureQuality.standard` needs, so Mac captures are `legacy`
and never train the learning loop. Continuity Camera delivers the
sensor's landscape frames however the phone sits, so an iPhone starts turned a
quarter-turn clockwise, the same turn the iPhone app applies to its own camera;
the preview layer and the photo's EXIF orientation are turned together
(`CameraRotation`), so `GuideCrop` maps the guide exactly as on the phone. The
preview shows the whole frame, and `FrameGuide` places the card outline in it:
for the built-in or a USB camera where the iPhone app's guide lands in its
photos, for an iPhone a larger centred card (Continuity films through the main
lens, which sees the card bigger than the app's ultra-wide). The side panel's
Rotate button (⌥⌘R) and Guide size slider fit both to the stand; each is
remembered per camera under `scanner.cameraPreferences`.

Measured on 31 cards fed on 10 Nov 2026: the card is about 718 × 1017 px of
the upright 1080 × 1920 frame, its black border is lost against the dark
stand, so the recogniser often cannot find the card and matches the whole
crop, and there is no torch. The iPhone guide is therefore 66 % of the frame's
short side with a 7 % crop margin (not the phone's 15 %), and Continuity
photos are brightened half a stop (`CameraDevice.Kind.photoExposureBoost`,
since macOS has no camera exposure bias). On those photos that took the
recogniser from 17 to 27 right; the build before it, with a looser guide and
no brightening, got 13. No printed code was read at this resolution, so no
Mac scan is confident: every one goes through the review queue.

**Review.** Every way into a batch (Review on the run strip, a History row,
an imported server batch) opens one screen, `BatchReviewView`. It opens on
**To review**: on the Mac the triage grid, then the one-at-a-time queue for
the flagged and the rest; on the iPhone the queue. **All scans** shows the
whole batch by what it needs; any scan opened there goes to the same
one-at-a-time view and fix panel, decided or not (`ReviewRoute.scans`). So
does a photo taken by hand: it is saved pending like a fed card and opens in
that view at once; a verdict closes it, Skip leaves it pending in the batch,
and Retake deletes it.
**Delete** takes a scan out of the batch with a `voided` decision: it leaves
review, the collection and the label count, and syncs like any verdict.

**Keys.** Space takes a photo, ⌘↩ feeds and scans, ⌘. stops feeding. In the
review queue Return confirms (or keeps both for a possible duplicate), F opens
the fix sheet, ⌫ deletes and → skips to the next scan; in the grid X flags, ⌫
deletes and ⌘↩ confirms the rest. The keys sit on the buttons, so they go
quiet while a sheet has focus. ⇧⌘S shows the scans in Finder.

**Storage and permissions.** The app is sandboxed: scans live in
`~/Library/Containers/com.nsluke.RiftboundScannerMac/Data/Documents/Scans`, the
same layout as the phone's, so `python3 -I Scripts/summarize-scans.py` reads that
folder directly. Entitlements: camera, Bluetooth, outgoing network (the
collection server) and user-selected files (exports). The feeder is the same
`CSC100Feeder` over CoreBluetooth; Bluetooth access is asked for on the first
Connect. One window only: the camera, the feeder link and the sync engine
belong to a single scanner.

**The iPhone app as the Mac's camera** ([ADR-004](docs/adr/004-iphone-as-mac-camera.md)).
The sharpest way to scan from the Mac: on the iPhone, tap the Mac-and-phone
button on the Scan tab (**Camera for Mac**) and leave that screen open with
the phone on the stand. The Mac's camera menu then lists the phone as
"<name> (Riftbound app)" and switches to it. The phone lets go of the feeder
and the Mac connects to it, then drives it and gets the iPhone app's own
photos: the 0.5× lens up close, 12 MP, and the torch. The apps talk over
Bonjour (`_riftcam._tcp`) on the local network; each asks for Local Network
access once. Run the Mac app from `/Applications`: launched from the build
folder under `~/Documents`, macOS refuses its Bonjour browse (`NoAuth`).

**Reviewing what the iPhone scanned** ([ADR-003](docs/adr/003-mac-review-station.md)).
Continuity Camera only ever gives the Mac the iPhone's main lens, which cannot
focus on a card that close, so the sharp way to scan is the iPhone app, whose
dual-wide camera drops to the 0.5× lens up close. Every scan that waits for a
person uploads its record and full photo, and History on the Mac lists those
batches under **On the server**. **Import to review** copies one into the
Mac's store (`ServerBatchImporter`; an interrupted import resumes), then the
triage grid and fix panel work as for a batch scanned here, and the verdicts
go back to the server as the next decision of each scan. Review a batch on one
device: the server refuses whichever decision log arrives second.

### Talking to the collection server

The app is a client of the [RiftboundCollection](../RiftboundCollection) server
(ADR-002): the ledger on the Pi is the source of truth for holdings. The
networking layer lives in `App/Sources/Server/`:

- `CollectionServing` is the one protocol every feature talks to; the live
  implementation is `HTTPCollectionClient` (plain HTTP, no `URLCache`, 15 s
  request / 60 s resource timeouts, `X-Client` header, optional bearer token,
  typed `ServerError`). Conditional GETs carry the app's own validator as
  `If-None-Match`; a 304 is answered from `ResponseCache` under that validator.
- `EndpointResolver` probes `/health` on `riftbound.lan`, then `riftbound.local`,
  then the fallback address from Settings (default `192.168.1.155:8096`), 3 s per
  probe, only over Wi-Fi, wired or VPN (`utun`) paths. A hit is cached for
  10 minutes; a cycle where nothing answers backs off for 5 minutes.
- `ServerSettings` holds the fallback address (UserDefaults) and the write token
  (Keychain). The Settings tab edits both and has **Test connection**, which
  shows the `/health` fields and "Server needs updating" when the server's
  `user_version` is below 3.
- `AppPaths` is `Library/Application Support/Riftbound/{Sync,Learning,Catalog}`,
  excluded from backup; `Documents/Scans` stays the only file-shared tree.

`App/project.yml` carries the plist keys the transport needs: `NSAppTransportSecurity`
(local networking plus exceptions for `riftbound.lan` and `riftbound.local`),
`NSLocalNetworkUsageDescription`, `NSBonjourServices` and the reworded camera
string. The tests stub `URLProtocol` (`App/Tests/Support/StubServer.swift`) and
inject a `TestClock`; nothing in the suite touches the network. To try the real
client against a local server, run the server repo's
`RC_PORT=<port> python -m riftbound_collection serve`, enter `127.0.0.1:<port>` as
the fallback address in a simulator build and tap Test connection.

### Syncing scans and the ledger

Decisions reach the server through `App/Sources/Sync/` (ADR-002, decisions 2
and 4). Durable truth on the phone is `Documents/Scans/<batch>/scans.json`
(the decisions) plus `Library/Application Support/Riftbound/Sync/<batch>/sync.json`
(what the server has acknowledged); `Sync/outbox.json` is a cache rebuilt
from the two and can be deleted at any time.

- `ManualItemStore` keeps cards added by hand in `Sync/manual.json`, one
  `ManualItem` per add (`manual:<uuid>`, `card_key`, `finish`, `quantity`,
  `condition`, `LedgerItemState`); reconcile puts every unacknowledged one
  into the outbox after the scans' items, and the server's answer is written
  back to `manual.json`, with `unknown_card` re-queued when the catalog
  version changes. Each `OutboxEntry` carries its origin (a scan's batch and
  id, or `manual`); an outbox written before this format decodes as empty and
  is rebuilt.
- `SyncingScanStore` is the live `ScanStoring`: it wraps `FileScanStore`,
  writes `scans.json` first and `sync.json` second, and fixes a batch's
  `purpose` once any scan in it has a decision (`ScanStoreError.purposeImmutable`).
  `voidBatch` appends a `human` `voided` decision to every scan and marks the
  batch; `closeBatch` records `closedAt` for the pruner (A5).
- `LedgerDeltaBuilder.items(record:previousState:batch:vault:)` is pure: a
  `correct`/`corrected` decision in a `collection` batch owes `+1` as
  `scan:<scan id>:<seq>` (printing key from the decision's override or the
  card id, finish forced for single-finish printings, otherwise the override
  or the batch default); a changed effect also owes an undo
  `scan:<scan id>:<seq>:undo` naming the previously **applied** reference
  (`undo_of`), while a previous `+1` the server never applied is simply
  withdrawn. Unchanged effects, `legacy` decisions and `calibration` batches
  emit nothing; acknowledged references are never sent twice.
- `SyncEngine` (main-actor, built by `RootView` through
  `AppDependencies.makeSyncEngine`) runs `reconcile()` on launch, on **Retry
  now** and before every flush, then drains batch metadata, ledger items in
  pages of 100 (`POST /api/sync/ledger`), scan records, `photo_small`,
  canvases and photos. Triggers: launch, foreground, 2 s after a decision, a
  path to the home network appearing, every 60 s on the Scan tab. Transport
  failures back off 5 s to 5 min; `unauthorized`/`forbidden`/outdated server
  stop the flush with a message. Per-item statuses are terminal states in
  `sync.json`: `applied(ledgerID, cardID, finish)` or
  `terminal(duplicate | duplicateMismatch | unknownCard(catalogVersion) |
  wouldGoNegative | nothingToUndo | invalid | unrecognized)`; an
  `unknownCard` item is re-queued unchanged when `/health.catalog_version`
  changes, nothing else ever is. An item is marked `sent` before its page
  goes out; one whose answer was lost is replayed (the server answers
  `duplicate` or `applied`) and, if its effect changed meanwhile, reversed by
  reference, so a timeout after the server's commit never leaves a stale
  row. A `+1` the server answers `duplicate` is recorded `applied` from the
  row the answer names, because the server holds that row and a later
  correction or void must undo it. A refusal of the ledger route as a whole
  (404, or the 422 the server gives only for a request shape it does not
  accept) leaves the items owed and ends the flush with the server's detail;
  nothing is marked `invalid` for it. Record uploads: `uploaded(at)` with the
  decision count the server accepted, `conflict(serverSeq)` on 409 (terminal),
  `failed(reason)` for refusals that are retried on the next flush. Every
  drain writes only the fields it owns through the store's closure, so a
  void or close written mid-flush is never overwritten. A flush decodes each
  batch's `scans.json` once, and skips a batch that owes nothing and whose
  file stamp has not moved since its last reconcile.
- UI: the batch overview shows a sync line with needs-attention rows
  (refused undos, unknown printings, record conflicts), **Close batch**,
  **Void batch** and **Sync now**; History shows purpose and sync badges and
  a Void swipe action. A voided batch's folder is removed once every ledger
  item is acknowledged, every voided record is on the server and no undo was
  refused; refused undos keep the batch with their count ("Resolve on the
  web") until the user deletes it.

`App/Sources/Sync/ScanUploads.swift` holds the two seams A5 fills in:
`ScanUploadComposing` (`RecordUploadComposer` sends the record minus image
URLs, the oriented descriptor with its calibration hash, the analysis stamp
and the engine) and `ScanAssetProviding` (`StoredAssetProvider` downsamples
`photo_small` and re-encodes anything over the server's caps at the sizes and
JPEG qualities in `AssetEncodingPolicy`, a value the composition root injects).

To check the wire contract against a local server, run the server repo's
`RC_DB_PATH=/tmp/x.sqlite RC_PRICE_SYNC=0 RC_BACKUPS=0 RC_PORT=8197 python -m riftbound_collection serve`
and `POST /api/sync/ledger` a page with a `+1`, its replay, an undo naming
the applied reference and an undo of a missing one: the statuses come back
`applied`, `duplicate`, `applied` (card and finish copied from the row) and
`nothing_to_undo`, and `GET /api/holdings` reflects the net result.

### Decks

The Decks tab (`App/Sources/Decks/`) is the phone's read-only view of the
decks built in the server's web builder (ADR-002, decision 11). `DecksModel`
reads `GET /api/decks` conditionally on the cached validator; `DeckDetailModel`
reads `GET /api/decks/{id}` (every slot including the sideboard, the server's
`owned` / `used_elsewhere` / `available` / `short` per card, per-slot `counts`
and the `validation` verdict with its issue codes) together with
`GET /api/decks/{id}/export?style=piltover`, which the Share button hands to
`ShareLink`. Both are saved under `Library/Application Support/Riftbound/Catalog/decks.json`
(`FileDeckCacheStore`), so when the server is out of reach the tab shows the
saved copy with a "Showing decks saved …" line and a retry; with nothing saved
it shows the error and a retry. Short counts are the server's, never recomputed
on the phone.

The one deck write is **Add to deck…** on a card's detail sheet
(`AddToDeckSheet`): pick a deck (the most recently edited is pre-selected), a
slot pre-filled by the same rule as the server's `default_slot` (Legend, Rune
and Battlefield by type; Signature cards to the main deck; other Champion units
to the champion slot; everything else to the main deck), and the number of
copies the deck should hold, then `PUT /api/decks/{id}/cards`. The server
answers with the refreshed deck, which replaces the cached detail. Decks are
server-authoritative and online-only: when discovery finds no endpoint the
button is disabled with the reason and a "Try again" that re-probes.

Slot headers stack their count under the name at accessibility text sizes and
every row is one VoiceOver element ("3 × Back to Back, OGN-206, Main Deck,
2 short"). The tests (`App/Tests/DecksModelTests.swift`) run the models
against `StubCollectionClient` and decode `App/Tests/Fixtures/deck-detail-v4.json`,
a deck captured from the server at `user_version` 4. To see it live, run the
server locally (`RC_DB_PATH=/tmp/x.sqlite RC_PRICE_SYNC=0 RC_PORT=8096 python -m riftbound_collection serve`
in the server repo), build a deck at `http://127.0.0.1:8096/decks`, enter
`127.0.0.1:8096` as the fallback address in a simulator build and open the
Decks tab.

### The Collection tab

The Collection tab (`App/Sources/Collection/`) shows what the server's ledger
says the user owns, never a count of local scans (ADR-002, principle 1 and
decision 10). `CollectionModel` is built from four sources the composition
root wires in `AppDependencies.live()`, each caching one JSON file under
`Library/Application Support/Riftbound/Catalog/` (rebuilt from the server, safe
to delete):

- `ServerHoldingsSource` (`HoldingsSourcing`): `GET /api/holdings` with the
  ledger-head ETag as `If-None-Match`, kept as `holdings.json`. An unchanged
  validator (a 304, which `HTTPCollectionClient` answers from its own cache
  under that validator) keeps the stored counts and only moves `fetchedAt`.
  Counts are per vault code and per finish (`OwnedCount.normal/foil`).
- `ServerCatalogSource` (`CatalogSourcing`): `GET /api/catalog` conditional on
  `catalog_version`, kept as `catalog.json`; the bundled `CardVault.json` is
  the cold-start seed and stays on screen until the first fetch. Server rows
  carry no art or Cardmarket link (decision 15), so each takes them from the
  bundled row with the same code; a printing the bundle lacks shows a
  placeholder. The catalog is re-asked for when its copy is older than
  `CollectionModel.Policy.catalogMaxAge` (24 h), on pull-to-refresh, or when
  the sync engine sees a different `/health.catalog_version`.
- `ServerPriceSource` (`PriceQuoting`): `GET /api/prices/latest` conditional on
  the day tag, kept as `prices.json`, keyed by vault code; refreshed when older
  than `Policy.priceMaxAge` (12 h). A 404 ("no prices stored yet") or a failure
  leaves the last sheet, or the vault's snapshot prices, on screen. The app's
  tcgcsv client is gone: the server refreshes prices from tcgcsv, the phone
  never talks to it.
- `OutboxPendingLedger` (`PendingLedgerProviding`): every ledger item the sync
  engine's outbox still owes, as `PendingDelta`s; an undo resolves to the
  applied row it reverses through the batch's `sync.json` (or to the `+1`
  being replayed beside it), and an undo of an unknown row counts for nothing.
  Scan references and `manual:` references are treated alike.

What the screen shows: the server's count ("×3") plus a "+N pending" chip for
what this phone still owes; the header carries the net pending total; a
pending-only printing appears under **My cards**. The card sheet lists Normal
and Foil rows with each finish's owned count and value. When the server cannot
be reached and a snapshot exists, the snapshot stands in with the pending
chips and a notice ("Showing your collection as of …"); with no snapshot the
bundled catalog shows with zero counts, **My cards** shows "Not connected to
your server" with a **Connect** action (which forgets the cached endpoint so
discovery probes again, then asks for holdings), and **All cards** still
browses. When the server's catalog has printings the bundle lacks, a notice
says how many cannot be scanned until the app is rebuilt with a new index
(decision 10's new-set order). The view re-reads holdings when
`SyncEngine.ledgerGeneration` moves, pending items when `queuedItems` does,
and the catalog when `catalogVersion` does.

The tests (`App/Tests/CollectionTests.swift`) run the real sources with
in-memory files over `StubCollectionClient` and a `SyncingScanStore` whose
confirmed scans must never be counted; `grep -rn tcgcsv.com App/Sources`
finds nothing. To see it live, run the server locally as in the Decks section
and open the Collection tab; `GET /api/holdings` and `GET /api/catalog` answer
304 to the validators the app stores (checked with curl against the server's
main at `user_version` 5: `ETag: "ledger-<head>.<stamp>"` moves with every
applied item, the catalog's ETag equals `/health.catalog_version` and the
body's `catalog_version`).

### Reviewing the results

The app writes `Documents/Scans/<batch>/batch.json`, `scans.json`, `photos/` and
`rectified/`. The folder is visible in the Files app (file sharing is enabled)
and can be pulled over USB or Wi-Fi with the phone's development pairing:

```bash
Scripts/pull-scans.sh                   # copies Documents/Scans into ./scans
python3 -I Scripts/summarize-scans.py   # accuracy per batch, who decided, plus every miss with its photo
```

The script reads v1 and v2 files alike and reports, per batch, the purpose,
capture qualities, how many scans each decision source settled, and the voided
count. `App/Tests/Fixtures/` holds a frozen v1 sample (`scans-v1.json`,
`batch-v1.json`, five real records with the image URLs replaced), a v2 sample
(`scans-v2.json`, `batch-v2.json`) and the crop/size table of the Testing
batch; the app tests decode all of them. To run the script over the v2 sample:

```bash
d=$(mktemp -d)/2B0E6D3C-0000-4000-8000-000000000002 && mkdir -p "$d" \
  && cp App/Tests/Fixtures/batch-v2.json "$d/batch.json" && cp App/Tests/Fixtures/scans-v2.json "$d/scans.json" \
  && python3 -I Scripts/summarize-scans.py "$(dirname "$d")"
```

`riftscan import-scans scans` turns the judged scans into an evaluation
manifest directly (see "Learning evaluation"); `riftscan evaluate` can also be
pointed at photos copied into `samples/` with their printed code as the file
name.

### Printing identity

The app joins two spellings of every printing (ADR-002, decision 1). The
recogniser's index writes `sfd-227*-221` and `ven-038a-166`; the bundled
`App/Resources/CardVault.json` writes `SFD-227-STAR` and `VEN-038A`. Both reduce
to one `PrintingKey` (`App/Sources/Catalog/PrintingKey.swift`): set, collector
number and variant with no denominator, in the index's spelling (`SFD-227*`,
`VEN-038a`). Vault rows the recogniser can never produce keep their raw code as
the key so they never collide with the base printing: promo suffixes
(`OGN-066-P`, `SFD-178a-P`), rune and token backs (`RAD-R01b-P`) and the four
oversized rows with a denominator (`OGN-279/298`). The rule resolves 1,403 of
the 1,408 index printings; the five misses are token backs the vault spells
differently (`UNL-T01g`), and the collection server resolves the same key
through its `card_aliases` table, so the app never sends vault spellings.

`CardVault.siblings(of:)` lists every printing of the same art (same set and
collector number, any suffix, oversized rows excluded) in vault order, which is
what "Pick printing" offers; `CardVault.vaultCode(for:)` maps an index id back
to the vault row. `FinishPolicy.resolve(card:batchDefault:)` turns the vault's
`hasNormal`/`hasFoil` flags into `forced(finish)` for single-finish printings,
`prompt(default:)` for both-finish ones (the batch default pre-selected) and
`unknown` when the vault lists neither or lacks the printing. The CSV export
carries a `Key` column with the printing key next to the printed code.

## Data, images and Riot's developer policy

The catalog comes from
[Dystorted888/riftbound-card-data](https://github.com/Dystorted888/riftbound-card-data)
(MIT), a snapshot of Riot's public card gallery; the fallback source is
[slimtreble/Riftbound-card-data](https://github.com/slimtreble/Riftbound-card-data).
Card images are Riot Games' property, fetched from the gallery's CDN URLs listed in
the catalog, cached locally for personal prototyping only and never committed.

Anything distributed is a different matter. Riot's Riftbound developer policy
requires an app-specific API key from [developer.riotgames.com](https://developer.riotgames.com),
permits only assets obtained through the Riot API, and requires the "Legal Jibber
Jabber" attribution notice. The community dataset and the cached gallery images
are for this personal prototype; a shipped app must source its catalog and images
through the official API under those terms.

## Engineering notes

- **Isolation.** The library sets nonisolated default isolation (`Package.swift`,
  ADR-001): it is a pure compute module with no UI state, every type is a
  `Sendable` value type, and the two entry points are `@concurrent`. The CLI target
  uses main-actor default isolation. Both enable approachable concurrency.
- **Vision API.** The Swift-native requests (`DetectRectanglesRequest`,
  `RecognizeTextRequest`, `GenerateImageFeaturePrintRequest`) are the modern form of
  the `VN…` classes; their observations are `Sendable` values and `perform` is
  `async`, which is why they were chosen over the Objective-C-era API.
- **Index format.** JSON with feature prints stored as little-endian Float32 bytes
  (base64), unit-normalised at build time so similarity is a dot product. The
  format is versioned; a mismatch is refused rather than misread. An optional
  `calibrationPrint` (same encoding) records the embedding the index was built in.
- **Admission gate.** `ExemplarAdmission` (gate version 2) is a pure function of
  an `AdmissionInput` (decision source and kind, the snapshot card, placement,
  calibration hash, capture and training quality, code evidence, reference
  similarity, code alternatives, feature print), the witnesses offered for the
  art tier and the exemplars already admitted. Every similarity goes through
  `SimilarityContract`: Float64 accumulation over the stored Float32 values,
  rounded half-to-even to four decimals (`round(x * 10000) / 10000`) before any
  comparison. `Tests/Fixtures/admission-cases.json` carries 58 cases and 15
  similarity vectors (each threshold ± 0.00005); the Swift suite and the
  server's Python port both run it, and `riftscan gate-diff` checks the live
  server against the Swift gate.
- **Overlay and policy formats.** `ExemplarIndex` is JSON `formatVersion` 2
  (`version`, `calibrationPrint`, `exemplars[{artGroup, featurePrint, scanID,
  batchID, admittedAt}]`), stored on the phone by `BinaryExemplarStore` (packed
  Float32 plus an id table, patched by `ExemplarDelta`s) and compared with the
  device's calibration print before use. `LearningPolicy` (`version`, `scoring`,
  `confidence`, `admission`, `calibrationMinimum`) decodes with defaults for every
  missing key. Both are documented in `docs/learning-policy.md`.
- **Engine fingerprint.** `EngineFingerprint` = package version (`RecognizerInfo.version`),
  the 16-byte digest (`FeaturePrint.Digest`, the first 16 bytes of SHA-256 over the
  Float32 bytes) of the device's calibration print, platform and OS version. It is
  stamped on every `RecognitionResult`; `CardRecognizer.live` computes it, which
  is why that factory is `async throws`. `ScoringPolicy` and `ScoreComponents` are
  `Codable` so policies can ship as data and analyses can be recorded; a policy
  file missing a key (one written before `codeAlternativeBonus` or
  `expectedSetBonus` existed, say) decodes with the default for it.
- **OCR vocabulary.** `PrintedCodeParser.Vocabulary(codes:)` is built from the
  index's codes: the keys (code without denominator), the denominators each set
  prints, and the set codes and number prefixes used for shape repairs. A parser
  therefore knows exactly the printings the recogniser can name; there is no
  built-in list of sets. `CodeReading.origin` is `.literal` for a code read as
  printed (shape repairs such as `0GN` → `OGN` included) and `.alternative` when
  the literal named no printing and a digit alternative did; `alternatives` lists
  every code the text could name, best first. `Match.codeEvidence` pairs the
  agreement with the origin it came through, so a candidate that matched only an
  alternative is distinguishable from one the text literally named.
- **Tests.** Every stage has a Swift Testing suite. Card images for tests are drawn
  procedurally with CoreGraphics and CoreText (no Riot assets), feature prints come
  from a deterministic thumbnail-based fake, and the Vision-backed tests exercise
  the real locator, OCR and feature prints on those procedural cards. A contract
  test against the real catalog runs when `data/cards.json` is present.
- **OCR concurrency.** Vision's text recogniser crashed (`EXC_BAD_ACCESS` inside
  TextRecognition) when this process ran many `RecognizeTextRequest`s at once, so
  `VisionTextRecognizer` funnels requests through an `AsyncLimiter` (one at a
  time by default). Feature-print and rectangle requests still run in parallel.
- **Known gaps.** Only one card per photo. Printings that share an illustration tie
  on descriptors and are separated by OCR alone, so a blurred code means a
  coin-flip between, say, `OGN-299/298` and `OGN-299*/298`. The frame insets were
  measured on the standard frame; full-art showcase cards have none, which is fine
  (the unexpanded or whole-image hypothesis wins) but untested on real photos.
