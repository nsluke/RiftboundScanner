import SwiftUI

/// The camera menu on the Mac: every connected camera with the one in use
/// checked, plus the one being waited for when it has dropped off. Choosing a
/// camera uses it at once and remembers it for the next launch.
struct CameraPicker: View {
    let source: CameraSourceModel

    var body: some View {
        Picker(selection: selection) {
            if source.selectedID == nil {
                Text(source.devices.isEmpty ? "No cameras" : "Choose a camera").tag(CameraDevice.ID?.none)
            }
            ForEach(source.devices) { device in
                Label(device.name, systemImage: device.kind.systemImage)
                    .tag(Optional(device.id))
            }
            if case .lost(let device) = source.source {
                Label("\(device.name) (disconnected)", systemImage: "iphone.slash")
                    .tag(Optional(device.id))
            }
        } label: {
            Label("Camera", systemImage: "camera")
        }
        .pickerStyle(.menu)
        // A toolbar shows icons alone by default; the camera's name is the point.
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .accessibilityLabel("Camera")
        .accessibilityValue(source.source.device?.name ?? String(localized: "none"))
        .help("Choose the camera that photographs the cards")
    }

    private var selection: Binding<CameraDevice.ID?> {
        Binding(
            get: { source.selectedID },
            set: { id in
                guard let id else { return }
                Task { await source.choose(id) }
            }
        )
    }
}

extension CameraDevice.Kind {
    var systemImage: String {
        switch self {
        case .iPhoneApp: "iphone.gen3.radiowaves.left.and.right"
        case .continuity: "iphone"
        case .external: "web.camera"
        case .builtIn: "laptopcomputer"
        }
    }
}
