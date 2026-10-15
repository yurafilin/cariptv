import SwiftUI
import UniformTypeIdentifiers

/// Adds an M3U link, an M3U file or an Xtream Codes account.
struct AddSourceView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case m3uLink
        case m3uFile
        case xtream

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .m3uLink: "M3U link"
            case .m3uFile: "M3U file"
            case .xtream: "Xtream"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .m3uLink
    @State private var name = ""
    @State private var link = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source type", selection: $kind) {
                        ForEach(Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch kind {
                case .m3uLink:
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
                case .m3uFile:
                    Section {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Choose a File", systemImage: "folder")
                        }
                    } footer: {
                        Text("Import an .m3u or .m3u8 file from Files.")
                    }
                case .xtream:
                    Section {
                        TextField("Server", text: $server, prompt: Text(verbatim: "http://example.com:8080"))
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
                    } footer: {
                        Text("The server address, username and password from your Xtream Codes provider. Live channels are added.")
                    }
                }

                Section {
                } footer: {
                    Text("CarIPTV is a player. It doesn't provide or include any channels.")
                }
            }
            .navigationTitle("Add a Source")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if kind != .m3uFile {
                    ToolbarItem(placement: .confirmationAction) {
                        if isWorking {
                            ProgressView()
                        } else {
                            Button("Add") { add() }
                                .disabled(!canAdd)
                        }
                    }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.m3uPlaylist, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                run { try await LibraryStore.shared.importM3U(file: url) }
            }
            .alert("Couldn't add the source", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var canAdd: Bool {
        switch kind {
        case .m3uLink: URL(string: link.trimmingCharacters(in: .whitespaces))?.scheme != nil
        case .m3uFile: false
        case .xtream: !server.isEmpty && !username.isEmpty && !password.isEmpty
        }
    }

    private func add() {
        switch kind {
        case .m3uLink:
            guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
            run { try await LibraryStore.shared.addM3U(url: url, name: name) }
        case .xtream:
            run { try await LibraryStore.shared.addXtream(server: server, username: username, password: password, name: name) }
        case .m3uFile:
            break
        }
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await operation()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
