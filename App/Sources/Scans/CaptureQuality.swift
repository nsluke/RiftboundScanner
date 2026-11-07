import RiftboundRecognizer

/// Whether a photo was taken the way the learning loop expects: cropped to
/// the viewfinder guide at the full sensor resolution, which gives a
/// card-shaped image about 1454 x 2030 pixels. Anything else (the pre-crop
/// batches, a whole-frame 1536 x 2048 photo, a guide that was still the wrong
/// shape) is `legacy`: it may still be judged and ledgered, but it never
/// becomes an exemplar (ADR-002, decision 6 and section 7 rule 4).
nonisolated enum CaptureQuality: String, Hashable, Sendable, Codable, CaseIterable {
    case standard
    case legacy

    /// The long edge a guide crop produces at full resolution, within tolerance.
    static let standardLongEdge = 1800...2200
    /// How far the photo's aspect may sit from the card's 63 : 88.
    static let aspectTolerance = 0.03

    /// A pure function of how the photo was taken and how big it came out.
    init(crop: CropDebug?, photoSize: PixelSize) {
        guard crop != nil, Self.isStandardSize(photoSize) else {
            self = .legacy
            return
        }
        self = .standard
    }

    /// Portrait, card-shaped and at guide-crop resolution.
    static func isStandardSize(_ size: PixelSize) -> Bool {
        guard size.width > 0, size.height > 0, size.height >= size.width else { return false }
        guard standardLongEdge.contains(size.height) else { return false }
        let cardAspect = 63.0 / 88.0
        let aspect = Double(size.width) / Double(size.height)
        return abs(aspect - cardAspect) / cardAspect <= aspectTolerance
    }
}
