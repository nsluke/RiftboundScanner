"""Summarises scan batches pulled from the phone.

    python3 -I Scripts/summarize-scans.py [scans-folder]

Reads every batch.json / scans.json pair under the folder (the layout the app
writes) and prints verdict counts, top-1/top-3 accuracy, OCR hit rate, timing,
who decided (human, auto-accepted, audit, spot-check, legacy), and one line
per corrected or rejected scan with the photo to look at.

Reads version 1 files (a bare `verdict` per scan, no `purpose` on the batch)
and version 2 files (ADR-002: a `decisions` log per scan, `purpose`,
`trainingQuality` and `captureQuality`). A v1 batch is a calibration sitting
and each of its judged scans counts as one `legacy` decision, exactly as the
app decodes it.
"""
import glob
import json
import os
import statistics
import sys

VERDICT_KINDS = ("pending", "correct", "corrected", "rejected", "voided")
SOURCES = ("human", "autoAccepted", "audit", "spotCheck", "legacy")


def decisions_of(scan):
    """The scan's decision log, synthesising the legacy decision a v1 scan gets."""
    decisions = scan.get("decisions") or []
    if decisions:
        return decisions
    verdict = scan["verdict"]
    if verdict["kind"] == "pending":
        return []
    candidates = scan.get("candidates", [])
    card_id = None
    if verdict["kind"] == "correct" and candidates:
        card_id = candidates[0]["card"]["id"]
    elif verdict["kind"] == "corrected":
        card_id = verdict["cardID"]
    return [{"seq": 1, "verdict": verdict, "cardID": card_id, "source": "legacy", "decidedAt": scan.get("verdictAt")}]


def confirmed_card(scan):
    decisions = decisions_of(scan)
    return decisions[-1].get("cardID") if decisions else None


root = sys.argv[1] if len(sys.argv) > 1 else "scans"
batch_files = sorted(glob.glob(os.path.join(root, "**", "batch.json"), recursive=True))
if not batch_files:
    print(f"no batches under {root}")
    sys.exit(1)

overall = {"scans": 0, "correct": 0, "judged": 0, "top3": 0, "legacy": 0, "voided": 0}
overall_sources = {source: 0 for source in SOURCES}
for batch_file in batch_files:
    folder = os.path.dirname(batch_file)
    with open(batch_file) as f:
        batch = json.load(f)
    scans_file = os.path.join(folder, "scans.json")
    scans = []
    if os.path.exists(scans_file):
        with open(scans_file) as f:
            scans = json.load(f)
    scans.sort(key=lambda s: s["capturedAt"])

    counts = {kind: 0 for kind in VERDICT_KINDS}
    sources = {source: 0 for source in SOURCES}
    latest_sources = {source: 0 for source in SOURCES}
    quality = {"standard": 0, "legacy": 0}
    top3 = 0
    codes = 0
    analysed = 0
    times = []
    misses = []
    for scan in scans:
        kind = scan["verdict"]["kind"]
        counts[kind] = counts.get(kind, 0) + 1
        times.append(scan["processingSeconds"])
        if scan.get("codeReading"):
            codes += 1
        if scan.get("analysis"):
            analysed += 1
        quality[scan.get("captureQuality", "legacy")] += 1
        decisions = decisions_of(scan)
        for decision in decisions:
            sources[decision["source"]] = sources.get(decision["source"], 0) + 1
        if decisions:
            latest = decisions[-1]["source"]
            latest_sources[latest] = latest_sources.get(latest, 0) + 1
        candidates = scan.get("candidates", [])
        truth = confirmed_card(scan) if kind in ("correct", "corrected") else None
        if truth and truth in [c["card"]["id"] for c in candidates[:3]]:
            top3 += 1
        if kind in ("corrected", "rejected"):
            misses.append(scan)

    judged = counts["correct"] + counts["corrected"]
    label = batch.get("label") or batch["startedAt"]
    device = batch["device"]
    purpose = batch.get("purpose", "calibration")
    training = batch.get("trainingQuality", "legacy")
    print(f"== {label}  ({device['model']}, {device['systemVersion']}, app {device['appVersion']}, index {batch['index']['entryCount']} printings)")
    print(f"   purpose {purpose}  training {training}  captures standard {quality['standard']} / legacy {quality['legacy']}  analysed {analysed}")
    print(f"   scans {len(scans)}  correct {counts['correct']}  corrected {counts['corrected']}  rejected {counts['rejected']}  voided {counts['voided']}  pending {counts['pending']}")
    decided = sum(latest_sources.values())
    if decided:
        by_source = "  ".join(f"{source} {latest_sources[source]}" for source in SOURCES if latest_sources[source])
        total_decisions = sum(sources.values())
        print(f"   decided by {by_source}  ({total_decisions} decisions in all)")
    if scans:
        line = f"   code read {codes / len(scans):.0%}  median time {statistics.median(times):.2f}s"
        if judged:
            line = f"   top-1 {counts['correct'] / judged:.0%}  top-3 {top3 / judged:.0%}" + line[2:]
        print(line)
    for scan in misses:
        top = scan["candidates"][0]["card"] if scan.get("candidates") else None
        verdict = scan["verdict"]
        outcome = verdict.get("cardID") or verdict.get("reason")
        read = (scan.get("codeReading") or {}).get("code", "none")
        top_text = f"{top['code']} {top['displayName']}" if top else "no match"
        source = decisions_of(scan)[-1]["source"]
        print(f"   - {verdict['kind']:9} ({source}) top: {top_text}; actual: {outcome}; code read: {read}; photo: {os.path.join(folder, scan['photoFileName'])}")
    overall["scans"] += len(scans)
    overall["correct"] += counts["correct"]
    overall["judged"] += judged
    overall["top3"] += top3
    overall["voided"] += counts["voided"]
    overall["legacy"] += latest_sources["legacy"]
    for source in SOURCES:
        overall_sources[source] += sources[source]

print()
if overall["judged"]:
    print(f"overall: {overall['scans']} scans, {overall['judged']} judged, top-1 {overall['correct'] / overall['judged']:.0%}, top-3 {overall['top3'] / overall['judged']:.0%}")
else:
    print(f"overall: {overall['scans']} scans, none judged yet")
print("decisions: " + "  ".join(f"{source} {overall_sources[source]}" for source in SOURCES) + f"  (legacy-decided scans {overall['legacy']}, voided {overall['voided']})")
