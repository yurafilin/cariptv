import SwiftUI
import WebKit

/// Web browser with suggested video sites and the user's saved ones. The page reaches the car
/// display through screen mirroring.
struct BrowserView: View {
    @State private var address = ""
    @State private var picker = BroadcastPicker()
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        let model = BrowserModel.shared
        ZStack {
            WebView(webView: model.webView)
                .opacity(model.isShowingHome ? 0 : 1)
            if model.isShowingHome {
                home(model)
            }
        }
        .overlay(alignment: .top) {
            if model.isLoading, !model.isShowingHome {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }
        }
        .navigationTitle(model.isShowingHome ? String(localized: "Browser") : (model.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            bottomBar(model)
        }
        .background {
            BroadcastPickerHost(picker: picker)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
        .onChange(of: model.url) { _, url in
            if !isAddressFocused {
                address = url?.absoluteString ?? ""
            }
        }
    }

    private func home(_ model: BrowserModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !model.bookmarks.isEmpty {
                    siteGrid(title: "Saved", sites: model.bookmarks, removable: true)
                }
                siteGrid(title: "Suggested", sites: BrowserModel.suggestedSites, removable: false)
                Text("Open a site, then tap \(Image(systemName: "rectangle.on.rectangle")) to show it on the car display.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private func siteGrid(title: LocalizedStringKey, sites: [Bookmark], removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 16) {
                ForEach(sites) { site in
                    Button {
                        BrowserModel.shared.open(site.url)
                    } label: {
                        VStack(spacing: 6) {
                            SiteIcon(url: site.url, title: site.title)
                            Text(site.title)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if removable {
                            Button(role: .destructive) {
                                BrowserModel.shared.remove(site)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func bottomBar(_ model: BrowserModel) -> some View {
        HStack(spacing: 10) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
            }
            .disabled(model.isShowingHome)
            .accessibilityLabel("Back")

            TextField("Search or enter website", text: $address)
                .textFieldStyle(.plain)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($isAddressFocused)
                .onSubmit {
                    model.open(address)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.quaternary, in: Capsule())

            Menu {
                Button {
                    model.isShowingHome = true
                } label: {
                    Label("Start Page", systemImage: "square.grid.2x2")
                }
                if !model.isShowingHome {
                    Button {
                        model.toggleBookmark()
                    } label: {
                        Label(
                            model.isCurrentPageBookmarked ? "Remove from Saved" : "Save Site",
                            systemImage: model.isCurrentPageBookmarked ? "bookmark.slash" : "bookmark"
                        )
                    }
                    Button {
                        model.reload()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    picker.present()
                } label: {
                    Label("Show on Car Display", systemImage: "rectangle.on.rectangle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The site's icon (favicon service), or its first letter.
private struct SiteIcon: View {
    let url: URL
    let title: String

    var body: some View {
        AsyncImage(url: iconURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().padding(10)
            } else {
                Text(String(title.prefix(1)))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var iconURL: URL? {
        guard let host = url.host() else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128")
    }
}

private struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
