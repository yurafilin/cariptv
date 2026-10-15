import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// "Choose Files" and "From Photos" rows: copy videos into the app.
struct LocalVideoImportRows: View {
    @State private var isImportingFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            isImportingFiles = true
        } label: {
            Label("Choose Files", systemImage: "folder")
        }
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                do {
                    for url in urls {
                        try LibraryStore.shared.importVideo(from: url)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }

        PhotosPicker(selection: $photoItem, matching: .videos, photoLibrary: .shared()) {
            HStack {
                Label("From Photos", systemImage: "photo.on.rectangle")
                if isWorking {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isWorking)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            importFromPhotos(item)
        }
        .alert("Couldn't add the video", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importFromPhotos(_ item: PhotosPickerItem) {
        isWorking = true
        Task {
            defer {
                isWorking = false
                photoItem = nil
            }
            do {
                guard let video = try await item.loadTransferable(type: ImportedVideo.self) else { return }
                let title = String(localized: "Video \(Date.now.formatted(date: .abbreviated, time: .shortened))")
                try LibraryStore.shared.importVideo(from: video.url, title: title, moving: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A video handed over by the Photos picker as a temporary file.
struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedVideo(url: destination)
        }
    }
}
