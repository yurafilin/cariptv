import ReplayKit
import SwiftUI

/// Opens the system broadcast sheet with ScreenRelay preselected. ReplayKit has no API to open it
/// from a custom button, so the system picker view stays hidden and its button is tapped for the user.
@MainActor
final class BroadcastPicker {
    fileprivate let pickerView: RPSystemBroadcastPickerView = {
        let view = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.preferredExtension = (Bundle.main.bundleIdentifier ?? "weappico.cariptv") + ".ScreenRelay"
        view.showsMicrophoneButton = false
        return view
    }()

    func present() {
        pickerView.subviews
            .compactMap { $0 as? UIButton }
            .first?
            .sendActions(for: .touchUpInside)
    }
}

/// Puts the hidden system picker into the view hierarchy; it must be in a window to present.
struct BroadcastPickerHost: UIViewRepresentable {
    let picker: BroadcastPicker

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        picker.pickerView
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
