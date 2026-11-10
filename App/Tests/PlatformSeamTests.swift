import Foundation
import Testing
@testable import RiftboundScannerApp
#if os(iOS)
import UIKit
#endif

/// The places where the iPhone and the Mac apps knowingly differ.
@Suite("Platform seams")
struct PlatformSeamTests {
    @Test func permissionButtonsOpenThePlatformsSettings() {
        #if os(macOS)
        #expect(SystemSettingsPane.camera.url?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        #expect(SystemSettingsPane.bluetooth.url?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        #expect(SystemSettingsPane.openButtonTitle == "Open System Settings")
        #else
        #expect(SystemSettingsPane.camera.url?.absoluteString == UIApplication.openSettingsURLString)
        #expect(SystemSettingsPane.bluetooth.url == SystemSettingsPane.camera.url, "the iPhone's app page lists both permissions")
        #expect(SystemSettingsPane.openButtonTitle == "Open Settings")
        #endif
    }

    @Test func messagesNameThePlatformsOwnHardwareAndSettings() {
        #if os(macOS)
        #expect(CameraError.noCamera.message.contains("Mac"))
        #expect(FeederFailure.bluetoothUnauthorized.message.contains("System Settings"))
        #else
        #expect(CameraError.noCamera.message.contains("back camera"))
        #expect(!FeederFailure.bluetoothUnauthorized.message.contains("System Settings"))
        #endif
    }

    @Test func scansLiveUnderDocuments() {
        // On the Mac `Documents` is the sandbox container's, so scans never
        // land in the user's own Documents folder.
        #expect(AppPaths.scans == URL.documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory))
        #if os(macOS)
        #expect(AppPaths.scans.path().contains("/Library/Containers/com.nsluke.RiftboundScannerMac/"))
        #endif
    }

    @Test func aCameraLostMidRunExplainsWhyFeedingStopped() {
        #expect(ScannerModel.AutoScanEnd.cameraDisconnected("Luke's iPhone Camera").message == "Luke's iPhone Camera disconnected, so feeding stopped.")
    }

    @Test func reviewOpensTheGridOnTheMacAndTheQueueOnTheIPhone() {
        let batch = Fixtures.batch()
        #if os(macOS)
        #expect(ReviewRoute.review(batch) == .triage(batch))
        #else
        #expect(ReviewRoute.review(batch) == .queue(batch))
        #endif
    }
}
