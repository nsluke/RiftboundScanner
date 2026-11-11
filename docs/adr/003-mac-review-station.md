# The Mac reviews what the iPhone captures (ADR-003)

Status: accepted, 10 Nov 2026. Amends ADR-002 decision 4 (payload tiers) and §5.5 (writers). Branch `mac-app`.

## Context

The Mac app scans through the iPhone over Continuity Camera. On the feeder's stand the card sits closer than the iPhone's main lens can focus, so every Mac photo is soft: Luke's 43-card feed at 18:37 on 10 Nov matched Safety Inspector as Repulse. The iPhone app does not have this problem: its `.builtInDualWideCamera` falls back to the ultra-wide (0.5×) lens for close subjects, as TCG Archivist does, and keeps 12 MP crops.

A Mac app cannot reach that lens. `videoZoomFactor` is unavailable on macOS; the iPhone 16 Pro's Continuity device reports `primaryConstituentDeviceSwitchingBehavior = unsupported`, no fallback constituents and `minimumFocusDistance = -1`. Center Stage streams from the ultra-wide but frames faces, including the ones in card art: tried as a 0.5× setting, it cropped in and stayed soft. Desk View is the ultra-wide dewarped for a phone on a laptop lid.

So the iPhone captures and the Mac, with its screen and keyboard, reviews.

## Decision

1. **Every scan that waits for a person goes to the server whole.** `UploadTiers` sends every record, and for a scan without a decision `photo_small` and the full `photo`. Decided scans keep ADR-002's tiers; a full photo still only queued when a decision made on the capturing device earns none is withdrawn, so a scan the iPhone settles itself before syncing costs no more than before. A pending scan used to send nothing, so the batch a person still had to review was the one batch the server never saw.
2. **The Mac imports a batch from the server.** History on the Mac lists the server's batches that are not on the Mac ("On the server"). Import copies the batch, every record (keeping its id and decision log, with each candidate's art URL filled back in from the Mac's catalog, since the server keeps none, decision 15) and each scan's best photo into the Mac's own store (`ServerBatchImporter`). The syncing store marks what it imported as held by the server, so nothing goes straight back. An interrupted import resumes; scans already present are skipped.
3. **The Mac is a second writer of decisions.** It reviews the imported batch like its own, and its verdicts go back as the next `seq` of the same scans, with ledger items under the usual `scan:<id>:<seq>` references for a collection batch. The server already orders records last-writer-by-seq and refuses a stale log with `409 seq_conflict` (§5.5), which either app shows as a conflict. The rule for people: review a batch on one device.

## Consequences

- The Pi stores a full photo for every scan that waited for a person, about 1 MB each, so a 300-card box adds about 300 MB. The asset budget sweep still governs.
- The iPhone's own review list keeps showing scans the Mac decided as pending, until the phone pulls decisions back from the server. That pull is the follow-up.
- A record is forwarded through `JSONValue`, which now keeps integers beyond 2^53 exact; as a `Double` it rounded the three 64-bit perceptual hashes. Records uploaded before this fix keep the rounded hashes in the server's copy, and an import of one carries them. The server's learning loop reads the separate descriptor upload, which sends hashes as strings, so it was never affected.
- A batch's `index` summary on the Mac is the Mac's own, because the server does not record the capturing device's. It is informational only.
- The importer needs the iPhone app built after `7ba97f4` (the `/health` decode fix); before it, the iPhone synced nothing.
