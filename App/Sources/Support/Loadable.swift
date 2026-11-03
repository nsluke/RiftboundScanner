/// The states of something fetched asynchronously, so a screen cannot be both
/// loading and failed, or loaded with nothing to show.
enum Loadable<Value, Failure: Error> {
    case idle
    case loading
    case loaded(Value)
    case failed(Failure)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
