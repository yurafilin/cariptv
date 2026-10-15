import AVFoundation
import ImageIO
import UIKit

/// Shows the mirrored stream: rotated by the ReplayKit orientation, letterboxed to fit.
/// Receives frames only while `isReceiving` and in a window.
final class MirrorDisplayView: UIView {
    private final class VideoLayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    private let videoView = VideoLayerView()
    private var isAttached = false

    var orientation = CGImagePropertyOrientation.up {
        didSet {
            if oldValue != orientation { setNeedsLayout() }
        }
    }

    var isReceiving = false {
        didSet { updateAttachment() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        videoView.displayLayer.videoGravity = .resizeAspect
        addSubview(videoView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAttachment()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let quarterTurn: Bool
        let angle: CGFloat
        switch orientation {
        case .right, .rightMirrored:
            quarterTurn = true
            angle = .pi / 2
        case .left, .leftMirrored:
            quarterTurn = true
            angle = -.pi / 2
        case .down, .downMirrored:
            quarterTurn = false
            angle = .pi
        default:
            quarterTurn = false
            angle = 0
        }
        videoView.transform = .identity
        videoView.bounds = CGRect(
            origin: .zero,
            size: quarterTurn ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        )
        videoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        videoView.transform = CGAffineTransform(rotationAngle: angle)
    }

    private func updateAttachment() {
        let shouldAttach = isReceiving && window != nil
        guard shouldAttach != isAttached else { return }
        isAttached = shouldAttach
        let renderer = videoView.displayLayer.sampleBufferRenderer
        if shouldAttach {
            MirrorReceiver.shared.renderer.attach(renderer)
        } else {
            MirrorReceiver.shared.renderer.detach(renderer)
        }
    }
}
