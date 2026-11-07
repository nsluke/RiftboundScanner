# Learning evaluation: the admission gate and what it yields

ADR-002 (section 7) lets the recogniser learn real-photo feature prints from
confirmed scans. This document covers the three pieces work item P4 adds to
`RiftboundRecognizer` and `riftscan`: the admission gate that decides which
scans become exemplars, the contract that keeps the Swift gate and the
server's Python port in agreement, and the evaluation protocol with its first
measured results on the three batches scanned before the ledger existed.

## 1. The gate: `ExemplarAdmission` (gate version 2)

`ExemplarAdmission(policy: LearningPolicy.AdmissionPolicy, calibrationHash:)`
is a pure function. `decide(candidate, witnesses:, existing:)` takes one
`AdmissionInput`, the other scans offered as witnesses for the art tier (the
gate checks their eligibility itself) and the exemplars already admitted for
the same calibration hash, and returns an `AdmissionOutcome`. Nothing in it
touches a file, a clock or Vision, so the same inputs give the same answer on
the Mac, the phone and the Pi.

### Inputs (`AdmissionInput`)

| Field | From | Used by |
|---|---|---|
| `scanID`, `batchID` | the record | identity, witnesses, folds |
| `decisionSource` (`human`, `autoAccepted`, `audit`, `spotCheck`, `legacy`), `decisionKind` (`pending`, `correct`, `corrected`, `rejected`, `voided`), `cardID` | the latest `Decision` | rule 1 |
| `placement` (`detected`, `wholeImage`) | the analysis | rule 2 |
| `calibrationHash` | `EngineStamp` | rule 3 |
| `captureQuality`, `trainingQuality` (`standard`, `legacy`) | the record and its batch | rule 4 |
| `code` (`source` edgeBand/fullImage, `origin` literal/alternative, `agreement` with the confirmed card), or absent | the analysis | rule 5 |
| `referenceSimilarity` | fp cosine of the oriented descriptor to the confirmed card's reference, computed where the reference prints live (phone or Mac) | rules 5 and 8 |
| `codeAlternatives[{code, origin, referenceSimilarity?}]` | every code the reading could name (`CodeReading.alternatives`: the literal reading when the index knows it, then the parser's ranked digit repairs), each with the best reference similarity among the printings it names exactly | rule 5 |
| `featurePrint` | the oriented descriptor | rules 5-8 |

`ExistingExemplar` is `{scanID, artGroup, featurePrint, referenceSimilarity}`:
what the server's `exemplars` row holds beyond the overlay's wire exemplar.

### Rules, in order

1. The latest decision is human (`human`, `audit`, `spotCheck`), confirms a
   card (`correct`/`corrected`) and snapshots its id. `autoAccepted` and
   `legacy` never admit (`decisionSource`); `pending`/`rejected`/`voided`
   never do (`decisionKind`).
2. The card was `detected`, not assumed to fill the photo (`placement`).
3. The descriptor's calibration hash equals the overlay's (`calibrationMismatch`).
4. `captureQuality == standard` and the batch's `trainingQuality != legacy`.
5. Tier **code**: a code was read from an **edge band**, **literally**, with
   **exact** agreement with the confirmed card; `referenceSimilarity >= 0.62`
   (`referenceBelowFloor`); and the confirmed card's reference similarity
   exceeds every code alternative naming a **different** `ArtGroup` by
   `>= 0.05` (`alternativeMargin`; an alternative with no reference similarity
   names no indexed printing and is ignored, as is one in the same group).
   A code from the full image (`codeSource`), an alternative-won code
   (`codeNotLiteral`) or a disagreeing one (`codeDisagrees`) is rejected
   outright: it is neither tier.
   Tier **artCorroborated**: no code was read; the scan itself clears the
   witness floor (`referenceSimilarity >= 0.60`, else
   `witnessReferenceBelowFloor`), and at least one witness corroborates it: a
   different scan id, codeless, the same `ArtGroup`, passing rules 1-4, with
   `referenceSimilarity >= 0.60` and mutual feature-print similarity
   `>= 0.85`. None -> `needsSecondWitness`. The outcome lists the
   corroborators; a run admits them together.
6. An existing exemplar of **another** group with similarity `>= 0.90` ->
   `blocked(by: scanID, similarity:)` (the closest one; the server records
   `blocking_exemplar_id` and an `exemplar_conflicts` row).
7. An existing exemplar of the **same** group with similarity `>= 0.985` ->
   `duplicate(of:, similarity:)`.
8. A group already holding `maximumPerGroup` (6) keeps its **medoid** (highest
   mean similarity to the other candidates), then adds by farthest-point
   selection (the candidate least similar to anything kept) from the
   candidates whose reference similarity is in the **top half**, and from the
   rest only once that pool is exhausted. The new scan is `admitted` with
   `evicted` naming what it displaces, or `rejected(capReached)`. Ties fall to
   the lexically smaller scan id.

`ExemplarAdmission.run(inputs, existing:)` gates a set of scans the way the
server does when a batch arrives: coded scans first (they need no witness),
then codeless ones with every other codeless input of their group as
witnesses; exemplars admitted earlier count as `existing` for later scans.
`replay` returns the same calls as `AdmissionRequest`s, for `gate-diff`.

### Outcome JSON (also the `admit/dry-run` response)

```json
{"outcome": "admitted", "tier": "code", "corroborators": [], "evicted": ["<scan uuid>"]}
{"outcome": "rejected", "reason": "placement"}
{"outcome": "needsSecondWitness"}
{"outcome": "blocked", "blockingScanID": "<scan uuid>", "similarity": 0.93}
{"outcome": "duplicate", "duplicateOf": "<scan uuid>", "similarity": 0.99}
```

Reasons: `decisionSource`, `decisionKind`, `noCardID`, `placement`,
`calibrationMismatch`, `captureQuality`, `trainingQuality`, `codeSource`,
`codeNotLiteral`, `codeDisagrees`, `referenceBelowFloor`,
`alternativeMargin`, `witnessReferenceBelowFloor`, `capReached`.

## 2. The similarity contract

Both gates must compute the same number from the same bytes.
`SimilarityContract.similarity(a, b)`:

1. Inputs are the Float32 elements a `FeaturePrint` stores, taken as given
   (never re-normalised).
2. The dot product is a Float64 running sum over the elements in order
   (Python: `math.sumprod(array('f', a), array('f', b))`; the fixture confirms
   it agrees with the running sum after rounding).
3. Clamp to 0...1, then round to 4 decimals as `round_half_even(x * 10000) /
   10000` with an IEEE double multiply: Swift `(x * 10_000).rounded(.toNearestOrEven) / 10_000`,
   Python `round(x * 10000) / 10000`. (Python's `round(x, 4)` rounds the exact
   binary value and can differ at decimal halves; the port must use the
   multiply form.)
4. Similarities that arrive as inputs (`referenceSimilarity`, the
   alternatives' similarities) are rounded the same way before comparison,
   and so is **every arithmetic result the gate compares**: the margin rule
   rounds `reference - alternative` before testing it against 0.05, and the
   cap rule rounds its mean similarities. This is not pedantry: in binary
   doubles `0.70 - 0.65`, `0.85 - 0.80` and `0.95 - 0.90` are all
   `0.04999...` while `0.80 - 0.75` is `0.05000...04`, so an unrounded
   comparison admits or rejects an exact 0.05 margin by operand luck. The
   fixture pins the rounded form (`code-alternative-margin-0.70-vs-0.65-admits`,
   `...-0.85-vs-0.80-admits`, `...-0.70-vs-0.6501-rejected`); a port that
   subtracts raw doubles fails it.

A consequence worth knowing: a value within 0.00005 of a threshold lands on
it. The fixture's similarity vectors pin this at every threshold, e.g.
Float32(0.84995) rounds to 0.8500 (admitted), Float32(0.61995) to 0.6199
(rejected), Float32(0.98505) to 0.9851 (duplicate).

## 3. The shared fixture: `Tests/Fixtures/admission-cases.json`

```json
{
  "gateVersion": 2,
  "contract": {"decimals": 4, "rounding": "round_half_even(x * 10000) / 10000 over a Float64 running sum ..."},
  "calibrationHash": "c0ffee00c0ffee00c0ffee00c0ffee00",
  "policy": {"referenceSimilarityFloor": 0.62, "alternativeMargin": 0.05, "witnessMutualSimilarity": 0.85,
             "witnessReferenceFloor": 0.60, "impostorSimilarity": 0.90, "duplicateSimilarity": 0.985, "maximumPerGroup": 6},
  "cases": [{"name": "...", "candidate": {AdmissionInput}, "witnesses": [AdmissionInput], "existing": [ExistingExemplar], "expected": {AdmissionOutcome}}],
  "similarityVectors": [{"name": "...", "a": "<base64 Float32>", "b": "<base64 Float32>", "expected": 0.6201}]
}
```

63 cases cover every rule, every rejection reason, both tiers, the impostor
and duplicate outcomes, the cap (a full group keeps its medoid; a low-variety
candidate is turned away; five members admit a sixth), twelve threshold-edge
cases and the rounded margin difference (section 2, point 4); 15 vectors pin
the contract at each threshold ± 0.00005. Feature
prints are 4-element Float32 vectors as base64 little-endian bytes, exactly
as every other print in the package travels. `ExemplarAdmissionTests` runs
every case through the Swift gate; S7's `tests/test_admission.py` runs the
same file through the Python port.

A request to `POST /api/learning/admit/dry-run` is one case without `name`
and `expected`, plus the policy and hash:

```json
{"gateVersion": 2, "calibrationHash": "<hex>", "policy": {...}, "candidate": {...}, "witnesses": [...], "existing": [...]}
```

and the response is the outcome JSON above. `riftscan gate-diff` posts the
fixture's cases (or a dump's folds, replayed call by call with the exemplars
as they stood) and reports every disagreement.

## 4. Evaluation protocol

```bash
swift run -c release riftscan import-scans scans --output evaluation/manifest.json
swift run -c release riftscan build-overlay evaluation/manifest.json --leave-one-out \
  --output evaluation/overlay.json --dump evaluation/admissions.json \
  [--accept-legacy --derive-capture-quality --training-quality standard]
swift run -c release riftscan evaluate evaluation/manifest.json --dump evaluation/baseline.json --label baseline
swift run -c release riftscan evaluate evaluation/manifest.json --batch <held-out batch uuid> \
  --overlay evaluation/overlay-holdout-<prefix>.json --dump evaluation/fold-<prefix>.json --label fold-<prefix>
swift run -c release riftscan report evaluation/fold-*.json --baseline evaluation/baseline.json
swift run -c release riftscan admission-report evaluation/admissions.json
```

- **import-scans** reads v1 and v2 `scans.json` files. One case per scan whose
  latest decision was made by a person (`human`, `audit`, `spotCheck`, or the
  `legacy` decision a v1 verdict stands for) and confirms a card; pending,
  rejected, voided and `autoAccepted` scans are skipped and counted.
  `samplingWeight` is `1 / auditRate` (the policy's `confidence.auditRate`,
  0.3) for `audit` cases and 1 otherwise. Photos are loaded at 4096 px and
  their size recorded. Each case carries `captureQuality` **as the app
  decodes the record** (what it states; `legacy` when it states nothing,
  which is every v1 record, exactly as `ScanRecord` and
  `Scripts/summarize-scans.py` read it) and, beside it,
  `derivedCaptureQuality`: what the app's rule would have written had it
  existed (`standard` iff the record has a `crop` and the photo is a
  portrait 63:88 image 1800-2200 px tall). The second is a measurement aid
  for `build-overlay --derive-capture-quality`, never what the gate sees on
  the phone. The manifest records the platform.
- **build-overlay** recognises every photo once with the bare index and
  builds each scan's `AdmissionInput` from the result (placement from the
  Mac's detection; code source, **origin** (`CodeReading.origin`, literal or
  parser alternative) and agreement from the Mac's reading; one
  `CodeAlternative` per code the reading could name (`CodeReading.alternatives`)
  with the best reference similarity of the printings it names; the
  confirmed card's reference similarity under the contract; the oriented
  feature print), then runs the gate per fold and writes one `ExemplarIndex`
  (version 1, the Mac's calibration print) per fold. It prints the exemplar
  count per fold and exits 1 when any fold yields zero exemplars. `--dump`
  writes an `AdmissionDump`: every analysed scan (input, the best similarity
  to another art group's reference, the derivable capture quality) and each
  fold's records. Three measurement-only assumptions exist for the pre-ledger
  batches, each recorded in the dump and printed by `admission-report`:
  `--accept-legacy` (legacy decisions treated as human), `--derive-capture-quality`
  (the derivable capture quality in place of the recorded one) and
  `--training-quality standard` (the batch override assumed standard). An
  overlay built under any of them is a smoke-test artefact.
- **evaluate** reports raw and weighted top-1/top-3, the confident tier's
  precision and coverage (decision 9's rule: literal exact code, score
  `>= 1.0`, no exemplar of another art group `>= 0.88` beating the top's own
  evidence by `>= 0.10`) with its 95 % Wilson lower bound, and the exemplar
  hit rate (the winner owed score to an exemplar). `--batch` restricts to a
  held-out batch, `--exclude-batch` drops a batch's exemplars from the overlay.
- **report** re-tallies dumps and compares each with the baseline on their
  shared cases; it states whether the shipping rule holds (top-1 and
  confident precision not lower than baseline).
- **admission-report** prints the impostor distribution (similarity between
  scans of different art groups: p50/p95/p99/max and how many pairs reach the
  0.90 impostor rule), the reference floor's ROC and the outcomes by reason.

The Mac path and the phone path see the same code evidence: the reading's
own `origin` decides `codeNotLiteral` (and the confident tier's `codeRepaired`),
and the parser's digit alternatives feed the margin rule with the reference
similarity of whatever printing each one names.

## 5. Results on the three pre-ledger batches (2026-11-07, macOS 26.6, M-series)

Calibration print hash `c9008e0eafa62e6827a43aea9bd2f524` (the same as the
index's; the Mac-to-phone cosine is still unmeasured, ADR open risk 1).
113 cases: Testing/1CAED0F4 85, 6B23DFD9 14, New batch/BF7582A9 14, all
`legacy` decisions in `calibration` batches with `legacy` training quality.
No record states a `captureQuality`, so all 113 are `legacy` captures as the
app, `summarize-scans.py` and `import-scans` read them; 28 of them (14 + 0 +
14) have a crop record and a 1454 x 2030 photo, which is what
`--derive-capture-quality` turns into `standard`. Weighted total 113.0 (no
audit cases exist yet).

### Strict gate: zero exemplars, every fold fails

Every one of the 113 decisions is `legacy` (a v1 verdict), so rule 1 refuses
all of them before anything else is looked at, and rule 4 would refuse every
capture (none states a quality) and the `legacy` training override regardless:

| Fold (held-out batch) | Scans gated | Exemplars | Outcomes |
|---|---|---|---|
| holdout-1CAED0F4 | 28 | **0** | rejected/decisionSource 28 |
| holdout-6B23DFD9 | 99 | **0** | rejected/decisionSource 99 |
| holdout-BF7582A9 | 99 | **0** | rejected/decisionSource 99 |

`build-overlay --leave-one-out` writes the three empty overlays and exits 1
("folds ... yielded zero exemplars"). This is the ADR's expectation for the
pre-ledger batches (decision 6: legacy ledgers nothing and trains nothing
until an on-device re-identify (A11) rewrites the analysis; open risk: "the
three legacy batches may seed very few exemplars") and the fold guard doing
its job: there is nothing to evaluate an overlay against.

### Relaxed gate (`--accept-legacy --derive-capture-quality --training-quality standard`): what the gate would yield

To measure what the gate would make of these photos if the same judgements
had been made in the app today, `build-overlay` was run with the three
measurement-only assumptions (legacy decisions treated as human, capture
quality derived from the crop record and photo size, batch training quality
assumed standard). Rule 1, the capture rule and the batch override then
pass; everything else is the real gate on the Mac's own recognition of each
photo. The derivation matters: with only `--accept-legacy --training-quality
standard`, rule 4 refuses every detected scan (`captureQuality` 19 / 82 / 83
per fold, after `placement` has taken 9 / 17 / 16) and all three folds yield
0, which is exactly what A11's re-identify over the stored records would see
on the phone (the records say `legacy`, and the app never re-derives). The
figures below therefore describe the photos, not the records:

| Fold (held-out batch) | Scans gated | Exemplars (groups) | Outcomes |
|---|---|---|---|
| holdout-1CAED0F4 | 28 | **9** (9) | admitted/code 9, rejected/captureQuality 10, rejected/placement 9 |
| holdout-6B23DFD9 | 99 | **18** (18) | admitted/code 18, rejected/captureQuality 64, rejected/placement 17 |
| holdout-BF7582A9 | 99 | **9** (9) | admitted/code 9, rejected/captureQuality 74, rejected/placement 16 |

Of the 113 scans, 28 derive as standard captures (14 in Testing, 14 in New
batch, none in 6B23DFD9); on the Mac 92 are `detected` and 21 `wholeImage`,
and 18 are both standard and detected. All 18 carry an exact literal
edge-band code and clear the 0.62 floor (reference similarities 0.672–0.868),
so all 18 are admitted at tier `code` (9 VEN printings plus `sfd-104` from
Testing, 9 VEN printings from New batch; one exemplar per group, no
duplicates, no impostor blocks, no group near the cap). The margin rule now
sees the parser's real alternatives (`CodeReading.alternatives`): 52 of the
113 readings offer at least one code naming another art group with an
indexed printing, 12 of the 18 admitted scans among them, and the smallest
margin on an admitted scan is 0.109 (`ven-117` over the `VEN-127` repair),
twice the 0.05 rule. Twelve scans in the batches would have failed the margin
(down to −0.03: the alternative's printing resembles the photo more than the
confirmed card does), but every one of them is a legacy capture or a
whole-image placement, so rules 2 and 4 refuse them first. Every code in
these batches was read literally (86 readings, 64 from an edge band), so
`codeNotLiteral` had nothing to fire on. Nothing reached the art tier: every
codeless scan in these batches is a legacy capture. Ten derivable-standard
captures were turned away by rule 2 because the Mac assumed the whole image
for them (the phone had done the same for 7 of New batch's 14).

### Baseline vs overlay, leave-one-batch-out

Baseline (bare index, all 113 cases): top-1 80.5 %, top-3 86.7 % (weighted
the same, every weight being 1); confident tier 86 of 113 (coverage 76.1 %),
83 right (precision 96.5 %, 95 % Wilson lower bound 90.2 %). The three
confident-but-wrong scans are the known OCR misreads (`sfd-024` for
`sfd-014`, `unl-222` for `unl-227`) and a `ven-080` for `unl-184`.

Each relaxed fold's overlay was evaluated on its held-out batch and compared
with the baseline on the same cases:

| Held-out batch | Exemplars | Top-1 base → overlay | Top-3 | Confident precision (n) | Coverage | Exemplar hit | Shipping rule |
|---|---|---|---|---|---|---|---|
| Testing (85) | 9 | 76.5 % → **75.3 %** (−1.2 pt) | 84.7 % → 81.2 % | 98.3 % → 98.3 % (57/58) | 68.2 % | 15.3 % | **fails** |
| 6B23DFD9 (14) | 18 | 85.7 % → 85.7 % | 85.7 % → 85.7 % | 85.7 % → 85.7 % (12/14) | 100 % | 0 % | holds |
| New batch (14) | 9 | 100 % → 100 % | 100 % → 100 % | 100 % → 100 % (14/14) | 100 % | 0 % | holds |

The overlays never helped because the held-out batches share almost no art
groups with the batches that trained them (the Testing batch is SFD cards fed
repeatedly; the other two are VEN and UNL), and the Testing fold shows the
one way a small overlay hurts: the `ven-117` exemplar (a New-batch photo)
sits at feature-print cosine 0.65–0.81 to Testing's legacy photos, which
lifts it into the top three of 28 of the 85 cases (18 of them codeless,
tray-locked captures whose own reference scores are only 0.67–0.72) and,
once, past the true card (`sfd-106-221`, reference 0.70, exemplar-lifted
`ven-117` 0.72). The
confident tier is untouched (a lift without a code cannot reach 1.0, and
no code-bearing scan was affected). Under the ADR's shipping rule this
overlay does not ship, which is the protocol working as written: the three
old batches are a smoke set, and box 1's first ~100 human-reviewed,
standard-capture scans are the first real held-out set.

### Impostor distribution and the reference floor

`admission-report` over the 113 analysed scans:

| Population | Pairs | Impostor fp cosine p50 / p95 / p99 / max | Pairs ≥ 0.90 |
|---|---|---|---|
| all 113 scans (different art groups) | 6,288 | 0.650 / 0.843 / 0.882 / 0.956 | 27 |
| the 18 standard, detected scans (what the gate can admit) | 153 | 0.618 / 0.717 / 0.752 / 0.800 | 0 |

The 27 near-identical cross-group pairs are the legacy photos: 17 are pairs
of whole-image canvases, 23 involve at least one legacy capture, and every
one has a legacy capture or a whole-image placement on at least one side
(tray-locked canvases look alike whatever card lies in them). Among the
captures the gate can actually admit, nothing comes within 0.10 of the 0.90
impostor rule, so rule 6 is a backstop here, not an active filter.

Reference floor ROC (genuine = each scan's similarity to its confirmed card;
impostor = its best similarity to another art group's reference), all 113:

| floor | genuine pass | impostor pass |
|---|---|---|
| 0.56 | 100.0 % | 93.8 % |
| 0.60 | 99.1 % | 88.5 % |
| **0.62** | **99.1 %** | **84.1 %** |
| 0.66 | 89.4 % | 79.6 % |
| 0.70 | 75.2 % | 70.8 % |
| 0.80 | 38.1 % | 18.6 % |

The floor is a sanity check, not a classifier: at 0.62 it passes 99.1 % of
genuine scans (the one it drops, `ven-052-166` at 0.562, is a legacy
whole-image capture whose code was read off the full photo, which rules 2
and 5 refuse as well) while most impostor references also pass, which is why the
gate leans on the code, the placement and the capture quality rather than on
the floor. Raising it would cost genuine scans long before it bought
selectivity (0.70 drops a quarter of them). Median genuine similarity is
0.763; the admitted 18 sit at 0.672–0.868 against best-other-group references
of 0.523–0.781.

### Thresholds shipped

`LearningPolicy.admission` ships with the ADR's values, unchanged by these
measurements: `referenceSimilarityFloor` 0.62, `alternativeMargin` 0.05,
`witnessMutualSimilarity` 0.85, `witnessReferenceFloor` 0.60,
`impostorSimilarity` 0.90, `duplicateSimilarity` 0.985, `maximumPerGroup` 6;
`confidence` as decision 9 (`minimumFusedScore` 1.0, literal code required,
veto at 0.88 with a 0.10 margin, `auditRate` 0.3 then 0.1 after 300 random
audits); `calibrationMinimum` 0.95 (provisional until `check-revision` is
compared across the Mac and the phone). What this run established:

- The strict gate yields **0** exemplars from the legacy batches; the smoke
  set seeds nothing until A11's re-identify produces fresh analyses with
  human-sourced decisions, and even then rule 4 keeps every stored record out
  (none states a `captureQuality`, and the app never re-derives one): the 28
  derivable-standard captures (18 detected on the Mac) are candidates only
  for photos re-taken through today's guide.
- Relaxed, the gate admits exactly the 18 derivable-standard, detected,
  code-bearing scans and nothing else. The margin rule was exercised on real
  alternatives for the first time (12 of the 18 carry an other-group
  alternative; the closest is 0.109 away) and never fired on an admissible
  scan; no impostor, duplicate or cap decision fired either, so the
  thresholds remain the ADR's a-priori values and the open risk about their
  basis stands.
- The impostor rule (0.90) has 0.10 of headroom on admissible captures and
  would have fired 27 times on legacy canvases, which rules 2 and 4 keep out.
- An overlay built from another batch's cards cannot help a held-out batch
  and can cost a point of top-1 on codeless legacy photos; the shipping rule
  catches it. The first meaningful measurement needs a held-out batch that
  shares art groups with its training folds: box 1.

Dumps and overlays were written outside the repository (`evaluation/` is
ignored); re-run the commands in section 4 to regenerate them. The whole
pass was re-run after the OCR hygiene work (P2: ranked alternatives,
literal/alternative origin) and the confidence rule (A7) landed, with the
gate seeing the reading's real origin and alternatives; every number in this
section is from that run and none moved. Runtime on an
M-series Mac: about 1.5 s per photo, so a full leave-one-out pass (analysis
plus three fold evaluations plus the baseline) is about eight minutes.

### Manual checks

- `gate-diff` against the real server needs S7. Until then it was exercised
  against a stub answering `needsSecondWitness` to every request
  (`python3 -m http.server`-style, 58 requests): the 8 fixture cases whose
  expected outcome is `needsSecondWitness` agree, the other 50 differ, exit 1;
  against a closed port every request fails and the command exits 1.
- The fold guard: the strict run above exits 1 naming all three folds, and
  so does the `--accept-legacy --training-quality standard` run without
  `--derive-capture-quality` (0 exemplars, every detected scan
  `rejected/captureQuality`).
- `import-scans` reports `standard captures 0 (+14 derivable from crop and
  size)` for Testing and New batch, matching `summarize-scans.py`'s
  `captures standard 0 / legacy 14` and the app's decode of the same files.
