# Learning artefacts: overlay, policy and the fused score

ADR-002 (decision 7, section 7) makes the recogniser learn from confirmed
scans without touching the reference index. Three data formats and one scoring
rule carry that, all in `RiftboundRecognizer` (work item P3).

## ArtGroup

`ArtGroup` is the learning identity of a printing: the recogniser `Card.ID`
with the total and the `a`/`*` suffix stripped (`sfd-227*-221` -> `sfd-227`,
`ven-038a-166` -> `ven-038`, `rad-r01a` -> `rad-r01`, `unl-t01` -> `unl-t01`).
Every printing that shares an illustration is one group; an exemplar learned
from any member helps all of them equally and the printed code stays the only
thing that separates them. `Card.artGroup`, `CardIndex.Entry.artGroup` and
`ArtGroup(code:)` (from a `PrintedCode`) all agree. An id in an unexpected
shape is its own group, so nothing merges by accident.

## Overlay: `ExemplarIndex`

```json
{
  "formatVersion": 2,
  "version": 7,
  "calibrationPrint": "<base64 little-endian Float32, 768 elements>",
  "exemplars": [
    {
      "artGroup": "ogn-003",
      "featurePrint": "<base64 little-endian Float32>",
      "scanID": "8D59C1F2-....",
      "batchID": "1CAED0F4-....",
      "admittedAt": "2026-11-07T12:26:40Z"
    }
  ]
}
```

- `version` is monotonic per calibration hash on the server; `ExemplarIndex.empty`
  has version 0, no print and no exemplars, and matching with it is identical to
  matching without an overlay.
- `calibrationPrint` is the `CalibrationCanvas` feature print of the devices
  whose scans produced the exemplars; `calibrationHash` is its 16-byte digest.
  `compatibility(with: devicePrint, minimum:)` returns `.compatible(similarity:)`,
  `.embeddingChanged(similarity:)`, `.dimensionMismatch(overlay:device:)` or
  `.uncalibrated`; `isCompatible(calibrationPrint:minimum:)` is the Bool form.
  The minimum is `LearningPolicy.calibrationMinimum`.
- `excluding(batches: Set<UUID>)` drops the exemplars of those batches
  (on-device re-identification of a batch must not use what that batch taught).
- One exemplar per scan: `Exemplar.id == scanID`, and a delta revokes by scan id.

Deltas (`GET /api/learning/overlay/changes`) decode as `ExemplarDelta`
`{baseVersion?, version, calibrationPrint?, added[], revoked[]}` where `revoked`
holds scan ids. `index.applying(delta)` throws `deltaBaseMismatch` when
`baseVersion` is set and differs from the index's version; otherwise revoked and
re-added scans are removed, `added` is appended, and the version becomes the
delta's.

### Binary store

The phone keeps the overlay as `BinaryExemplarStore` (`write`, `read`,
`encode`, `decode`, `patch(fileAt:with:)`): magic `RBEX`, layout version 1, the
index's format version, the overlay version, dimension, count, a calibration
flag, the calibration print and every exemplar print packed as Float32, then an
id table (art group, scan UUID, batch UUID, `admittedAt` as a Float64). Prints
and dates round-trip bit for bit (JSON dates lose sub-second precision).
`patch` reads the file (a missing file is `.empty`), applies the delta and
writes atomically; a refused delta leaves the file untouched.

## Scores

`DescriptorCandidate` and `Match` carry two descriptor scores:

- `referenceScore`: the weighted similarities to the index entry alone (what
  `descriptorScore` was before overlays existed).
- `fusedScore` (`Match.descriptorScore`): `max(referenceScore, exemplarScale ×
  exemplarSimilarity)`, where `exemplarSimilarity` is the best feature-print
  cosine between any query rotation and any exemplar of the candidate's art
  group. It is the same number for every member of the group and `nil` when the
  group has none, in which case the fused score *is* the reference score.

`exemplarScale` (default 0.95) lives in `ScoringPolicy`, so a photo identical
to an exemplar still ranks under a perfect reference match and never reaches the
confident tier's fused threshold (1.0) without code evidence.

