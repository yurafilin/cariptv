import SwiftUI

/// Centered illustration, title, explanation and one action: every empty list in the app.
struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

/// Channel logo from the playlist, or the channel's initials.
struct ChannelLogo: View {
    let url: URL?
    let name: String
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().padding(4)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.22))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// A playable channel. Tap plays, touch and hold or swipe toggles the favorite.
struct ChannelRow: View {
    let item: LibraryItem

    var body: some View {
        let store = LibraryStore.shared
        let isFavorite = store.isFavorite(item)
        Button {
            AppRouter.shared.play(item)
        } label: {
            HStack(spacing: 12) {
                ChannelLogo(url: item.channel.logo, name: item.channel.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.channel.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let group = item.channel.group {
                        Text(group)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Favorite")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            favoriteButton(isFavorite)
        }
        .swipeActions(edge: .trailing) {
            favoriteButton(isFavorite)
                .tint(.accentColor)
        }
    }

    private func favoriteButton(_ isFavorite: Bool) -> some View {
        Button {
            LibraryStore.shared.toggleFavorite(item)
        } label: {
            Label(
                isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
    }
}

/// What is playing, above the tab bar; tap opens the player.
struct MiniPlayerBar: View {
    var body: some View {
        let playback = PlaybackController.shared
        if let media = playback.media {
            HStack(spacing: 12) {
                ChannelLogo(url: media.artwork, name: media.title, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(media.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(playback.state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    playback.togglePause()
                } label: {
                    Image(systemName: playback.state == .playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(playback.state == .playing ? "Pause" : "Play")
                Button {
                    playback.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Stop")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onTapGesture {
                AppRouter.shared.isPlayerPresented = true
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
    }
}

extension View {
    /// Keeps the mini player above the tab bar on every tab.
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
        }
    }
}
