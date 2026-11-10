import Foundation

/// Where the feeder link is, so the screen can show exactly one of these.
nonisolated enum FeederState: Hashable, Sendable {
    /// Not connected and not looking; the user has to ask.
    case idle
    case scanning
    case connecting
    /// Subscribed and accepting commands. The version arrives a moment after
    /// readiness, from the `FWVER` reply, so it can be missing briefly or forever.
    case ready(firmwareVersion: String?)
    case feeding
    case failed(FeederFailure)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Why the feeder link is down. Each case maps to a different recovery on screen.
nonisolated enum FeederFailure: Hashable, Sendable {
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case connectionFailed(String)
    case disconnected(String?)

    var message: String {
        switch self {
        case .bluetoothOff: String(localized: "Bluetooth is off.")
        case .bluetoothUnauthorized:
            #if os(macOS)
            String(localized: "Allow Bluetooth access in System Settings to use the feeder.")
            #else
            String(localized: "Allow Bluetooth access in Settings to use the feeder.")
            #endif
        case .bluetoothUnsupported: String(localized: "This device has no Bluetooth LE.")
        case .connectionFailed(let detail): String(localized: "Couldn't connect to the feeder. \(detail)")
        case .disconnected(let detail):
            if let detail {
                String(localized: "The feeder disconnected. \(detail)")
            } else {
                String(localized: "The feeder disconnected.")
            }
        }
    }
}

/// Why a single feed did not complete.
nonisolated enum FeederError: Error, Hashable, Sendable {
    /// `feedOneCard` was called while the link was not `ready`.
    case notReady(FeederState)
    /// No `MOTOR:COMPLETE` arrived in time. The feeder says nothing when its
    /// hopper is empty, so this is also how an empty hopper shows up.
    case timedOut
    case writeFailed(String)
    case disconnected

    var message: String {
        switch self {
        case .notReady: String(localized: "The feeder isn't ready.")
        case .timedOut: String(localized: "The feeder didn't report a card. The hopper may be empty.")
        case .writeFailed(let detail): String(localized: "The feeder rejected the command. \(detail)")
        case .disconnected: String(localized: "The feeder disconnected.")
        }
    }
}

/// The card feeder as the scanner model sees it. The live implementation drives
/// the CSC100 over Bluetooth LE; tests and previews inject a stub.
///
/// Main-actor isolated like the rest of the app module: `state` is read by
/// views, and the live driver's CoreBluetooth callbacks are delivered on the
/// main queue.
protocol FeederControlling: AnyObject {
    var state: FeederState { get }
    /// Starts looking for the feeder and connects to the first one found.
    /// Reconnects on its own if the link drops.
    func connect()
    /// Advances exactly one card and returns once the feeder reports it done.
    /// Throws `FeederError.timedOut` after `timeout` without a report.
    func feedOneCard(timeout: Duration) async throws
    /// Tells the feeder to stop its motor; sent at the end of a session or on error.
    func stop()
    func disconnect()
}

extension FeederControlling {
    func feedOneCard() async throws {
        try await feedOneCard(timeout: .seconds(5))
    }
}
