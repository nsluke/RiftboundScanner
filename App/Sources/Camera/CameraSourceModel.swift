import Foundation
import RiftboundRecognizer

/// Reports the cameras that are connected, now and after every change.
nonisolated protocol CameraDiscovering: Sendable {
    /// Yields the connected cameras at once and again whenever one connects
    /// or disconnects, until the consumer stops listening.
    func devices() -> AsyncStream<[CameraDevice]>
}

/// A camera engine that can photograph through more than one device.
nonisolated protocol CameraSwitching: Sendable {
    /// Opens `device` for the next `start()`, replacing the camera in use.
    /// Returns the size of the frames it delivers, before any rotation, or
    /// `nil` when it cannot be opened; `start()` then reports why.
    func use(_ device: CameraDevice.ID) async -> PixelSize?
    /// Turns every later photo by `rotation`, matching the preview.
    func setRotation(_ rotation: CameraRotation) async
}

/// The camera picker's memory: the camera chosen last, and for each camera
/// how its picture is turned and how large its card guide is.
nonisolated struct CameraPreferences: Hashable, Sendable, Codable {
    var cameraID: CameraDevice.ID?
    /// Keyed by `CameraDevice.ID.rawValue`.
    var rotations: [String: CameraRotation] = [:]
    /// The guide's width over the frame's shorter side, keyed like `rotations`.
    var guideWidths: [String: Double] = [:]

    init(cameraID: CameraDevice.ID? = nil, rotations: [String: CameraRotation] = [:], guideWidths: [String: Double] = [:]) {
        self.cameraID = cameraID
        self.rotations = rotations
        self.guideWidths = guideWidths
    }

    /// Every key is optional, so preferences saved before a key existed still load.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cameraID = try container.decodeIfPresent(CameraDevice.ID.self, forKey: .cameraID)
        rotations = try container.decodeIfPresent([String: CameraRotation].self, forKey: .rotations) ?? [:]
        guideWidths = try container.decodeIfPresent([String: Double].self, forKey: .guideWidths) ?? [:]
    }

    /// The saved turn, else a quarter-turn for an iPhone through Continuity
    /// Camera: it delivers the sensor's landscape frames however the phone
    /// sits, and a quarter-turn clockwise is what the iPhone app applies to
    /// its own back camera to stand the card upright.
    func rotation(for device: CameraDevice) -> CameraRotation {
        rotations[device.id.rawValue] ?? (device.kind == .continuity ? .clockwise90 : .none)
    }

    /// The saved guide size, else the standard guide for the kind of camera.
    func guide(for device: CameraDevice) -> FrameGuide {
        let standard = FrameGuide.standard(for: device.kind)
        return guideWidths[device.id.rawValue].map(standard.resized(to:)) ?? standard
    }
}

nonisolated protocol CameraPreferenceStoring: Sendable {
    func load() async -> CameraPreferences
    func save(_ preferences: CameraPreferences) async
}

