import UIKit

/// Root of the CarPlay window: the mirrored iPhone screen, or the reason it is not shown.
/// Frames reach the view only while the car allows video.
final class CarMirrorViewController: UIViewController {
    private let display = MirrorDisplayView()
    private let message = UILabel()
    private var observer: StateObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        display.frame = view.bounds
        display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(display)

        message.textColor = .white
        message.textAlignment = .center
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .title3)
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])

        observer = StateObserver { [weak self] in
            self?.apply()
        }
    }

    private func apply() {
        let availability = CarState.shared.videoAvailability
        let mirror = MirrorStatus.shared
        let allowed = availability == .allowed
        let streaming = allowed && mirror.state == .streaming

        display.isReceiving = allowed
        display.orientation = mirror.orientation
        display.isHidden = !streaming
        message.isHidden = streaming
        message.text = allowed
            ? String(localized: "Start screen mirroring on your iPhone")
            : availability.message
    }
}
