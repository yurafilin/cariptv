import AVKit
import SwiftUI

/// Full-screen player on the phone. The same player feeds the car display.
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    /// AVKit pauses when its view goes away; playback should go on for the car display.
    @State private var resumeAfterClose = false

    var body: some View {
        let playback = PlaybackController.shared
        let car = CarState.shared
        NavigationStack {
            VStack(spacing: 0) {
                VideoPlayer(player: playback.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(.black)

                List {
                    if let media = playback.media {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(media.title)
                                    .font(.title3.weight(.semibold))
                                if let subtitle = media.subtitle {
                                    Text(subtitle)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            LabeledContent("Status", value: playback.state.message)
                            LabeledContent("Car display", value: carText(car))
                        }

                        Section {
                            if let item = media.libraryItem {
                                let isFavorite = LibraryStore.shared.isFavorite(item)
                                Button {
                                    LibraryStore.shared.toggleFavorite(item)
                                } label: {
                                    Label(
                                        isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                        systemImage: isFavorite ? "heart.fill" : "heart"
                                    )
                                }
                            }
                            Button(role: .destructive) {
                                playback.stop()
                                dismiss()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        resumeAfterClose = playback.state == .playing
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "chevron.down")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onDisappear {
            if resumeAfterClose {
                playback.resume()
            }
        }
    }

    private func carText(_ car: CarState) -> String {
        guard car.isConnected else { return String(localized: "Not connected") }
        return car.videoAvailability == .allowed
            ? String(localized: "Showing on the car display")
            : car.videoAvailability.message
    }
}
