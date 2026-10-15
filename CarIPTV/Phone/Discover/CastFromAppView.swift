import SwiftUI

/// Receives videos from apps with a Cast (DLNA) button, plus local videos to send to the car.
struct CastFromAppView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var installedApps: [CastingApp] = []

    var body: some View {
        let receiver = CastReceiver.shared
        List {
            Section {
                VStack(spacing: 14) {
                    receiverIllustration(receiver)
                    Text(statusText(receiver))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if case .needsWiFi = receiver.status {
                        Button("Try Again") { receiver.restart() }
                    } else if case .failed = receiver.status {
                        Button("Try Again") { receiver.restart() }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                if installedApps.isEmpty {
                    Text("Open any app with a Cast or TV button, choose “\(receiver.friendlyName)” and the video plays on the car display.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installedApps) { app in
                        Button {
                            openURL(app.url)
                        } label: {
                            Label(app.name, systemImage: "arrow.up.forward.app")
                        }
                    }
                }
            } header: {
                Text("Media Apps")
            } footer: {
                Text("Works with apps that support DLNA / UPnP casting. Your iPhone must be on Wi-Fi. Some apps limit quality or restrict certain videos when casting.")
            }

            Section("Local Videos") {
                LocalVideoImportRows()
            }
        }
        .navigationTitle("Cast from an App")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            receiver.setActive(true, for: .castScreen)
            installedApps = CastingApp.installed()
        }
        .onDisappear {
            receiver.setActive(false, for: .castScreen)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, receiver.status == .needsWiFi {
                receiver.restart()
            }
        }
        .miniPlayerInset()
    }

    private func receiverIllustration(_ receiver: CastReceiver) -> some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.secondary, lineWidth: 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                .frame(width: 220, height: 130)
                .overlay {
                    Text(receiver.friendlyName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            Capsule()
                .fill(.secondary)
                .frame(width: 90, height: 5)
        }
    }

    private func statusText(_ receiver: CastReceiver) -> String {
        switch receiver.status {
        case .running:
            if let title = receiver.lastCastTitle, PlaybackController.shared.isActive {
                return String(localized: "Playing “\(title)”")
            }
            return String(localized: "Waiting for an app to cast…")
        case .needsWiFi:
            return String(localized: "Connect your iPhone to Wi-Fi to receive casts.")
        case .failed(let message):
            return String(localized: "Casting isn't available: \(message)")
        case .stopped:
            return String(localized: "Starting…")
        }
    }
}

/// Apps known to cast over DLNA, detected through their URL schemes.
struct CastingApp: Identifiable {
    let name: String
    let scheme: String

    var id: String { scheme }
    var url: URL { URL(string: "\(scheme)://")! }

    static let known: [CastingApp] = [
        CastingApp(name: "TikTok", scheme: "snssdk1233"),
        CastingApp(name: "Douyin", scheme: "snssdk1128"),
        CastingApp(name: "Bilibili", scheme: "bilibili"),
        CastingApp(name: "iQIYI", scheme: "iqiyi"),
        CastingApp(name: "Youku", scheme: "youku"),
        CastingApp(name: "Tencent Video", scheme: "tenvideo"),
        CastingApp(name: "Mango TV", scheme: "imgotv"),
        CastingApp(name: "Kuaishou", scheme: "kwai"),
    ]

    /// Schemes must also be listed in `LSApplicationQueriesSchemes`.
    @MainActor
    static func installed() -> [CastingApp] {
        known.filter { UIApplication.shared.canOpenURL($0.url) }
    }
}
