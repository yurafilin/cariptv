import UIKit

/// Root of the CarPlay window. Shows, in order of priority: the playing channel or video,
/// the mirrored iPhone screen, or why there is no picture. Video reaches the window only
/// while the car allows it; otherwise the player keeps going as audio.
final class CarScreenViewController: UIViewController {
    private let playerView = PlayerLayerView()
    private let mirrorView = MirrorDisplayView()
    private let message = UILabel()
    private var observer: StateObserver?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        for content in [playerView, mirrorView] as [UIView] {
            content.frame = view.bounds
            content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(content)
        }

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
        let playback = PlaybackController.shared
        let mirror = MirrorStatus.shared
        let allowed = availability == .allowed
        let showsPlayer = allowed && playback.isActive
        let showsMirror = allowed && !showsPlayer && mirror.state == .streaming

        playerView.player = showsPlayer ? playback.player : nil
        playerView.isHidden = !showsPlayer

        mirrorView.isReceiving = allowed && !showsPlayer
        mirrorView.orientation = mirror.orientation
        mirrorView.isHidden = !showsMirror

        message.isHidden = showsPlayer || showsMirror
        message.text = allowed
            ? String(localized: "Choose a channel on your iPhone or start screen mirroring")
            : availability.message
    }
}
