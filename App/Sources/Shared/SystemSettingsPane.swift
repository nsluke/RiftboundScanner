import Foundation
#if os(iOS)
import UIKit
#endif

/// Where to send the user to grant a permission the app was refused. The
/// iPhone opens the app's own page in Settings, which lists every permission;
/// the Mac opens the matching Privacy & Security pane of System Settings.
enum SystemSettingsPane: Hashable {
    case camera
    case bluetooth

    var url: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        switch self {
        case .camera: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        case .bluetooth: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        }
        #endif
    }

    /// The button that opens it, named the way each platform names its settings app.
    static var openButtonTitle: String {
        #if os(iOS)
        String(localized: "Open Settings")
        #else
        String(localized: "Open System Settings")
        #endif
    }
}
