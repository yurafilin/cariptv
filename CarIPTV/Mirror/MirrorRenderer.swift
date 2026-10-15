import AVFoundation
import CoreMedia

/// Turns received H.264 frames into sample buffers for every attached display.
/// Thread-safe: frames arrive on the receiver queue, displays attach on the main thread.
final class MirrorRenderer {
    /// A display joined, dropped frames or lost its decoder: the sender should emit a keyframe.
    var onNeedsKeyframe: (() -> Void)?

    private struct Sink {
        let renderer: AVSampleBufferVideoRenderer
        /// P-frames are useless until the decoder has seen a keyframe.
        var waitingForKeyframe = true
    }

    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: Sink] = [:]
    private var formatDescription: CMVideoFormatDescription?

    func attach(_ renderer: AVSampleBufferVideoRenderer) {
        renderer.flush()
        lock.withLock { sinks[ObjectIdentifier(renderer)] = Sink(renderer: renderer) }
        onNeedsKeyframe?()
    }

    func detach(_ renderer: AVSampleBufferVideoRenderer) {
        lock.withLock { sinks[ObjectIdentifier(renderer)] = nil }
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// New sender: forget the old stream and clear the screens.
    func reset() {
        let renderers = lock.withLock { () -> [AVSampleBufferVideoRenderer] in
            formatDescription = nil
            for key in sinks.keys {
                sinks[key]?.waitingForKeyframe = true
            }
            return sinks.values.map(\.renderer)
        }
        renderers.forEach { $0.flush(removingDisplayedImage: true, completionHandler: nil) }
    }

    /// Returns the coded size, or `nil` when the parameter sets are unusable.
    func setParameterSets(_ sets: [Data]) -> CMVideoDimensions? {
        guard let format = Self.makeFormatDescription(sets) else { return nil }
        lock.withLock { formatDescription = format }
        return CMVideoFormatDescriptionGetDimensions(format)
    }

    func render(_ frame: MirrorProtocol.Frame) {
        guard let format = lock.withLock({ formatDescription }),
              let sampleBuffer = Self.makeSampleBuffer(frame, format: format) else { return }

        let needsKeyframe = lock.withLock { () -> Bool in
            var needsKeyframe = false
            for (key, var sink) in sinks {
                let renderer = sink.renderer
                if renderer.requiresFlushToResumeDecoding || renderer.status == .failed {
                    // The decoder was torn down, e.g. while the app sat in the background.
                    renderer.flush()
                    sink.waitingForKeyframe = true
                    needsKeyframe = true
                }
                if sink.waitingForKeyframe, !frame.isKeyframe {
                    sinks[key] = sink
                    continue
                }
                if renderer.isReadyForMoreMediaData {
                    renderer.enqueue(sampleBuffer)
                    sink.waitingForKeyframe = false
                } else {
                    sink.waitingForKeyframe = true
                    needsKeyframe = true
                }
                sinks[key] = sink
            }
            return needsKeyframe
        }
        if needsKeyframe {
            onNeedsKeyframe?()
        }
    }

    // MARK: - CoreMedia

    private static func makeFormatDescription(_ sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty, sets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let buffers = sets.map { set -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes = buffers.map(\.count)

        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private static func makeSampleBuffer(_ frame: MirrorProtocol.Frame, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = frame.data.count
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = frame.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frame.ptsMicroseconds, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // Live stream: show each frame as soon as it is decoded, ignore timestamps.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !frame.isKeyframe {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
        return sampleBuffer
    }
}
