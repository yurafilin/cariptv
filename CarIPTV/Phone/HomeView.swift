import SwiftUI

struct HomeView: View {
    @State private var picker = BroadcastPicker()
    #if DEBUG
    @State private var testPattern = TestPatternSource()
    @State private var isTestPatternOn = false
    #endif

    private var car: CarState { .shared }
    private var mirror: MirrorStatus { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusRow(
                        title: "CarPlay",
                        value: car.isConnected ? String(localized: "Connected") : String(localized: "Not connected"),
                        isOK: car.isConnected
                    )
                    StatusRow(
                        title: "Video in car",
                        value: car.videoAvailability.message,
                        isOK: car.videoAvailability == .allowed
                    )
                    StatusRow(
                        title: "Mirroring",
                        value: mirrorText,
                        isOK: mirror.state == .streaming
                    )
                }

                Section {
                    Button {
                        picker.present()
                    } label: {
                        Label("Start screen mirroring", systemImage: "rectangle.on.rectangle")
                    }
                    .background(alignment: .leading) {
                        BroadcastPickerHost(picker: picker)
                            .frame(width: 1, height: 1)
                            .opacity(0.01)
                            .accessibilityHidden(true)
                    }
                } footer: {
                    Text("Everything on your iPhone screen appears on the car display. Video shows only while the car is parked.")
                }

                #if DEBUG
                Section("Debug") {
                    Toggle("Test pattern", isOn: $isTestPatternOn)
                        .onChange(of: isTestPatternOn) { _, isOn in
                            isOn ? testPattern.start() : testPattern.stop()
                        }
                    MirrorPreview(orientation: mirror.orientation)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                }
                #endif
            }
            .navigationTitle("CarIPTV")
        }
    }

    private var mirrorText: String {
        switch mirror.state {
        case .stopped:
            return String(localized: "Not ready")
        case .listening:
            return String(localized: "Waiting for the screen")
        case .streaming:
            // Built outside the localized string: Int interpolation there adds grouping ("1 280").
            let size = "\(Int(mirror.videoSize.width))×\(Int(mirror.videoSize.height))"
            return String(localized: "On · \(mirror.framesPerSecond) fps · \(size)")
        }
    }
}

private struct StatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let isOK: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                Image(systemName: isOK ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOK ? .green : .secondary)
            }
        }
    }
}

#Preview {
    HomeView()
}
