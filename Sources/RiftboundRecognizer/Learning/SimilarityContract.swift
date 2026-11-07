import Foundation

/// How the admission gate measures similarity, on both sides of the wire
/// (ADR-002, section 7). The gate exists twice, as this Swift struct and as a
/// Python port on the server, and the two must reach the same decision on the
/// same inputs; the shared fixture (`Tests/Fixtures/admission-cases.json`)
/// pins that, and this contract is what makes it achievable:
///
/// 1. Inputs are the Float32 elements a ``FeaturePrint`` stores (never
///    re-normalised; the bytes are the contract).
/// 2. The dot product is accumulated in Float64, element by element in order.
///    Python: `math.sumprod(array('f', a), array('f', b))`.
/// 3. Every similarity is rounded to ``decimals`` places before any
///    comparison, as `round_half_even(x * 10_000) / 10_000` with an IEEE double
///    multiply: in Swift ``round(_:)``, in Python `round(x * 10000) / 10000`.
///    (Python's `round(x, 4)` rounds the exact binary value and can disagree
///    with the multiply-then-round form at decimal halves, so the port must use
///    the multiply form.)
/// 4. Similarities that arrive as inputs (reference similarities computed on
///    the phone) go through the same rounding before they are compared.
///
/// Rounding to four decimals also means a value within 0.00005 of a threshold
/// lands on it: the fixture carries vectors at each threshold ± 0.00005 so a
/// port that compares unrounded values fails the suite.
public enum SimilarityContract {
    public static let decimals = 4
    private static let scale = 10_000.0

    /// Cosine similarity of two prints under the contract: Float64
    /// accumulation, clamped to 0...1, rounded to ``decimals`` places. Prints of
    /// different dimension are 0 (they live in different spaces).
    public static func similarity(_ a: FeaturePrint, _ b: FeaturePrint) -> Double {
        guard !a.elements.isEmpty, a.elements.count == b.elements.count else { return 0 }
        var sum = 0.0
        for index in a.elements.indices {
            sum += Double(a.elements[index]) * Double(b.elements[index])
        }
        return round(min(max(sum, 0), 1))
    }

    /// The contract's rounding: half to even on the scaled value.
    public static func round(_ value: Double) -> Double {
        (value * scale).rounded(.toNearestOrEven) / scale
    }
}