What uses which (`CardRecognizer.identify`):

| Decision | Score |
|---|---|
| Which hypotheses get OCR | best `referenceScore` of the hypothesis |
| Whole-image eligibility (`wholeImageMinimumScore`) | best `referenceScore` of the hypothesis |
| Which hypothesis wins | best `referenceScore + code adjustment` among its matches |
| Ranking within the winning hypothesis, `Match.score` | `fusedScore + code adjustment` |

So an exemplar can change which card wins but never where the card was found,
and with `ExemplarIndex.empty` every number equals what the pre-overlay code
produced. The shortlist per hypothesis is the union of the `rerankedCandidateCount`
best by fused score and the same count best by reference score (one list when
there are no exemplars), so exemplar evidence can bring a card into contention
while the top reference match is always present.

`DescriptorMatcher(policy:exemplars:excluding:)` does the work;
`CardRecognizer.init` takes `overlay:` and `excludedBatches:`, `CardRecognizer.live`
takes `overlay:`, and `recognizer.replacing(index:overlay:policy:excludedBatches:)`
returns a recogniser with the same locator, rectifier, descriptor extractor and
code reader (hence the same single `VisionTextRecognizer`) matching against the
new data. A replacement index must share the current one's canvas and sets.

## Policy: `LearningPolicy`

`GET/PUT /api/learning/policy` and `riftscan push-policy` carry this file. Any
key missing on decode takes its default, at every level, so a file need only
name what it changes. The values below are the defaults (apart from `version`
and `calibrationMinimum`, chosen for the example); `LearningPolicyTests`
decodes exactly this text.

```json
{
  "version": 3,
  "calibrationMinimum": 0.97,
  "scoring": {
    "featurePrintWeight": 0.5,
    "wholeDifferenceHashWeight": 0.2,
    "wholePerceptualHashWeight": 0.15,
    "artDifferenceHashWeight": 0.15,
    "codeExactBonus": 0.5,
    "codeVariantMismatchBonus": 0.2,
    "codeSetMismatchPenalty": 0.15,
    "codeMismatchPenalty": 0.4,
    "rerankedCandidateCount": 12,
    "codeInjectionMinimumConfidence": 0.3,
    "maximumLocationHypotheses": 6,
    "ocrHypothesisCount": 2,
    "wholeImageMinimumScore": 0.8,
    "exemplarScale": 0.95
  },
  "confidence": {
    "minimumFusedScore": 1.0,
    "requireLiteralCode": true,
    "exemplarDisagreementThreshold": 0.88,
    "exemplarDisagreementMargin": 0.10,
    "auditRate": 0.3,
    "auditRateAfter": 0.1,
    "auditRateSwitchCount": 300
  },
  "admission": {
    "referenceSimilarityFloor": 0.62,
    "alternativeMargin": 0.05,
    "witnessMutualSimilarity": 0.85,
    "witnessReferenceFloor": 0.60,
    "impostorSimilarity": 0.90,
    "duplicateSimilarity": 0.985,
    "maximumPerGroup": 6
  }
}
```

- `calibrationMinimum` defaults to 0.95 and is provisional until
  `riftscan check-revision` has been compared across the Mac and the phone
  (ADR-002, open risk 1). Identical models print identically (1.0).
- `confidence` is decision 9: `auditRate(afterRandomAudits:)` returns
  `auditRate` until `auditRateSwitchCount` random audits exist, then
  `auditRateAfter`.
- `admission` is section 7, rules 5-8: the 0.62 reference floor and 0.05
  alternative margin of tier `code`, the 0.85 / 0.60 two-witness thresholds of
  tier `artCorroborated`, the 0.90 impostor rule, the 0.985 dedupe and the cap
  of 6 per art group.

`LearningPolicy.read(from:)` / `write(to:)` handle the file; `riftscan identify
--policy policy.json --overlay overlay.json` runs the recogniser with both and
refuses an overlay whose calibration print is incompatible with the machine.
