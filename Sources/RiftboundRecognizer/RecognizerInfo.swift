import Foundation

/// Facts about this build of the recogniser that travel with its results.
public enum RecognizerInfo {
    /// The package's own version, independent of any app that embeds it. Bump
    /// it whenever recognition behaviour changes (scoring, OCR repair, the
    /// canvas, the descriptors), so that analyses recorded by two builds can
    /// be told apart.
    public static let version = "0.2.0"

    /// The operating system family this process runs on, as recorded on
    /// engine fingerprints: feature prints computed on different platforms
    /// are not assumed to be comparable until measured.
    public static var platform: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(visionOS)
        "visionOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(watchOS)
        "watchOS"
        #else
        "unknown"
        #endif
    }

    /// The running operating system's version, `major.minor.patch`.
    public static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

/// Which recogniser produced a result: the package build, the embedding the
/// device's Vision model yields for the procedural ``CalibrationCanvas``, and
/// the platform it ran on. Two fingerprints with the same `calibrationHash`
/// computed feature prints in the same space, so their descriptors and any
/// learned exemplars are directly comparable.
public struct EngineFingerprint: Hashable, Sendable, Codable {
    public let packageVersion: String
    /// The 16-byte digest of this device's calibration print.
    public let calibrationHash: FeaturePrint.Digest
    public let platform: String
    public let osVersion: String

    public init(packageVersion: String, calibrationHash: FeaturePrint.Digest, platform: String, osVersion: String) {
        self.packageVersion = packageVersion
        self.calibrationHash = calibrationHash
        self.platform = platform
        self.osVersion = osVersion
    }

    /// This build on this operating system, with a calibration hash that was
    /// computed already.
    public static func current(calibrationHash: FeaturePrint.Digest) -> EngineFingerprint {
        EngineFingerprint(
            packageVersion: RecognizerInfo.version,
            calibrationHash: calibrationHash,
            platform: RecognizerInfo.platform,
            osVersion: RecognizerInfo.osVersion
        )
    }

    /// Calibrates `featurePrinter` against the ``CalibrationCanvas`` and
    /// fingerprints this build on this operating system with the result.
    public static func current(calibrating featurePrinter: any FeaturePrintGenerating) async throws -> EngineFingerprint {
        current(calibrationHash: try await featurePrinter.calibrationPrint().digest)
    }
}
