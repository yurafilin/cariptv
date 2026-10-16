import SwiftUI
import UniformTypeIdentifiers

/// Picks a source type, then its form: M3U link or file, Xtream Codes, Jellyfin, Emby, Plex.
struct AddSourceView: View {
    @State private var isImportingFile = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Playlists") {
                    NavigationLink {
                        M3ULinkForm()
                    } label: {
                        SourceTypeRow(systemImage: "link", title: "M3U Link", subtitle: "A link to an .m3u or .m3u8 playlist")
                    }
                    Button {
                        isImportingFile = true
                    } label: {
                        SourceTypeRow(systemImage: "doc.text", title: "M3U File", subtitle: "Import a playlist from Files")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                    NavigationLink {
                        XtreamForm()
                    } label: {
                        SourceTypeRow(systemImage: "antenna.radiowaves.left.and.right", title: "Xtream Codes", subtitle: "Live TV, movies and series from your provider")
                    }
                }
                Section("Media Servers") {
                    NavigationLink {
                        ServerLoginForm(flavor: .jellyfin)
                    } label: {
                        SourceTypeRow(systemImage: "server.rack", title: "Jellyfin", subtitle: "Your Jellyfin server")
                    }
                    NavigationLink {
                        ServerLoginForm(flavor: .emby)
                    } label: {
                        SourceTypeRow(systemImage: "server.rack", title: "Emby", subtitle: "Your Emby server")
                    }
                    NavigationLink {
                        PlexSignInView()
                    } label: {
                        SourceTypeRow(systemImage: "play.square.stack", title: "Plex", subtitle: "Sign in with your Plex account")
                    }
                }
                Section {
                } footer: {
                    Text("CarIPTV is a player. It doesn't provide or include any channels.")
                }
            }
            .navigationTitle("Add a Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { AppRouter.shared.isAddSourcePresented = false }
                }
            }
            .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.m3uPlaylist, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                isWorking = true
                Task {
                    defer { isWorking = false }
                    do {
                        try await LibraryStore.shared.importM3U(file: url)
                        AppRouter.shared.isAddSourcePresented = false
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .errorAlert("Couldn't add the source", message: $errorMessage)
        }
    }
}

private struct SourceTypeRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Forms

