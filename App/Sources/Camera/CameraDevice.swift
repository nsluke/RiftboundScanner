import Foundation

/// A camera the scanner could photograph through. On the Mac that is an
/// iPhone over Continuity Camera, a USB camera or the Mac's own camera; the
/// iPhone app only ever uses its back camera and never lists devices.
nonisolated struct CameraDevice: Hashable, Sendable, Identifiable {
    /// AVFoundation's `uniqueID`, which stays the same when the same iPhone
    /// drops off and comes back.
    struct ID: RawRepresentable, Hashable, Sendable, Codable {
        let rawValue: String
    }

    /// What kind of camera it is, in the order the scanner prefers them.
    enum Kind: Int, Hashable, Sendable, Comparable {
        /// An iPhone through Continuity Camera: the camera on the feeder's stand.
        case continuity
        /// A USB or other external camera.
        case external
        /// The Mac's own camera, which cannot see the feeder.
        case builtIn

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: ID
    let name: String
    let kind: Kind
    let hasTorch: Bool

    init(id: ID, name: String, kind: Kind, hasTorch: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.hasTorch = hasTorch
    }
}

/// Which camera the scanner is using as cameras come and go.
nonisolated enum CameraSource: Hashable, Sendable {
    /// Discovery has not reported yet.
    case searching
    /// No camera is connected at all.
    case none
    /// This camera is connected and is the one to photograph through.
    case using(CameraDevice)
    /// The camera in use went away: the iPhone moved, locked out of Continuity
    /// Camera or lost its link. The scanner waits for it instead of switching
    /// to another camera that cannot see the feeder.
    case lost(CameraDevice)

    /// The camera being used or waited for.
    var device: CameraDevice? {
        switch self {
        case .searching, .none: nil
        case .using(let device), .lost(let device): device
        }
    }
}

/// The rules for picking a camera, kept pure so they can be tested without
/// AVFoundation.
nonisolated enum CameraSelection {
    /// The camera to use when the choice is open: the saved one while it is
    /// connected, otherwise the first iPhone, then an external camera, then
    /// the built-in one. Ties keep discovery order.
    static func preferred(among devices: [CameraDevice], saved: CameraDevice.ID?) -> CameraDevice? {
        if let saved, let device = devices.first(where: { $0.id == saved }) {
            return device
        }
        return devices.enumerated()
            .min { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }?
            .element
    }

    /// Where `current` goes when the connected cameras become `devices`.
    ///
    /// - A camera in use that disconnects becomes `lost`, never a silent
    ///   switch: the next photo would come from a camera aimed elsewhere.
    /// - A lost camera that reconnects is used again; until then it stays lost.
    /// - A camera the user did not save gives way when the saved camera
    ///   appears, or when a more preferred kind does (an iPhone that joins
    ///   after launch replaces the built-in camera picked in the meantime).
    static func source(after current: CameraSource, devices: [CameraDevice], saved: CameraDevice.ID?) -> CameraSource {
        switch current {
        case .searching, .none:
            return preferred(among: devices, saved: saved).map(CameraSource.using) ?? .none
        case .using(let inUse):
            guard let connected = devices.first(where: { $0.id == inUse.id }) else {
                return .lost(inUse)
            }
            guard inUse.id != saved, let best = preferred(among: devices, saved: saved), best.id != inUse.id else {
                return .using(connected)
            }
            return best.id == saved || best.kind < inUse.kind ? .using(best) : .using(connected)
        case .lost(let missing):
            return devices.first(where: { $0.id == missing.id }).map(CameraSource.using) ?? .lost(missing)
        }
    }
}
