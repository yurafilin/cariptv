import SwiftUI
import WebKit

/// Web browser with suggested video sites and the user's saved ones. A video that starts playing
/// on a page can be handed to our player, and through it to the car display.
struct BrowserView: View {
    @State private var address = ""
    @State private var isAddingSite = false
    @State private var isShowingInfo = false
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        let model = BrowserModel.shared
        ZStack {
            // The page runs to the bottom edge, as in Safari; the video bar, when shown, sits above it.
            WebView(webView: model.webView)
                .ignoresSafeArea(.container, edges: model.video == nil ? .bottom : [])
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
        // Site → start page → Home: one level per tap. Without the system button the left-edge
        // swipe goes to the page's own history.
        .navigationBarBackButtonHidden(!model.isShowingHome)
        .toolbar {
            if !model.isShowingHome {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.isShowingHome = true
                    } label: {
                        Label("Start Page", systemImage: "chevron.backward")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingInfo = true
                } label: {
                    Label("How it works", systemImage: "info.circle")
                }
                .popover(isPresented: $isShowingInfo) {
                    Text("Start a video on a site, then tap \(Image(systemName: "play.rectangle.fill")) Watch in Car.")
                        .font(.subheadline)
                        .padding()
                        .frame(idealWidth: 280)
                        .fixedSize(horizontal: false, vertical: true)
                        .presentationCompactAdaptation(.popover)
                }
            }
            if !model.isShowingHome {
                ToolbarItem(placement: .topBarTrailing) {
                    pageMenu(model)
                }
            }
        }
        // A site gets the whole screen: no bar of ours under it, only Watch in Car once a video is
        // found. The address field lives on the start page.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isShowingHome {
                addressField(model)
            } else if let video = model.video {
                videoBar(video, model)
            }
        }
        .sheet(isPresented: $isAddingSite) {
            AddSiteSheet()
        }
        // Back on the start page the field is for a new site, not the last one.
        .onChange(of: model.isShowingHome) { _, isShowingHome in
            if isShowingHome {
                address = ""
            }
        }
    }

    /// One grid: adding a site comes first, then the suggested sites, then the user's own in the order added.
    private func home(_ model: BrowserModel) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 16) {
                addSiteTile
                ForEach(BrowserModel.suggestedSites) { site in
                    siteTile(site, removable: false)
                }
                ForEach(model.bookmarks) { site in
                    siteTile(site, removable: true)
                }
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }

    private var addSiteTile: some View {
        Button {
            isAddingSite = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 60, height: 60)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: SiteIcon.corner, style: .continuous))
                Text("Add Site")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    /// The user's own sites can be removed by touching and holding; the suggested ones cannot.
    private func siteTile(_ site: Bookmark, removable: Bool) -> some View {
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

    private func videoBar(_ video: WebVideo, _ model: BrowserModel) -> some View {
        Button {
            Task { await model.playVideo() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: video.canPlay ? "play.rectangle.fill" : "lock.rectangle")
                    .font(.title2)
                    .foregroundStyle(video.canPlay ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.canPlay ? "Watch in Car" : "This video can't go to the car")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(video.canPlay ? video.title : String(localized: "The site plays it only inside the page."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if video.canPlay {
                    Image(systemName: "chevron.forward")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: video.canPlay)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!video.canPlay)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// Search or a website, on the start page only: a floating glass capsule with no bar behind it.
    private func addressField(_ model: BrowserModel) -> some View {
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
            .padding(.horizontal, 18)
            .frame(height: Self.controlSize)
            .glassSurface(in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
    }

    /// Page actions, in the top bar so the site keeps the whole screen. The previous page of the
    /// site is also a swipe from the left edge.
    private func pageMenu(_ model: BrowserModel) -> some View {
        Menu {
            if model.canGoBack {
                Button {
                    model.goBack()
                } label: {
                    Label("Previous Page", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                model.reload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            Button {
                model.toggleBookmark()
            } label: {
                Label(
                    model.isCurrentPageBookmarked ? "Remove from Start Page" : "Add to Start Page",
                    systemImage: model.isCurrentPageBookmarked ? "bookmark.slash" : "bookmark"
                )
            }
            Button {
                model.isShowingHome = true
            } label: {
                Label("Start Page", systemImage: "square.grid.2x2")
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    /// The address capsule: above the 44 pt minimum, the size of Safari's.
    private static let controlSize: CGFloat = 48
}

/// Adds a site of the user's own to the start page.
private struct AddSiteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        let url = BrowserModel.siteURL(from: address)
        NavigationStack {
            Form {
                Section {
                    TextField("Website", text: $address, prompt: Text(verbatim: "example.com"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isAddressFocused)
                        .onSubmit { add(url) }
                    TextField("Name (optional)", text: $name)
                }
            }
            .navigationTitle("Add Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Active only for a real address: a search phrase is not a site.
                    Button("Add") { add(url) }
                        .disabled(url == nil)
                }
            }
            .onAppear { isAddressFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func add(_ url: URL?) {
        guard let url else { return }
        BrowserModel.shared.addBookmark(url: url, title: name)
        dismiss()
    }
}

/// The site's icon (favicon service), or its first letter.
private struct SiteIcon: View {
    let url: URL
    let title: String

    /// The tile's corner and the icon's inset; the icon's own corner follows them (outer − inset),
    /// so the two curves run parallel instead of a sharp square inside a rounded one.
    static let corner: CGFloat = 14
    private static let inset: CGFloat = 10

    var body: some View {
        AsyncImage(url: iconURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Self.corner - Self.inset, style: .continuous))
                    .padding(Self.inset)
            } else {
                Text(String(title.prefix(1)))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
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
