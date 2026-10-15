#if DEBUG
import ImageIO
import SwiftUI

/// Debug: what the car display receives, shown on the phone.
struct MirrorPreview: UIViewRepresentable {
    let orientation: CGImagePropertyOrientation

    func makeUIView(context: Context) -> MirrorDisplayView {
        let view = MirrorDisplayView()
        view.isReceiving = true
        return view
    }

    func updateUIView(_ view: MirrorDisplayView, context: Context) {
        view.orientation = orientation
    }
}
#endif
