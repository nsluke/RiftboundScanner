import CoreGraphics
import Testing
@testable import RiftboundScannerApp

@Suite("Guide crop")
struct GuideCropTests {
    /// A 400×800 preview with a guide half its width, centred, 63:88 tall.
    private let preview = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let guide = CGRect(x: 100, y: 260, width: 200, height: 280)

    @Test func withoutMarginACentredGuideMapsToTheCentreOfTheVisiblePhoto() {
        // Photo 3:4 is wider than the 1:2 view, so the full height is visible
        // and only (0.5)/(0.75) = 2/3 of the width.
        let crop = GuideCrop(guideFrame: guide, previewFrame: preview, margin: 0)
        let unit = crop.normalizedRect(forPhotoSize: CGSize(width: 3000, height: 4000))
        #expect(abs(unit.midX - 0.5) < 1e-9)
        #expect(abs(unit.midY - 0.5) < 1e-9)
        #expect(abs(unit.width - 0.5 * (2.0 / 3.0)) < 1e-9)
        #expect(abs(unit.height - 0.35) < 1e-9)
    }

    @Test func aPhotoTallerThanTheViewClipsItsHeightInstead() {
        // Photo 1:4 is taller than the 1:2 view: full width, half the height visible.
        let crop = GuideCrop(guideFrame: guide, previewFrame: preview, margin: 0)
        let unit = crop.normalizedRect(forPhotoSize: CGSize(width: 1000, height: 4000))
        #expect(abs(unit.width - 0.5) < 1e-9)
        #expect(abs(unit.height - 0.35 * 0.5) < 1e-9)
        #expect(abs(unit.midY - 0.5) < 1e-9)
    }

    @Test func marginGrowsTheCropOnEverySide() {
        let tight = GuideCrop(guideFrame: guide, previewFrame: preview, margin: 0)
        let roomy = GuideCrop(guideFrame: guide, previewFrame: preview, margin: 0.15)
        let size = CGSize(width: 3000, height: 4000)
        let a = tight.normalizedRect(forPhotoSize: size)
        let b = roomy.normalizedRect(forPhotoSize: size)
        #expect(abs(b.width - a.width * 1.3) < 1e-9)
        #expect(abs(b.height - a.height * 1.3) < 1e-9)
        #expect(abs(b.midX - a.midX) < 1e-9)
    }

    @Test func pixelRectIsIntegralAndInsideThePhoto() {
        let crop = GuideCrop(guideFrame: guide, previewFrame: preview)
        let size = CGSize(width: 3024, height: 4032)
        let rect = crop.pixelRect(forPhotoSize: size)
        #expect(rect == rect.integral)
        #expect(CGRect(origin: .zero, size: size).contains(rect))
        #expect(rect.width > 0 && rect.height > 0)
    }

    @Test func aGuideAtTheEdgeIsClampedToTheImage() {
        let edgeGuide = CGRect(x: -50, y: -50, width: 300, height: 300)
        let crop = GuideCrop(guideFrame: edgeGuide, previewFrame: preview, margin: 0.5)
        let unit = crop.normalizedRect(forPhotoSize: CGSize(width: 1000, height: 2000))
        #expect(unit.minX == 0)
        #expect(unit.minY == 0)
        #expect(unit.maxX <= 1 && unit.maxY <= 1)
    }

    @Test func offsetPreviewFramesAreHandled() {
        let shifted = GuideCrop(guideFrame: guide.offsetBy(dx: 20, dy: 40), previewFrame: preview.offsetBy(dx: 20, dy: 40), margin: 0)
        let centred = GuideCrop(guideFrame: guide, previewFrame: preview, margin: 0)
        let size = CGSize(width: 3000, height: 4000)
        #expect(shifted.normalizedRect(forPhotoSize: size) == centred.normalizedRect(forPhotoSize: size))
    }

    @Test func degenerateInputFallsBackToTheWholePhoto() {
        let crop = GuideCrop(guideFrame: .zero, previewFrame: .zero)
        #expect(crop.normalizedRect(forPhotoSize: CGSize(width: 10, height: 10)) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

@Suite("Frame guide")
struct FrameGuideTests {
    @Test func theIPhoneAppGuideCropsWhatThePhoneCrops() {
        // The iPhone app's standard captures: a 1454 × 2030 crop at (785, 1122)
        // of a 3024 × 4032 photo. A Mac preview of any size showing the whole
        // 3:4 frame must crop the same pixels.
        for preview in [CGRect(x: 0, y: 0, width: 600, height: 800), CGRect(x: 148, y: 52, width: 471, height: 628)] {
            let crop = GuideCrop(guideFrame: FrameGuide.iPhoneApp.rect(in: preview), previewFrame: preview)
            let pixels = crop.pixelRect(forPhotoSize: CGSize(width: 3024, height: 4032))
            #expect(abs(pixels.minX - 785) <= 2)
            #expect(abs(pixels.minY - 1122) <= 2)
            #expect(abs(pixels.width - 1454) <= 2)
            #expect(abs(pixels.height - 2030) <= 2)
        }
    }

    @Test func theContinuityGuideIsACardCentredInTheUprightFrame() {
        // A 1920 × 1080 Continuity Camera frame turned upright, shown at 540 × 960.
        let frame = CGRect(x: 10, y: 20, width: 540, height: 960)
        let rect = FrameGuide.continuityStand.rect(in: frame)
        #expect(abs(rect.width / rect.height - 63.0 / 88.0) < 1e-9)
        #expect(abs(rect.midX - frame.midX) < 1e-9)
        #expect(abs(rect.midY - frame.midY) < 1e-9)
        #expect(abs(rect.width - 540 * 0.73) < 1e-9)
        #expect(frame.contains(rect))
        // With the 15 % margin the crop still fits inside the photo.
        let pixels = GuideCrop(guideFrame: rect, previewFrame: frame).pixelRect(forPhotoSize: CGSize(width: 1080, height: 1920))
        #expect(pixels.width < 1080 && pixels.width > 1000)
    }

    @Test func sizesFollowTheShorterSideAndStayInRange() {
        let landscape = CGRect(x: 0, y: 0, width: 1600, height: 900)
        #expect(abs(FrameGuide.iPhoneApp.rect(in: landscape).width - 900 * 0.3699) < 1e-9)
        #expect(FrameGuide.iPhoneApp.resized(to: 5).widthFraction == FrameGuide.widthRange.upperBound)
        #expect(FrameGuide.iPhoneApp.resized(to: 0).widthFraction == FrameGuide.widthRange.lowerBound)
        #expect(FrameGuide.iPhoneApp.resized(to: 0.5).centerYFraction == FrameGuide.iPhoneApp.centerYFraction)
        #expect(FrameGuide.iPhoneApp.rect(in: .zero) == .zero)
    }

    @Test func aWideGuideNeverRunsPastALandscapeFrame() {
        let landscape = CGRect(x: 0, y: 0, width: 1920, height: 1440)
        let rect = FrameGuide(widthFraction: 0.9).rect(in: landscape)
        #expect(rect.height <= landscape.height)
    }
}