/// Shared scaffolding: an Add button that runs the operation and closes the sheet on success.
private struct SourceForm<Fields: View>: View {
    let title: LocalizedStringKey
    let canAdd: Bool
    let add: () async throws -> Void
    @ViewBuilder let fields: () -> Fields

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            fields()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isWorking {
                    ProgressView()
                } else {
                    Button("Add") { run() }
                        .disabled(!canAdd)
                }
            }
        }
        .errorAlert("Couldn't add the source", message: $errorMessage)
    }

    private func run() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await add()
                AppRouter.shared.isAddSourcePresented = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct M3ULinkForm: View {
    @State private var link = ""
    @State private var name = ""
    @State private var guide = ""

    var body: some View {
        SourceForm(title: "M3U Link", canAdd: url != nil && (guide.isEmpty || guideURL != nil)) {
            guard let url else { return }
            try await LibraryStore.shared.addM3U(url: url, name: name, guideURL: guideURL)
        } fields: {
            Section {
                TextField("Playlist link", text: $link, prompt: Text(verbatim: "https://example.com/playlist.m3u"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Name (optional)", text: $name)
            } footer: {
                Text("A link to an .m3u or .m3u8 playlist from your provider.")
            }
            Section {
                TextField("TV guide link (optional)", text: $guide, prompt: Text(verbatim: "https://example.com/epg.xml.gz"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("An XMLTV guide (.xml or .xml.gz). Most playlists already include one; add it only if programmes don't show.")
            }
        }
    }

    private var url: URL? {
        Self.webURL(link)
    }

    private var guideURL: URL? {
        Self.webURL(guide)
    }

    private static func webURL(_ text: String) -> URL? {
        URL(string: text.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
    }
}

private struct XtreamForm: View {
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""

    var body: some View {
        SourceForm(title: "Xtream Codes", canAdd: !server.isEmpty && !username.isEmpty && !password.isEmpty) {
            try await LibraryStore.shared.addXtream(server: server, username: username, password: password, name: name)
        } fields: {
            CredentialFields(server: $server, username: $username, password: $password, name: $name, serverPrompt: "http://example.com:8080")
            Section {
            } footer: {
                Text("The server address, username and password from your Xtream Codes provider. Live TV, movies and series are added.")
            }
        }
    }
}

private struct ServerLoginForm: View {
    let flavor: JellyfinClient.Flavor

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""

    var body: some View {
        SourceForm(title: LocalizedStringKey(flavor.title), canAdd: !server.isEmpty && !username.isEmpty) {
            try await LibraryStore.shared.addMediaServer(flavor: flavor, server: server, username: username, password: password, name: name)
        } fields: {
            CredentialFields(server: $server, username: $username, password: $password, name: $name, serverPrompt: "http://192.168.1.10:8096")
            Section {
            } footer: {
                Text("The address you open \(flavor.title) at in a browser, and your \(flavor.title) username and password. Videos are converted by your server so they play in the car.")
            }
        }
    }
}

private struct CredentialFields: View {
    @Binding var server: String
    @Binding var username: String
    @Binding var password: String
    @Binding var name: String
    let serverPrompt: String

    var body: some View {
        Section {
            TextField("Server", text: $server, prompt: Text(verbatim: serverPrompt))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
            TextField("Name (optional)", text: $name)
        }
    }
}

/// Plex sign-in without a password in the app: the user enters a code on plex.tv/link.
private struct PlexSignInView: View {
    private enum Step {
        case starting
        case waiting(PlexClient.Pin)
        case choosing([PlexClient.Server])
        case failed(String)
    }

    @Environment(\.openURL) private var openURL
    @State private var step: Step = .starting
    @State private var attempt = 0

    var body: some View {
        List {
            switch step {
            case .starting:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .waiting(let pin):
                Section {
                    VStack(spacing: 16) {
                        Text("Go to plex.tv/link on any device and enter this code")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Text(verbatim: pin.code)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Open plex.tv/link") {
                            openURL(PlexClient.linkURL)
                        }
                        .buttonStyle(.borderedProminent)
                        ProgressView("Waiting for Plex…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            case .choosing(let servers):
                Section("Choose a server") {
                    ForEach(servers) { server in
                        Button(server.name) {
                            LibraryStore.shared.addPlex(server)
                            AppRouter.shared.isAddSourcePresented = false
                        }
                    }
                }
            case .failed(let message):
                Section {
                    Text(message)
                    Button("Try Again") { attempt += 1 }
                }
            }
        }
        .navigationTitle("Plex")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) {
            await signIn()
        }
    }

    private func signIn() async {
        step = .starting
        do {
            let pin = try await PlexClient.createPin()
            step = .waiting(pin)
            // Codes live for about 15 minutes; poll every 2 seconds for 10 of them.
            for _ in 0..<300 {
                try await Task.sleep(for: .seconds(2))
                guard let token = try await PlexClient.checkPin(pin) else { continue }
                let servers = try await PlexClient.servers(accountToken: token)
                switch servers.count {
                case 0:
                    step = .failed(String(localized: "There are no Plex servers on this account."))
                case 1:
                    LibraryStore.shared.addPlex(servers[0])
                    AppRouter.shared.isAddSourcePresented = false
                default:
                    step = .choosing(servers)
                }
                return
            }
            step = .failed(String(localized: "The code has expired."))
        } catch is CancellationError {
            return
        } catch {
            step = .failed(error.localizedDescription)
        }
    }
}

extension View {
    /// Alert bound to an optional message: shown while the message is set.
    func errorAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
