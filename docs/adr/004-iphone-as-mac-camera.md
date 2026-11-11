# The iPhone app as the Mac's camera (ADR-004)

Status: accepted, 10 Nov 2026. Builds on ADR-003. Branch `mac-app`.

## Context

The Mac scans through the iPhone over Continuity Camera, and Continuity Camera only gives a Mac app the iPhone's main lens (ADR-003 has the evidence: no zoom on macOS, no constituent lenses, Center Stage crops in on faces). The card on the feeder's stand is too close for that lens, so every Mac photo is soft. The iPhone app's dual-wide camera falls back to the 0.5× lens up close and takes 12 MP photos. ADR-003 moved capture to the iPhone and review to the Mac through the server; this decision keeps the whole run on the Mac and borrows only the iPhone app's camera.

## Decision

1. **The iPhone app serves its camera on the local network.** Its Scan tab has a Camera for Mac button. The screen it opens starts the camera, keeps the phone awake, and advertises the Bonjour service `_riftcam._tcp` (`RemoteCameraListener`). It serves one Mac at a time; a second Mac that connects takes over.
2. **One small protocol, framed on TCP** (`RemoteCameraWire`): each frame is a JSON message plus a binary payload, each prefixed with a 4-byte big-endian length. The Mac says `hello` with the wire version and its name; the iPhone answers `ready` with its upright photo size and whether it has a torch, then streams `preview` JPEGs (960 px, at most eight a second, newest only) and answers `capture(id)` with `photo(id)` or `failed(id)`, and `setTorch` with `torch`. A version mismatch ends the link with a message naming both versions.
3. **On the Mac the phone is one more camera.** `RemoteCameraBrowser` lists each advertising phone in the camera picker as "<name> (Riftbound app)", kind `iPhoneApp`, preferred over every other kind. `MacCamera` is the scanner's camera and routes each call to the Mac's capture engine or to the phone's `RemoteCameraSession`. The feeder, the guide crop (`FrameGuide.iPhoneApp`, the phone's own framing), the recogniser and the review flow do not know the difference. A phone that closes the screen drops off Bonjour, which the camera source already treats as a camera that went away: feeding stops and the scan page waits for it.
4. **The batch belongs to the Mac.** Photos arrive on the Mac and are scanned into its own batch, so there is no import and no second writer. ADR-003's server import stays for runs done on the phone alone.

## Consequences

- Both apps ask for Local Network access once, and both list `_riftcam._tcp` in `NSBonjourServices`. The phone and the Mac must share a network: a sandboxed Mac app's browse with peer-to-peer Wi-Fi fails with `NoAuth`, so it is off.
- The iPhone must stay on the Camera for Mac screen with its screen on: iOS stops the camera of an app that leaves the foreground. Leaving the screen turns the torch off.
- A photo is 3–5 MB; at Wi-Fi speeds it adds about a third of a second per card. A capture that gets no answer in 20 s fails the card rather than stalling the run.
- Both apps must come from builds with the same wire version.
