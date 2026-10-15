import CoreMedia
import ReplayKit

/// Broadcast upload extension: captures the iPhone screen and relays it to the app,
/// which shows it on the CarPlay display.
final class SampleHandler: RPBroadcastSampleHandler {
    private let streamer = ScreenStreamer()
    private var orientation: UInt8 = 1

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        Log.relay.info("broadcast: started")
        streamer.start { [weak self] failure in
            self?.finish(after: failure)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Audio is not relayed: the source app already plays through the car speakers.
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let value = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
            orientation = value.uint8Value
        }
        streamer.submit(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), orientation: orientation)
    }

    override func broadcastPaused() {
        Log.relay.info("broadcast: paused")
    }

    override func broadcastResumed() {
        Log.relay.info("broadcast: resumed")
    }

    override func broadcastFinished() {
        Log.relay.info("broadcast: finished")
        streamer.stop()
    }

    private func finish(after failure: RelayClient.Failure) {
        let message: String
        switch failure {
        case .appUnavailable:
            message = String(localized: "Open CarIPTV on the car screen, then start mirroring again.")
        case .disconnected:
            message = String(localized: "CarIPTV stopped receiving the screen. Start mirroring again.")
        }
        Log.relay.error("broadcast: finishing \(message)")
        streamer.stop()
        finishBroadcastWithError(NSError(domain: "weappico.cariptv", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
