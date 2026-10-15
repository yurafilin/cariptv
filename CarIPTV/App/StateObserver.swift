import Observation

/// Re-runs `apply` whenever an `@Observable` property it read changes.
/// For UIKit and CarPlay code, which does not track observation on its own like SwiftUI views do.
/// Stops when the observer is released or cancelled.
@MainActor
final class StateObserver {
    private let apply: @MainActor () -> Void
    private var isCancelled = false

    init(_ apply: @escaping @MainActor () -> Void) {
        self.apply = apply
        track()
    }

    func cancel() {
        isCancelled = true
    }

    private func track() {
        guard !isCancelled else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }
}
