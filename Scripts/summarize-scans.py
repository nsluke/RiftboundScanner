"""Summarises scan batches pulled from the phone.

    python3 -I Scripts/summarize-scans.py [scans-folder]

Reads every batch.json / scans.json pair under the folder (the layout the app
writes) and prints verdict counts, top-1/top-3 accuracy, OCR hit rate, timing,
and one line per corrected or rejected scan with the photo to look at.
"""
import glob
import json
import os
import statistics
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "scans"
batch_files = sorted(glob.glob(os.path.join(root, "**", "batch.json"), recursive=True))
if not batch_files:
    print(f"no batches under {root}")
    sys.exit(1)

overall = {"scans": 0, "correct": 0, "judged": 0, "top3": 0}
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

    counts = {"pending": 0, "correct": 0, "corrected": 0, "rejected": 0}
    top3 = 0
    codes = 0
    times = []
    misses = []
    for scan in scans:
        kind = scan["verdict"]["kind"]
        counts[kind] += 1
        times.append(scan["processingSeconds"])
        if scan.get("codeReading"):
            codes += 1
        candidates = scan.get("candidates", [])
        truth = None
        if kind == "correct" and candidates:
            truth = candidates[0]["card"]["id"]
        elif kind == "corrected":
            truth = scan["verdict"]["cardID"]
        if truth and truth in [c["card"]["id"] for c in candidates[:3]]:
            top3 += 1
        if kind in ("corrected", "rejected"):
            misses.append(scan)

    judged = counts["correct"] + counts["corrected"]
    label = batch.get("label") or batch["startedAt"]
    device = batch["device"]
    print(f"== {label}  ({device['model']}, {device['systemVersion']}, app {device['appVersion']}, index {batch['index']['entryCount']} printings)")
    print(f"   scans {len(scans)}  correct {counts['correct']}  corrected {counts['corrected']}  rejected {counts['rejected']}  pending {counts['pending']}")
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
        print(f"   - {verdict['kind']:9} top: {top_text}; actual: {outcome}; code read: {read}; photo: {os.path.join(folder, scan['photoFileName'])}")
    overall["scans"] += len(scans)
    overall["correct"] += counts["correct"]
    overall["judged"] += judged
    overall["top3"] += top3

print()
if overall["judged"]:
    print(f"overall: {overall['scans']} scans, {overall['judged']} judged, top-1 {overall['correct'] / overall['judged']:.0%}, top-3 {overall['top3'] / overall['judged']:.0%}")
else:
    print(f"overall: {overall['scans']} scans, none judged yet")
