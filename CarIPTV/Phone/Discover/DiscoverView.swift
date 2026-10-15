import SwiftUI

struct DiscoverView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        BrowserView()
                    } label: {
                        DiscoverRow(systemImage: "safari", title: "Browser", subtitle: "Browse websites and save your favorites")
                    }
                }
                Section {
                    NavigationLink {
                        CastToScreenView()
                    } label: {
                        DiscoverRow(systemImage: "rectangle.on.rectangle", title: "Cast to Screen", subtitle: "Mirror your iPhone screen")
                    }
                    NavigationLink {
                        CastFromAppView()
                    } label: {
                        DiscoverRow(systemImage: "arrow.up.forward.app", title: "Cast from an App", subtitle: "Apps with a built-in Cast button")
                    }
                }
            }
            .navigationTitle("Discover")
            .miniPlayerInset()
        }
    }
}

private struct DiscoverRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}
