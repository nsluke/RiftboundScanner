import Foundation

/// A status message from the CSC100 feeder. The wire format is plain ASCII with
/// no terminator; anything this app does not recognise is kept verbatim so the
/// screen and the logs can still show it.
nonisolated enum FeederMessage: Hashable, Sendable {
    /// Sent once, right after the status characteristic is subscribed.
    case connected
    /// The reply to `FWVER`, e.g. `0.1.5`.
    case firmwareVersion(String)
    /// The immediate acknowledgement of `MOTOR:START:<length>`.
    case cardLengthSet
    /// One card has been advanced.
    case feedComplete
    /// The motor ran without a card coming through: the hopper is empty.
    /// Seen with firmware 0.1.5 on 10 Nov 2026, half a second after
    /// `MOTOR:CARDLEN_SET`, on a feed into an empty hopper.
    case feedEndedEmpty
    case unrecognized(String)

    init(parsing text: String) {
        switch text {
        case "CONNECTED": self = .connected
        case "MOTOR:CARDLEN_SET": self = .cardLengthSet
        case "MOTOR:COMPLETE": self = .feedComplete
        case "MOTOR:END": self = .feedEndedEmpty
        default:
            if text.hasPrefix("FWVER:") {
                self = .firmwareVersion(String(text.dropFirst("FWVER:".count)))
            } else {
                self = .unrecognized(text)
            }
        }
    }

    /// Decodes the raw characteristic value. Bytes that are not ASCII become an
    /// unrecognised message holding their hex form rather than a crash or a drop.
    init(parsing data: Data) {
        if let text = String(data: data, encoding: .ascii) {
            self.init(parsing: text)
        } else {
            self = .unrecognized(data.map { String(format: "%02x", $0) }.joined())
        }
    }
}

/// A command the app writes to the feeder. `OTA:` is deliberately absent: it
/// starts a firmware update and must never be sent by this app.
nonisolated enum FeederCommand: Hashable, Sendable {
    case firmwareVersion
    /// Advances one card. The vendor app always sends `80`; the units are unknown.
    case feed(cardLength: Int)
    case stop

    static let defaultCardLength = 80

    var text: String {
        switch self {
        case .firmwareVersion: "FWVER"
        case .feed(let cardLength): "MOTOR:START:\(cardLength)"
        case .stop: "MOTOR:STOP"
        }
    }

    var data: Data { Data(text.utf8) }
}
