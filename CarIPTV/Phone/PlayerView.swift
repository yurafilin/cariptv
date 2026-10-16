import AVKit
import SwiftUI

/// Full-screen player on the phone. The same player feeds the car display.
/// Turning the phone sideways switches to a full-screen layout with large controls.
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    /// AVKit pauses when its view goes away; playback should go on for the car display.
    @State private var resumeAfterClose = false
    @State private var guide: (now: Programme?, next: Programme?) = (nil, nil)

    var body: some View {
        let playback = PlaybackController.shared
        GeometryReader { proxy in
            if proxy.size.width > proxy.size.height {
                landscape(playback)
            } else {
                portrait(playback)
            }
        }
        .task(id: playback.media?.libraryItem?.id) {
            await loadGuide(playback.media?.libraryItem)
        }
        .onAppear {
            OrientationLock.allowLandscape(true)
        }
        .onDisappear {
            OrientationLock.allowLandscape(false)
            if resumeAfterClose {
                playback.resume()
            }
        }
    }

    // MARK: - Portrait

    private func portrait(_ playback: PlaybackController) -> some View {
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
                            if let now = guide.now {
                                LabeledContent("Now", value: "\(now.title) · until \(now.end.formatted(date: .omitted, time: .shortened))")
                            }
                            if let next = guide.next {
                                LabeledContent("Next", value: "\(next.start.formatted(date: .omitted, time: .shortened)) \(next.title)")
                            }
                            LabeledContent("Status", value: playback.state.message)
                            LabeledContent("Car display", value: carText)
                        }

                        if playback.canStep {
                            Section {
                                HStack {
                                    stepButton("Previous", systemImage: "backward.end.fill", offset: -1)
                                    Spacer()
                                    stepButton("Next", systemImage: "forward.end.fill", offset: 1)
                                }
                                .buttonStyle(.borderless)
                            } footer: {
                                Text("Turn your phone sideways for full screen.")
                            }
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
                    closeButton(playback)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Landscape ("car mode")

    private func landscape(_ playback: PlaybackController) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: playback.player)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 12) {
                closeButton(playback)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                if let media = playback.media {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(media.title)
                            .font(.headline)
                        if let now = guide.now {
                            Text(now.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding()
        }
        .overlay {
            if playback.canStep {
                HStack {
                    bigStepButton(systemImage: "backward.end.fill", label: "Previous", offset: -1)
                    Spacer()
                    bigStepButton(systemImage: "forward.end.fill", label: "Next", offset: 1)
                }
                .padding(.horizontal, 24)
            }
        }
        .statusBarHidden()
    }

    // MARK: - Controls

    private func closeButton(_ playback: PlaybackController) -> some View {
        Button {
            resumeAfterClose = playback.state == .playing
            dismiss()
        } label: {
            Label("Close", systemImage: "chevron.down")
        }
    }

    private func stepButton(_ title: LocalizedStringKey, systemImage: String, offset: Int) -> some View {
        Button {
            PlaybackController.shared.step(offset)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func bigStepButton(systemImage: String, label: LocalizedStringKey, offset: Int) -> some View {
        Button {
            PlaybackController.shared.step(offset)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 76, height: 76)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var carText: String {
        let car = CarState.shared
        guard car.isConnected else { return String(localized: "Not connected") }
        return car.videoAvailability == .allowed
            ? String(localized: "Showing on the car display")
            : car.videoAvailability.message
    }

    private func loadGuide(_ item: LibraryItem?) async {
        guide = (nil, nil)
        guard let item, let lookup = LibraryStore.shared.guideLookup(for: item) else { return }
        guide = await ProgramGuide.shared.nowNext(lookup)
    }
}