actor DefaultsCameraPreferenceStore: CameraPreferenceStoring {
    static let key = "scanner.cameraPreferences"

    private let defaults: UserDefaults

    /// `UserDefaults` is thread-safe but not `Sendable`; the instance is
    /// handed over and owned by this actor from then on.
    init(defaults: sending UserDefaults) {
        self.defaults = defaults
    }

    func load() -> CameraPreferences {
        guard let data = defaults.data(forKey: Self.key) else { return CameraPreferences() }
        return (try? JSONDecoder().decode(CameraPreferences.self, from: data)) ?? CameraPreferences()
    }

    func save(_ preferences: CameraPreferences) {
        // Two optional fields and a string map: encoding cannot fail.
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Which camera the Mac scanner photographs through, how its picture is
/// turned and where its card guide sits. It follows cameras as they connect and disconnect, prefers the
/// iPhone, remembers the user's pick, and points the engine at the chosen
/// camera before announcing it, so the scanner's next `start()` opens the
/// right device. The scanner reacts to `source`; see
/// `ScannerModel.follow(_:)`.
@Observable
final class CameraSourceModel {
    /// Every connected camera, in discovery order; what the picker lists.
    private(set) var devices: [CameraDevice] = []
    private(set) var source: CameraSource = .searching
    /// How the camera in use is turned; the preview reads it, the engine has it.
    private(set) var rotation: CameraRotation = .none
    /// Where the card guide sits in the camera in use's frame.
    private(set) var guide: FrameGuide = .iPhoneApp
    /// The frames the camera in use delivers, before rotation; `nil` until it opens.
    private(set) var frameSize: PixelSize?

    private let discovery: any CameraDiscovering
    private let camera: any CameraSwitching
    private let preferences: any CameraPreferenceStoring
    private var saved = CameraPreferences()
    private var hasLoadedPreferences = false

    init(discovery: any CameraDiscovering, camera: any CameraSwitching, preferences: any CameraPreferenceStoring) {
        self.discovery = discovery
        self.camera = camera
        self.preferences = preferences
    }

    /// The camera in use or waited for, for the picker's selection.
    var selectedID: CameraDevice.ID? { source.device?.id }

    /// The size the preview should take: the frame turned by the rotation.
    var displayAspectRatio: CGFloat? {
        guard let frameSize, frameSize.width > 0, frameSize.height > 0 else { return nil }
        let turned = rotation.turning(frameSize.cgSize)
        return turned.width / turned.height
    }

    /// Follows the connected cameras until the task is cancelled. Run it
    /// from the scanner screen's `.task`.
    func run() async {
        await loadPreferencesIfNeeded()
        for await connected in discovery.devices() {
            await apply(connected)
        }
    }

    /// Uses `id` from now on and remembers it as the camera to prefer.
    func choose(_ id: CameraDevice.ID) async {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        await loadPreferencesIfNeeded()
        saved.cameraID = id
        await preferences.save(saved)
        await switchTo(device)
        source = .using(device)
    }

    /// Turns the camera in use a further quarter-turn clockwise and remembers it for that camera.
    func rotateClockwise() async {
        guard let device = source.device else { return }
        let turned = rotation.turnedClockwise
        rotation = turned
        saved.rotations[device.id.rawValue] = turned
        await preferences.save(saved)
        await camera.setRotation(turned)
    }

    /// Resizes the card guide, so it can be fitted to where the card really
    /// sits on the stand; the next capture crops to it. Called as the slider
    /// moves; `rememberGuide()` keeps the size once it settles.
    func resizeGuide(to widthFraction: Double) {
        guide = guide.resized(to: widthFraction)
    }

    /// Remembers the guide's current size for the camera in use.
    func rememberGuide() async {
        guard let device = source.device else { return }
        saved.guideWidths[device.id.rawValue] = guide.widthFraction
        await preferences.save(saved)
    }

    private func apply(_ connected: [CameraDevice]) async {
        devices = connected
        let next = CameraSelection.source(after: source, devices: connected, saved: saved.cameraID)
        if case .using(let device) = next, !isUsing(device) {
            await switchTo(device)
        }
        // The iPhone app is remembered once used, picked or not: someone
        // opened Camera for Mac on purpose, and the next launch waits for it
        // rather than taking that phone through Continuity Camera.
        if case .using(let device) = next, device.kind == .iPhoneApp, saved.cameraID != device.id {
            saved.cameraID = device.id
            await preferences.save(saved)
        }
        source = next
    }

    /// Opens `device` in the engine with its remembered rotation. Done before
    /// `source` changes, because the scanner restarts the camera on that change.
    private func switchTo(_ device: CameraDevice) async {
        let turned = saved.rotation(for: device)
        await camera.setRotation(turned)
        frameSize = await camera.use(device.id)
        rotation = turned
        guide = saved.guide(for: device)
    }

    private func isUsing(_ device: CameraDevice) -> Bool {
        if case .using(let current) = source { return current.id == device.id }
        return false
    }

    private func loadPreferencesIfNeeded() async {
        guard !hasLoadedPreferences else { return }
        saved = await preferences.load()
        hasLoadedPreferences = true
    }
}
