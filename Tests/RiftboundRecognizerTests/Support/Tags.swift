import Testing

extension Tag {
    /// Tests that run the real Vision models; slower, and skipped on machines without them.
    @Tag static var vision: Self
}
