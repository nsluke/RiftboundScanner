/// Prior knowledge about the card being identified, supplied opt-in by the
/// caller: a sealed box holds cards of one set, say.
///
/// Hints bias the ranking and restrain the OCR repairs; they never veto what
/// the card plainly says. A cleanly read code in another set still counts.
public struct RecognitionHints: Hashable, Sendable, Codable {
    /// The set the card is expected to belong to. Candidates in it receive
    /// ``ScoringPolicy/expectedSetBonus``, and the code parser refuses to
    /// *repair* a reading into any other set (a literal, index-known reading of
    /// another set is still accepted).
    public var expectedSet: SetCode?

    public init(expectedSet: SetCode? = nil) {
        self.expectedSet = expectedSet
    }

    /// No prior knowledge.
    public static let none = RecognitionHints()
}
