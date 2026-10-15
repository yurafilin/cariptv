import Foundation

/// Wire format between the ScreenRelay broadcast extension (sender) and the app (receiver).
/// TCP on loopback, every packet is `[length: UInt32 BE][type: UInt8][payload]`,
/// where `length` counts the type byte and the payload.
enum MirrorProtocol {
    static let port: UInt16 = 52_741
    static let version: UInt8 = 1
    static let host = "127.0.0.1"

    enum MessageType: UInt8 {
        /// sender → app: `[version: UInt8]`
        case hello = 1
        /// sender → app: `[count: UInt8]` then `count × [length: UInt16][H.264 parameter set]` (SPS, PPS)
        case parameterSets = 2
        /// sender → app: `[flags: UInt8][orientation: UInt8][pts: Int64 µs]` then AVCC frame data
        case frame = 3
        /// sender → app: broadcast stopped
        case bye = 4
        /// app → sender: next frame must be a keyframe
        case keyframeRequest = 5
    }

    struct Frame {
        var isKeyframe: Bool
        /// `CGImagePropertyOrientation` raw value from ReplayKit (1 = up).
        var orientation: UInt8
        var ptsMicroseconds: Int64
        var data: Data
    }

    static func packet(_ type: MessageType, _ payload: Data = Data()) -> Data {
        var packet = Data(capacity: 5 + payload.count)
        packet.appendBigEndian(UInt32(1 + payload.count))
        packet.append(type.rawValue)
        packet.append(payload)
        return packet
    }

    static func helloPacket() -> Data {
        packet(.hello, Data([version]))
    }

    static func parameterSetsPacket(_ sets: [Data]) -> Data {
        var payload = Data()
        payload.append(UInt8(sets.count))
        for set in sets {
            payload.appendBigEndian(UInt16(set.count))
            payload.append(set)
        }
        return packet(.parameterSets, payload)
    }

    static func framePacket(_ frame: Frame) -> Data {
        var payload = Data(capacity: 10 + frame.data.count)
        payload.append(frame.isKeyframe ? 1 : 0)
        payload.append(frame.orientation)
        payload.appendBigEndian(frame.ptsMicroseconds)
        payload.append(frame.data)
        return packet(.frame, payload)
    }

    static func parseParameterSets(_ payload: Data) -> [Data]? {
        var reader = ByteReader(payload)
        guard let count = reader.read(UInt8.self), count > 0 else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let length = reader.read(UInt16.self), let set = reader.readData(Int(length)) else { return nil }
            sets.append(set)
        }
        return sets
    }

    static func parseFrame(_ payload: Data) -> Frame? {
        var reader = ByteReader(payload)
        guard let flags = reader.read(UInt8.self),
              let orientation = reader.read(UInt8.self),
              let pts = reader.read(Int64.self) else { return nil }
        let data = reader.remainingData()
        guard !data.isEmpty else { return nil }
        return Frame(isKeyframe: flags & 1 == 1, orientation: orientation, ptsMicroseconds: pts, data: data)
    }
}

/// Splits a TCP byte stream into protocol packets.
struct MirrorPacketParser {
    private static let maxPacketLength = 8 << 20
    private var buffer = Data()

    /// Returns complete packets; `nil` when the stream is corrupt and the connection should be dropped.
    mutating func append(_ bytes: Data) -> [(MirrorProtocol.MessageType, Data)]? {
        buffer.append(bytes)
        var packets: [(MirrorProtocol.MessageType, Data)] = []
        var consumed = 0
        while true {
            var reader = ByteReader(buffer, offset: consumed)
            guard let length = reader.read(UInt32.self) else { break }
            guard length >= 1, length <= Self.maxPacketLength else { return nil }
            guard let body = reader.readData(Int(length)) else { break }
            consumed += 4 + Int(length)
            // Unknown types are skipped so a newer sender does not break an older receiver.
            if let type = MirrorProtocol.MessageType(rawValue: body[body.startIndex]) {
                packets.append((type, Data(body.dropFirst())))
            }
        }
        if consumed > 0 {
            buffer = Data(buffer.dropFirst(consumed))
        }
        return packets
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        var value: T = 0
        let start = data.startIndex + offset
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: start..<start + size) }
        offset += size
        return T(bigEndian: value)
    }

    mutating func readData(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start..<start + count)
    }

    func remainingData() -> Data {
        data.subdata(in: data.startIndex + offset..<data.endIndex)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
