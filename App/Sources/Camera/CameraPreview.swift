import AVFoundation
import SwiftUI
import UIKit

/// Live viewfinder. The preview layer reads the session; the engine owns it.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // The connection exists only once the session has an input; the app is
        // portrait-only, so a fixed angle is correct.
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90), connection.videoRotationAngle != 90 {
            connection.videoRotationAngle = 90
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Guaranteed by `layerClass`; UIKit creates the backing layer of that class.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
