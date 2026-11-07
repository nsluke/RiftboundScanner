# Recognition on the CSC100 feeder

Findings from the first automated run (2026-11-05, 34 Spiritforged cards fed by the
feeder, every result labelled by hand in the app's "Testing" batch).

## What went wrong in the first run

The photos are sharp and evenly lit; the camera is fine. The card fills only about a
quarter of the frame, and the black tray opening around it is itself a 63 : 88
rectangle, so Vision's rectangle detector usually reported the tray and the saliency
fallback boxed the whole feeder. The recognizer then compared a picture of a tray
against card art. OCR still read the printed code off the full frame in many cases,
but the card it named was not among the 12 descriptor candidates, so the code could
only penalise the wrong cards rather than promote the right one.

| Pipeline | Top-1 on the 34 labelled feeder scans |
| --- | --- |
| App as shipped (full frame, code only re-ranks) | 12 / 34 |
| Centre crop to the guide region + code injection | 33 / 34 (34 / 34 top-3) |

The one remaining miss is a code misread on a low-confidence hypothesis.

## Changes

- `CardRecognizer.rerank` now pulls every index entry whose printed code matches a
  reading (exact or variant) into the candidates when the OCR confidence is at least
  `ScoringPolicy.codeInjectionMinimumConfidence`, scoring it on its real descriptors
  plus the code bonus. A legible code can therefore name the card even when the
  crop is poor.
- `VisionCardLocator` ignores salient objects covering more than half the photo
  (`maximumSalientAreaFraction`); a box that large is the scene, not a card.
- The app crops each photo to the viewfinder guide before recognition and saves the
  crop as the scan's photo, so with the phone on the stand the card dominates the
  frame. (A blind centre crop hurts hand-held photos where the card is off-centre;
  the crop follows the guide, so frame the card inside it.)
- The feed loop captures at feeder speed and identifies in a background queue.

## Second and third runs (same day)

| Run | Change | Top-1 |
| --- | --- | --- |
| 2 | code injection + saliency cap, crop not yet effective | 24 / 33 |
| 3 | guide crop measured after its padding (crop spanned full width) | 3 / 4 |
| 4 | guide measured before padding: crop ≈ 1454×2030 of 3024×4032 | 9 / 14 on the phone; 14 / 14 on the Mac after the whole-image OCR change below |
| 5 | whole-image OCR fallback on the phone | 14 / 14, code read on every card, median identify 1.2 s (overlapped with feeding) |

Run 4's misses were sharp, well-framed crops whose code was legible, but the
rectangle detector reported tray rectangles and the whole-image hypothesis was
never OCR'd (its descriptor score sat below `wholeImageMinimumScore`), and the
code reader only looks at the canvas's edge bands, where a code inside a crop
never falls. Two more changes:

- The whole-image hypothesis is always OCR'd; when its edge bands find nothing,
  `PrintedCodeReader.readCode(fromFullImage:)` reads the photo itself (upright,
  then turned 180°). A code read makes the whole image eligible to win.
- `CropDebug` (guide frame, preview frame, photo size, pixel rect) is saved with
  every scan, which is how the padding bug was found.

Jams: one card in five caught in the feeder on run 3. The feeder sends nothing
for a jam; the app sees it as a feed timeout.

## Evaluating offline

Pull the phone's batches with `Scripts/pull-scans.sh`, then run
`.build/release/riftscan identify <photo> --json` on each photo (optionally cropped
with `sips -c 1024 768`). Vision's rectangle detector behaves differently on macOS
and iOS, so Mac results predict the phone only roughly; the labelled batches in
`scans/` (gitignored) are the ground truth.
