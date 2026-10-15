import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for low latency: real-time mode, no B-frames,
/// frames scaled down so the long side is at most `maxLongSide`.
final class VideoEncoder {
    struct Output {
        /// SPS and PPS; present on keyframes.
        var parameterSets: [Data]?
        var frame: MirrorProtocol.Frame
    }

    var onOutput: ((Output) -> Void)?

    private let maxLongSide: Int
    private let frameRate: Int
    private let bitRate: Int

    private var session: VTCompressionSession?
    private var sessionSize: (width: Int, height: Int) = (0, 0)
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int) = (0, 0)

    private let keyframeLock = NSLock()
    private var keyframeRequested = true

    init(maxLongSide: Int = 1280, frameRate: Int = 30, bitRate: Int = 4_000_000) {
        self.maxLongSide = maxLongSide
        self.frameRate = frameRate
        self.bitRate = bitRate
    }

    deinit {
        invalidate()
    }

    /// Thread-safe: may be called from the network queue.
    func requestKeyframe() {
        keyframeLock.withLock { keyframeRequested = true }
    }

    /// Call from one serial context (the ReplayKit sample queue or the test pattern timer).
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, orientation: UInt8) {
        guard let source = scaledIfNeeded(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if session == nil || sessionSize != (width, height) {
            makeSession(width: width, height: height)
        }
        guard let session else { return }

        let forceKeyframe = keyframeLock.withLock { () -> Bool in
            defer { keyframeRequested = false }
            return keyframeRequested
        }
        let properties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: source,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                Log.relay.error("encoder: frame failed status=\(status)")
                return
            }
            self?.emit(sampleBuffer, orientation: orientation)
        }
        if status != noErr {
            Log.relay.error("encoder: encode call failed status=\(status)")
            requestKeyframe()
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        if let transfer {
            VTPixelTransferSessionInvalidate(transfer)
        }
        transfer = nil
        pool = nil
    }

    // MARK: - Session

    private func makeSession(width: Int, height: Int) {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil

        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            Log.relay.error("encoder: session create failed status=\(status)")
            return
        }

        let set = { (key: CFString, value: CFTypeRef) in
            let status = VTSessionSetProperty(newSession, key: key, value: value)
            if status != noErr {
                Log.relay.error("encoder: property \(key as String) failed status=\(status)")
            }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (frameRate * 2) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber)
        // Hard cap at 1.5× the average over one second, in bytes.
        set(kVTCompressionPropertyKey_DataRateLimits, [bitRate * 3 / 16, 1] as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(newSession)
        session = newSession
        sessionSize = (width, height)
        requestKeyframe()
        Log.relay.info("encoder: session \(width)x\(height) @\(self.frameRate)fps \(self.bitRate / 1000)kbps")
    }

    // MARK: - Output

    private func emit(_ sampleBuffer: CMSampleBuffer, orientation: UInt8) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: length)
        let copyStatus = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        let isKeyframe = Self.isKeyframe(sampleBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : 0
        let frame = MirrorProtocol.Frame(isKeyframe: isKeyframe, orientation: orientation, ptsMicroseconds: micros, data: data)
        let parameterSets = isKeyframe ? Self.parameterSets(of: sampleBuffer) : nil
        onOutput?(Output(parameterSets: parameterSets, frame: frame))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func parameterSets(of sampleBuffer: CMSampleBuffer) -> [Data]? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }

    // MARK: - Scaling

    private func scaledIfNeeded(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let target = Self.targetSize(width: width, height: height, maxLongSide: maxLongSide)
        if target == (width, height) {
            return pixelBuffer
        }

        if transfer == nil {
            var newTransfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &newTransfer)
            transfer = newTransfer
        }
        if pool == nil || poolSize != target {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: target.width,
                kCVPixelBufferHeightKey: target.height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = target
        }
        guard let transfer, let pool else { return nil }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output,
              VTPixelTransferSessionTransferImage(transfer, from: pixelBuffer, to: output) == noErr
        else { return nil }
        return output
    }

    private static func targetSize(width: Int, height: Int, maxLongSide: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard longSide > maxLongSide else { return (width & ~1, height & ~1) }
        let scale = Double(maxLongSide) / Double(longSide)
        return (Int(Double(width) * scale) & ~1, Int(Double(height) * scale) & ~1)
    }
}
