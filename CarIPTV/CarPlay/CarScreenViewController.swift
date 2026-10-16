import UIKit

/// Root of the CarPlay window, when CarPlay gives us one: the mirrored iPhone screen, or why
/// there is no picture. Channels and films do not go through this window: the system presents
/// their video from our `AVPlayer` (see `CarPlaySceneDelegate`).
final class CarScreenViewController: UIViewController {
    private let mirrorView = MirrorDisplayView()
    private let message = UILabel()
    private var observer: StateObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        mirrorView.frame = view.bounds
        mirrorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mirrorView)

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
        let allowed = CarState.shared.mirroringAvailable
        let showsMirror = allowed && mirror.state == .streaming

        mirrorView.isReceiving = allowed
        mirrorView.orientation = mirror.orientation
        mirrorView.isHidden = !showsMirror

        message.isHidden = showsMirror
        message.text = allowed
            ? String(localized: "Start screen mirroring on your iPhone")
            : availability.message
    }
}
