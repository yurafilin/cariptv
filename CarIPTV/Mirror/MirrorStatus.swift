import CoreGraphics
import ImageIO
import Observation

/// What the phone UI and the car screen show about the incoming stream.
@MainActor @Observable
final class MirrorStatus {
    static let shared = MirrorStatus()

    enum State: Equatable {
        case stopped
        /// Waiting for the broadcast extension to connect.
        case listening
        case streaming
    }

    fileprivate(set) var state: State = .stopped
    fileprivate(set) var framesPerSecond = 0
    fileprivate(set) var videoSize = CGSize.zero
    fileprivate(set) var orientation = CGImagePropertyOrientation.up

    private init() {}
}

extension MirrorStatus {
    /// Updates from the receiver queue land on the main actor.
    nonisolated static func publish(_ update: @escaping @MainActor (MirrorStatus) -> Void) {
        Task { @MainActor in update(.shared) }
    }

    func set(state: State) { self.state = state }
    func set(framesPerSecond: Int) { self.framesPerSecond = framesPerSecond }
    func set(videoSize: CGSize) { self.videoSize = videoSize }
    func set(orientation: CGImagePropertyOrientation) { self.orientation = orientation }
}
