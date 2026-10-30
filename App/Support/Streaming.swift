import Domain

/// A value that is still being read from its first observation.
enum Loadable<Value> {
    case loading
    case loaded(Value)

    var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }

    var isLoaded: Bool {
        if case .loaded = self { true } else { false }
    }
}

extension Loadable: Sendable where Value: Sendable {}
extension Loadable: Equatable where Value: Equatable {}

extension AsyncThrowingStream where Failure == any Error, Element: Sendable {
    /// Delivers each value to `body` on the main actor until the stream ends or the surrounding task is cancelled.
    /// A failure of the stream goes to `onFailure`; cancellation is not a failure.
    @MainActor
    func forEachValue(
        onFailure: @MainActor (any Error) -> Void,
        _ body: @MainActor (Element) -> Void
    ) async {
        do {
            for try await value in self {
                body(value)
            }
        } catch is CancellationError {
            return
        } catch {
            onFailure(error)
        }
    }
}
