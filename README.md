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
   (`0GN`, `OO1`, missing separators) against the set codes and number prefixes
   found in the index.
7. **Re-rank.** The top 12 descriptor candidates are adjusted by how the read code
   relates to theirs, scaled by OCR confidence: exact match +0.5, same number but a
   different suffix (`299` vs `299*`) +0.2, same number in another set −0.15, any
   other disagreement −0.4. A confident code reading therefore outranks a slightly
   better descriptor match, which is what separates printings that share an
   illustration: standard vs signature, or the same rune reprinted in another set.

The result carries the ranked matches, where the card was found (and its corner
quad when a card was detected), the code that was read and where it came from
(an edge band of the canvas, or the whole photo as a fallback), the rectified
canvas, the query descriptor in the orientation of the winning match (the one to
compare with a reference or keep as an exemplar), the engine fingerprint that
produced it, and a summary of every hypothesis for diagnostics.

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
Code:  UNL-157/219 read from "UNL • 157/219" (confidence 1.00, upright, portrait layout)

 #  Code          Name                          Score  Desc   FP    dH    pH    Art   OCR
 1  UNL-157/219   Scrutinizing Sergeant         1.447  0.947  0.98  0.95  0.91  0.94  exact
 …
```

`--json` prints the same as JSON (plus `quad`, `codeSource`, the `descriptor`
orientation and digest, and the `engine` fingerprint), `--verbose` lists every
hypothesis that was tried, and `--save-rectified out.png` writes the winning
canvas so you can see what the hasher and the OCR saw.

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
accuracy and can export a batch as a zip.

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
existed is ever ledgered or learned from. Until the start-run sheet exists,
batches started in the app are `calibration` too.

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
store, and the scanner model with stubbed camera and recogniser) run on a
simulator; `sh Scripts/check-verdict-writers.sh` is the matching CI grep:

```bash
xcodebuild test -project App/RiftboundScannerApp.xcodeproj -scheme RiftboundScannerApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath App/DerivedData
```

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

`riftscan evaluate` can then be pointed at the pulled photos by copying the ones
you have judged into `samples/` with their printed code as the file name.

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
- **Engine fingerprint.** `EngineFingerprint` = package version (`RecognizerInfo.version`),
  the 16-byte digest (`FeaturePrint.Digest`, the first 16 bytes of SHA-256 over the
  Float32 bytes) of the device's calibration print, platform and OS version. It is
  stamped on every `RecognitionResult`; `CardRecognizer.live` computes it, which
  is why that factory is `async throws`. `ScoringPolicy` and `ScoreComponents` are
  `Codable` so policies can ship as data and analyses can be recorded.
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
