import AVFoundation
import SwiftUI

#if os(iOS)
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
#elseif os(macOS)
import AppKit

/// Live viewfinder in a Mac window, turned by `rotation` so it matches the
/// photos (`CaptureEngine` turns those by the same amount). The view is laid
/// out at the turned frame's aspect ratio, so `.resizeAspectFill` shows the
/// whole frame and `GuideCrop` maps it to the photo exactly as on the iPhone.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var rotation: CameraRotation = .none

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.rotation = rotation
    }

    /// Hosts the preview layer and rotates it about its centre. A turned layer
    /// is sized with width and height swapped so it covers the view once turned.
    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var rotation: CameraRotation = .none {
            didSet { if rotation != oldValue { needsLayout = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            let root = CALayer()
            root.backgroundColor = NSColor.black.cgColor
            root.addSublayer(previewLayer)
            // Layer-hosting: the view owns this layer tree and lays it out itself.
            layer = root
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.bounds = CGRect(origin: .zero, size: rotation.turning(bounds.size))
            previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            // Layer geometry is y-up here, so a clockwise turn is a negative angle.
            previewLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(rotation.degrees) * .pi / 180))
            // The Mac mirrors a built-in camera's preview by default; the photo
            // is never mirrored, and the guide crop needs the two to agree.
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            CATransaction.commit()
        }
    }
}
#endif
