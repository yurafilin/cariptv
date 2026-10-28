import Foundation

/// Plays the mirrored screen in our player: the car shows video only from it.
/// Starts by itself once the stream has its first seconds and the car can show video;
/// the car's Screen tab starts it too.
@MainActor
enum ScreenPlayback {
    /// The screen being mirrored, once it can be played.
    private(set) static var stream: MirrorStream?

    static var isPlaying: Bool {
        PlaybackController.shared.media?.isScreen == true
    }

    static func ready(_ stream: MirrorStream) {
        self.stream = stream
        if CarState.shared.videoAvailability == .allowed {
            play()
        }
    }

    /// The car connected while the screen was already mirrored.
    static func carConnected() {
        guard stream != nil, !isPlaying, CarState.shared.videoAvailability == .allowed else { return }
        play()
    }

    static func ended(_ stream: MirrorStream) {
        guard self.stream === stream else { return }
        self.stream = nil
        if isPlaying {
            PlaybackController.shared.stop()
        }
        LocalHLSServer.shared.remove(stream)
    }

    static func play() {
        guard let stream else { return }
        Task {
            do {
                let url = try await LocalHLSServer.shared.url(for: stream)
                guard self.stream === stream else { return }
                Log.mirror.info("stream: playing for the car")
                PlaybackController.shared.play(PlayableMedia(
                    title: String(localized: "iPhone Screen"), url: url, isLive: true, isScreen: true
                ))
            } catch {
                Log.mirror.error("stream: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
