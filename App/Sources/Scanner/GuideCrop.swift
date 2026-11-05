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

nonisolated private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
