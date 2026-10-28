import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for low latency: real-time mode, no B-frames, a keyframe at least
/// every `keyframeInterval`. Every frame goes out upright (`.up`) on one 16:9 picture `maxLongSide`
/// wide, the shape of a car display: ReplayKit keeps a turned screen in portrait pixels and only
/// reports the orientation, and the car shows the pixels as they are. Black bars around the content
/// (a 16:9 film on the wider iPhone screen) are cut off, so the content fills the car display; and
/// turning the phone keeps the picture size, so the stream for the car goes on without a new part.
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
    private var rotation: VTPixelRotationSession?
    private var rotatedPool: CVPixelBufferPool?
    private var rotatedPoolSize: (width: Int, height: Int) = (0, 0)
    private let canvasSize: (width: Int, height: Int)
    private var canvasTransfer: VTPixelTransferSession?
    private var canvasPool: CVPixelBufferPool?
    /// The content of the upright frame, without black bars; `nil` for the whole frame.
    private(set) var crop: CGRect?
    /// A smaller crop seen once; taken when the next look sees it again.
    private var cropCandidate: CGRect?
    private var cropFrameSize = CGSize.zero
    private var lastCropCheck = -Double.infinity
    /// The finished frame, for `repeatLastFrame`.
    private var lastFrame: CVPixelBuffer?

    private let keyframeLock = NSLock()
    private var keyframeRequested = true

    /// Seconds between keyframes at most.
    static let keyframeInterval = 0.5
    /// Seconds between looks for black bars.
    private static let cropCheckInterval = 0.5

    init(maxLongSide: Int = 1280, frameRate: Int = 30, bitRate: Int = 4_000_000) {
        self.maxLongSide = maxLongSide
        self.frameRate = frameRate
        self.bitRate = bitRate
        canvasSize = (maxLongSide & ~1, (maxLongSide * 9 / 16) & ~1)
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
        guard let scaled = scaledIfNeeded(pixelBuffer),
              let upright = uprightIfNeeded(scaled, orientation: orientation) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(upright), height: CVPixelBufferGetHeight(upright))
        let seconds = CMTimeGetSeconds(pts)
        if size != cropFrameSize || !seconds.isFinite || seconds - lastCropCheck >= Self.cropCheckInterval {
            lastCropCheck = seconds
            updateCrop(Self.contentRect(of: upright), frameSize: size)
        }
        guard let canvas = onCanvas(upright) else { return }
        lastFrame = canvas
        encodeScaled(canvas, pts: pts)
    }

    /// Encodes the last frame again at `pts`: ReplayKit sends nothing while the screen stands still,
    /// and the live stream for the car needs frames, and keyframes, to keep going.
    /// Same serial context as `encode`.
    func repeatLastFrame(pts: CMTime) {
        guard let source = lastFrame else { return }
        encodeScaled(source, pts: pts)
    }

    private func encodeScaled(_ source: CVPixelBuffer, pts: CMTime) {
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
            self?.emit(sampleBuffer)
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
        if let rotation {
            VTPixelRotationSessionInvalidate(rotation)
        }
        rotation = nil
        rotatedPool = nil
        if let canvasTransfer {
            VTPixelTransferSessionInvalidate(canvasTransfer)
        }
        canvasTransfer = nil
        canvasPool = nil
        lastFrame = nil
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
        // The app cuts the stream into half-second HLS segments for the car, at keyframes.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, max(frameRate / 2, 1) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Self.keyframeInterval as CFNumber)
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

    private func emit(_ sampleBuffer: CMSampleBuffer) {
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
        let frame = MirrorProtocol.Frame(isKeyframe: isKeyframe, orientation: Self.upright, ptsMicroseconds: micros, data: data)
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
        // A quarter larger than the canvas: a 16:9 film cut out of the wider iPhone screen still fills it.
        let target = Self.targetSize(width: width, height: height, maxLongSide: maxLongSide * 5 / 4)
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

    /// `CGImagePropertyOrientation.up`.
    private static let upright: UInt8 = 1

    /// Turns a turned screen upright; mirrored orientations are treated as their plain ones.
    /// ReplayKit's `.right` needs a counterclockwise turn, not the clockwise one its EXIF meaning
    /// suggests: turned clockwise, the picture was upside down in the car (iPhone, 2026-10-28).
    private func uprightIfNeeded(_ pixelBuffer: CVPixelBuffer, orientation: UInt8) -> CVPixelBuffer? {
        let angle: CFString
        switch orientation {
        case 6, 7: angle = kVTRotation_CCW90   // .right, .rightMirrored
        case 8, 5: angle = kVTRotation_CW90    // .left, .leftMirrored
        case 3, 4: angle = kVTRotation_180     // .down, .downMirrored
        default: return pixelBuffer
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = angle == kVTRotation_180 ? (width: width, height: height) : (width: height, height: width)

        if rotation == nil {
            var newRotation: VTPixelRotationSession?
            VTPixelRotationSessionCreate(kCFAllocatorDefault, &newRotation)
            rotation = newRotation
        }
        if rotatedPool == nil || rotatedPoolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(pixelBuffer),
                kCVPixelBufferWidthKey: size.width,
                kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            rotatedPool = newPool
            rotatedPoolSize = size
        }
        guard let rotation, let rotatedPool else { return nil }
        VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle)

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, rotatedPool, &output) == kCVReturnSuccess,
              let output,
              VTPixelRotationSessionRotateImage(rotation, pixelBuffer, output) == noErr
        else {
            Log.relay.error("encoder: rotation failed")
            return nil
        }
        return output
    }

    // MARK: - Canvas

    /// Fits the upright frame, without its black bars, into the 16:9 canvas.
    func onCanvas(_ upright: CVPixelBuffer) -> CVPixelBuffer? {
        if canvasTransfer == nil {
            var newTransfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &newTransfer)
            if let newTransfer {
                VTSessionSetProperty(newTransfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
            canvasTransfer = newTransfer
        }
        if canvasPool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey: canvasSize.width,
                kCVPixelBufferHeightKey: canvasSize.height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &canvasPool)
        }
        guard let canvasTransfer, let canvasPool else { return nil }

        // Letterbox scales the source's clean aperture: the crop is put there for this transfer only.
        let width = Double(CVPixelBufferGetWidth(upright))
        let height = Double(CVPixelBufferGetHeight(upright))
        let content = crop ?? CGRect(x: 0, y: 0, width: width, height: height)
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: content.width,
            kCVImageBufferCleanApertureHeightKey: content.height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: content.midX - width / 2,
            kCVImageBufferCleanApertureVerticalOffsetKey: content.midY - height / 2,
        ]
        CVBufferSetAttachment(upright, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        defer { CVBufferRemoveAttachment(upright, kCVImageBufferCleanApertureKey) }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, canvasPool, &output) == kCVReturnSuccess,
              let output,
              VTPixelTransferSessionTransferImage(canvasTransfer, from: upright, to: output) == noErr
        else { return nil }
        // The transfer notes aperture and pixel aspect on the canvas; they would only change the
        // stream's format, the picture is final.
        CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
        CVBufferRemoveAttachment(output, kCVImageBufferPixelAspectRatioKey)
        return output
    }

    /// A smaller crop is taken only when two looks in a row see it, so a dark scene does not shrink
    /// the picture; content that shows up where a bar was is uncovered at once.
    private func updateCrop(_ detected: CGRect?, frameSize: CGSize) {
        let full = CGRect(origin: .zero, size: frameSize)
        if frameSize != cropFrameSize {
            // A turned phone: the old crop does not fit the new frame.
            cropFrameSize = frameSize
            crop = detected == full ? nil : detected
            cropCandidate = nil
            return
        }
        // An all-dark frame tells nothing about bars.
        guard let detected else { return }
        let current = crop ?? full
        if detected == current {
            cropCandidate = nil
        } else if !current.contains(detected) || detected == cropCandidate {
            crop = detected == full ? nil : detected
            cropCandidate = nil
        } else {
            cropCandidate = detected
        }
    }

    /// Brightest value (0–255) still taken for a black bar.
    private static let blackLevel = 28

    /// The frame without black bars along both sides and along top and bottom: the whole frame when
    /// there are none, `nil` when the frame is all dark. Bars are cut evenly on both sides to the
    /// thinner one, so content at one edge is never lost.
    static func contentRect(of buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let brightness: (Int, Int) -> Int
        if CVPixelBufferIsPlanar(buffer) {
            // Y plane of 4:2:0.
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            brightness = { x, y in Int(bytes[y * rowBytes + x]) }
        } else if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            brightness = { x, y in
                let pixel = y * rowBytes + x * 4
                return max(Int(bytes[pixel]), Int(bytes[pixel + 1]), Int(bytes[pixel + 2]))
            }
        } else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        // Sixteen lines across each direction: a column is a bar when it is black on all of them.
        let lines = 16
        let rows = (0..<lines).map { (2 * $0 + 1) * height / (2 * lines) }
        let columns = (0..<lines).map { (2 * $0 + 1) * width / (2 * lines) }
        let isBarColumn = { (x: Int) in rows.allSatisfy { brightness(x, $0) <= blackLevel } }
        let isBarRow = { (y: Int) in columns.allSatisfy { brightness($0, y) <= blackLevel } }
        guard let left = (0..<width).first(where: { !isBarColumn($0) }),
              let right = (0..<width).reversed().first(where: { !isBarColumn($0) }),
              let top = (0..<height).first(where: { !isBarRow($0) }),
              let bottom = (0..<height).reversed().first(where: { !isBarRow($0) })
        else { return nil }

        // Bars thinner than 2 % are left alone.
        let side = min(left, width - 1 - right) & ~1
        let edge = min(top, height - 1 - bottom) & ~1
        let x = side >= width / 50 ? side : 0
        let y = edge >= height / 50 ? edge : 0
        // A picture cut to less than 40 % is dark content, not bars.
        guard width - 2 * x >= width * 2 / 5, height - 2 * y >= height * 2 / 5 else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        return CGRect(x: x, y: y, width: width - 2 * x, height: height - 2 * y)
    }

    private static func targetSize(width: Int, height: Int, maxLongSide: Int) -> (width: Int, height: Int) {
        let longSide = max(width, height)
        guard longSide > maxLongSide else { return (width & ~1, height & ~1) }
        let scale = Double(maxLongSide) / Double(longSide)
        return (Int(Double(width) * scale) & ~1, Int(Double(height) * scale) & ~1)
    }
}
