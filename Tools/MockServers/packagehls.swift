// Packages a file into HLS on the Mac the way HLSPackager does on the phone (fMP4, one writer per
// track, the same playlists), so the result can be served by mockservers.py as a control.
//
//     swift Tools/MockServers/packagehls.swift Tools/MockServers/media/test.mp4 Tools/MockServers/media/packaged
import AVFoundation
import UniformTypeIdentifiers

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

final class Track: NSObject, AVAssetWriterDelegate {
    let prefix: String
    var durations: [Double] = []
    init(prefix: String) { self.prefix = prefix }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData data: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        if segmentType == .initialization {
            try! data.write(to: output.appendingPathComponent("\(prefix)init.mp4"))
        } else {
            try! data.write(to: output.appendingPathComponent("\(prefix)\(durations.count).m4s"))
            durations.append(segmentReport?.trackReports.first?.duration.seconds ?? 4)
        }
    }

    func playlist() -> String {
        let target = max(10, Int((durations.max() ?? 0).rounded(.up)))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES",
                     "#EXT-X-MAP:URI=\"\(prefix)init.mp4\""]
        for (index, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", duration))
            lines.append("\(prefix)\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

func package(_ assetTrack: AVAssetTrack, asset: AVAsset, prefix: String) async throws -> Track {
    let track = Track(prefix: prefix)
    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: nil)
    reader.add(readerOutput)
    let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
    writer.outputFileTypeProfile = .mpeg4AppleHLS
    writer.preferredOutputSegmentInterval = CMTime(seconds: 4, preferredTimescale: 1)
    writer.initialSegmentStartTime = .zero
    writer.delegate = track
    let format = try await assetTrack.load(.formatDescriptions).first
    let input = AVAssetWriterInput(mediaType: assetTrack.mediaType, outputSettings: nil, sourceFormatHint: format)
    writer.add(input)
    reader.startReading()
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    while let sample = readerOutput.copyNextSampleBuffer() {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        input.append(sample)
    }
    input.markAsFinished()
    await writer.finishWriting()
    precondition(writer.status == .completed, "\(String(describing: writer.error))")
    return track
}

let asset = AVURLAsset(url: source)
let tracks = try await asset.load(.tracks)
let video = try await package(tracks.first { $0.mediaType == .video }!, asset: asset, prefix: "v")
try video.playlist().write(to: output.appendingPathComponent("video.m3u8"), atomically: true, encoding: .utf8)
if let audioTrack = tracks.first(where: { $0.mediaType == .audio }) {
    let audio = try await package(audioTrack, asset: asset, prefix: "a")
    try audio.playlist().write(to: output.appendingPathComponent("audio.m3u8"), atomically: true, encoding: .utf8)
    let master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS",
                  "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
                  "#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO=\"audio\"", "video.m3u8", ""].joined(separator: "\n")
    try master.write(to: output.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
} else {
    try video.playlist().write(to: output.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
}
print("packaged \(video.durations.count) video segments into \(output.path)")
