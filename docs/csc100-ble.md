# TCG Archivist CSC100 — Bluetooth LE notes

Findings from probing Luke's unit with `Scripts/blescan.sh` (2026-11-05). Nothing here
comes from vendor documentation; it is all observed behaviour.

## Advertising

| Field | Value |
| --- | --- |
| Local name | `ESP_OTA_GATTS` (Espressif's BLE OTA example default — the feeder is an ESP32) |
| Advertised service | `1811` (Alert Notification; not actually present after connect) |
| Connectable | yes, no pairing or bonding requested |
| Typical RSSI next to the Mac | about -40 dBm |

The device stops advertising while the vendor app holds a connection and only
reappears after the app disconnects (or after a USB power cycle). Only one central
can be connected at a time.

## GATT layout

One primary service, two characteristics. ATT MTU after connect: 512 with response,
20 without.

| UUID | Role | Properties |
| --- | --- | --- |
| `7E8A1E10-1234-4BCD-8AEF-1234567890AB` | service | primary |
| `7E8A1E11-1234-4BCD-8AEF-1234567890AB` | command (phone → feeder) | write (with response) |
| `7E8A1E12-1234-4BCD-8AEF-1234567890AB` | status (feeder → phone) | read, notify; has a 2902 CCCD |

## Observed traffic

| When | Direction | Bytes | ASCII |
| --- | --- | --- | --- |
| Right after subscribing to the status characteristic | feeder → central | `43 4f 4e 4e 45 43 54 45 44` | `CONNECTED` |
| Vendor app, immediately after subscribing (seen via `fake` mode) | app → feeder | `46 57 56 45 52` | `FWVER` |
| Vendor app, ~7 s after getting a non-version reply to `FWVER` | app → feeder | 109 bytes | `OTA:https://zxdudoympurjutnyimsg.supabase.co/storage/v1/object/public/Firmware/TCGArch_ESP32_0_1_5_preenc.bin` |

So the app's handshake is: subscribe → `FWVER` → compare the reply with the latest
version → if older, send `OTA:<url>` and let the feeder fetch the image itself (the
ESP32 therefore has Wi-Fi, or at least the app thinks it does). The image is publicly
downloadable, 1,315,328 bytes, and fully encrypted (8.0 bits/byte, no strings), so
static analysis is a dead end.

Status messages are plain ASCII with no terminator, and so are commands.

## Command vocabulary (captured from the vendor app via `fake` mode, 2026-11-05)

| Command | Reply | Meaning |
| --- | --- | --- |
| `FWVER` | `FWVER:0.1.5` | Firmware version query. The app sends it right after subscribing and pushes `OTA:<url>` if the reply is not the current version. |
| `MOTOR:START:80` | `MOTOR:CARDLEN_SET` at once, then `MOTOR:COMPLETE` ~0.36 s later, or `MOTOR:END` ~0.54 s later when the hopper is empty | Advance one card. The argument (`80`, the app's value) is acknowledged as a card length, so it is probably distance, not speed. The app repeats it per card. |
| `MOTOR:STOP` | (none seen) | Stop the motor. The app sends it when the user ends the session; a safety net, not part of the per-card cycle. |
| `OTA:<https url>` | — | Firmware update; the feeder fetches the image itself. Never send this by hand. |

Live run against the real feeder on 2026-11-05 (`Scripts/blescan.sh feed ESP_OTA_GATTS 80 3`):

```
11:39:04.676 → MOTOR:START:80
11:39:04.750 ← MOTOR:CARDLEN_SET
11:39:05.108 ← MOTOR:COMPLETE
11:39:07.828 → MOTOR:STOP        (no reply)
```

Luke confirmed exactly one Magic card was fed. So the per-card cycle for a custom app is: write `MOTOR:START:<len>`, wait for
`MOTOR:COMPLETE`, photograph, repeat. Still unknown: what the argument's units are
(sweep 60/100 and watch how far a card travels), what the feeder says when a card
jams, and whether `MOTOR:STOP` ever replies.

An empty hopper, from the Mac app's feeder log on 2026-11-10 (firmware 0.1.5; Luke
confirmed the hopper was empty):

```
22:34:04.144 → MOTOR:START:80
22:34:04.225 ← MOTOR:CARDLEN_SET
22:34:04.764 ← MOTOR:END
```

`CSC100Feeder` ends the run on `MOTOR:END` at once, and still treats a feed with no
reply for 5 s as an empty hopper.

Words tried over the command characteristic with no reply and no motor movement
(2026-11-05, each write acknowledged at the ATT layer): `STATUS`, `FEED`, `NEXT`,
`START`, `HELP`, `VERSION`, `STOP`. Unknown input is ignored silently rather than
answered with an error, so guessing gives no feedback.

## Tools

- `Scripts/blescan.sh scan [s]` — list advertisers.
- `Scripts/blescan.sh dump ESP_OTA_GATTS [s]` — connect, enumerate, subscribe, listen.
- `Scripts/blescan.sh shell ESP_OTA_GATTS 7E8A1E11-1234-4BCD-8AEF-1234567890AB` — type
  commands, watch status notifications.
- `Scripts/blescan.sh fake` — the Mac advertises as the feeder (same name, same
  service) so the vendor app connects to it; every write the app makes is logged.
  Power the real feeder off first.

The probe has to be launched from Terminal.app: processes spawned from the Claude app
are killed or silently denied by TCC because the parent has no Bluetooth usage string.

## Open questions

- Command words for feed / start / stop / speed, and whether they need a terminator.
- What the feeder reports on a jam. (A fed card is `MOTOR:COMPLETE`; an empty hopper is `MOTOR:END`.)
- Whether the status characteristic's `read` returns the last message.
