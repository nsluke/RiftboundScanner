import CoreGraphics

/// Maps the viewfinder guide, measured on screen, onto the captured photo so
/// the recogniser sees the card and not the feeder around it.
///
/// The preview layer fills its view with `.resizeAspectFill`, so the photo is
/// scaled until it covers the view and the overflow on one axis is clipped:
/// when the photo is wider than the view (w/h > W/H) its full height shows
/// and only a (W/H)/(w/h) fraction of its width; otherwise the full width
/// shows and a (w/h)/(W/H) fraction of its height. The visible part is centred,
/// so a point at view fraction v maps to photo fraction 0.5 + (v − 0.5)·visible.
nonisolated struct GuideCrop: Hashable, Sendable {
    /// The guide's frame and the preview view's frame in one coordinate space.
    let guideFrame: CGRect
    let previewFrame: CGRect
    /// Extra room on every side, as a fraction of the guide's size, so a card
    /// that is slightly off the guide keeps its edges.
    let margin: CGFloat

    init(guideFrame: CGRect, previewFrame: CGRect, margin: CGFloat = 0.15) {
        self.guideFrame = guideFrame
        self.previewFrame = previewFrame
        self.margin = margin
    }

    /// The guide as a rectangle in unit photo coordinates, clamped to the image.
    func normalizedRect(forPhotoSize photoSize: CGSize) -> CGRect {
        guard previewFrame.width > 0, previewFrame.height > 0, photoSize.width > 0, photoSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let viewAspect = previewFrame.width / previewFrame.height
        let photoAspect = photoSize.width / photoSize.height
        let visibleWidth = photoAspect > viewAspect ? viewAspect / photoAspect : 1
        let visibleHeight = photoAspect > viewAspect ? 1 : photoAspect / viewAspect

        // The guide in unit view coordinates, grown by the margin.
        let grown = guideFrame.insetBy(dx: -guideFrame.width * margin, dy: -guideFrame.height * margin)
        let viewMinX = (grown.minX - previewFrame.minX) / previewFrame.width
        let viewMaxX = (grown.maxX - previewFrame.minX) / previewFrame.width
        let viewMinY = (grown.minY - previewFrame.minY) / previewFrame.height
        let viewMaxY = (grown.maxY - previewFrame.minY) / previewFrame.height

        let minX = (0.5 + (viewMinX - 0.5) * visibleWidth).clamped(to: 0...1)
        let maxX = (0.5 + (viewMaxX - 0.5) * visibleWidth).clamped(to: 0...1)
        let minY = (0.5 + (viewMinY - 0.5) * visibleHeight).clamped(to: 0...1)
        let maxY = (0.5 + (viewMaxY - 0.5) * visibleHeight).clamped(to: 0...1)
        guard maxX > minX, maxY > minY else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The crop in pixels of a photo of `photoSize`, integral and inside the image.
    func pixelRect(forPhotoSize photoSize: CGSize) -> CGRect {
        let unit = normalizedRect(forPhotoSize: photoSize)
        let rect = CGRect(
            x: unit.minX * photoSize.width,
            y: unit.minY * photoSize.height,
            width: unit.width * photoSize.width,
            height: unit.height * photoSize.height
        ).integral
        return rect.intersection(CGRect(origin: .zero, size: photoSize))
    }
}

/// The card guide for a viewfinder that shows the camera's whole frame, as
/// the Mac's does: a 63:88 card outline, centred horizontally, sized as a
/// fraction of the frame's shorter side. The iPhone lays its guide out on
/// screen instead, 100 pt in from each side of a full-screen preview; a Mac
/// window has no fixed shape, so the guide is placed in the frame.
nonisolated struct FrameGuide: Hashable, Sendable {
    static let cardAspectRatio: CGFloat = 63.0 / 88.0
    /// The sizes the guide can be set to, as a fraction of the shorter side.
    static let widthRange: ClosedRange<Double> = 0.25...0.9

    /// The card's width over the frame's shorter side.
    let widthFraction: Double
    /// How far down the frame the card's centre sits.
    let centerYFraction: Double

    init(widthFraction: Double, centerYFraction: Double = 0.5) {
        self.widthFraction = widthFraction.clamped(to: Self.widthRange)
        self.centerYFraction = centerYFraction
    }

    /// Where the iPhone app's guide lands in its own photos. Its standard
    /// captures crop 1454 × 2030 px at (785, 1122) of a 3024 × 4032 photo,
    /// which is the guide grown by `GuideCrop`'s 15 % margin: a card 37 % as
    /// wide as the photo (1454 / 1.3 / 3024), its centre 53 % of the way down
    /// ((1122 + 2030 / 2) / 4032). Right for a camera that sees what the
    /// iPhone app's dual-wide camera sees.
    static let iPhoneApp = FrameGuide(widthFraction: 0.3699, centerYFraction: 0.53)

    /// An iPhone on the feeder's stand through Continuity Camera, turned
    /// upright. Continuity Camera films 1920 × 1080 through the main wide
    /// lens, which sees the card larger than the app's ultra-wide does: in
    /// Luke's first Mac run (10 Nov 2026) the card was about 1100 × 790 px,
    /// 73 % of the frame's short side, and centred. An estimate from one run;
    /// the guide-size control corrects it per camera.
    static let continuityStand = FrameGuide(widthFraction: 0.73, centerYFraction: 0.5)

    /// The starting guide for a kind of camera, before the user resizes it.
    static func standard(for kind: CameraDevice.Kind) -> FrameGuide {
        kind == .continuity ? .continuityStand : .iPhoneApp
    }

    /// The same guide at another size.
    func resized(to widthFraction: Double) -> FrameGuide {
        FrameGuide(widthFraction: widthFraction, centerYFraction: centerYFraction)
    }

    /// The guide inside `frame`, the rectangle the camera's whole frame fills.
    func rect(in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let width = Swift.min(frame.width, frame.height) * widthFraction
        let height = Swift.min(width / Self.cardAspectRatio, frame.height)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.minY + frame.height * centerYFraction - height / 2,
            width: width,
            height: height
        )
    }
}

nonisolated private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

nonisolated private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
