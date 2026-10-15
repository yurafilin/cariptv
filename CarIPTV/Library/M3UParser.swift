import Foundation

/// Parses extended M3U playlists (`#EXTM3U` / `#EXTINF` with `tvg-*` and `group-title` attributes).
/// Tolerant by design: IPTV playlists in the wild break the format in every possible way.
enum M3UParser {
    static func parse(_ text: String) -> [Channel] {
        var channels: [Channel] = []
        var pendingInfo: (name: String?, attributes: [String: String])?
        var pendingGroup: String?
        var occurrences: [String: Int] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTINF") {
                pendingInfo = parseInfo(line)
                continue
            }
            if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("#") {
                continue
            }

            guard let url = URL(string: line), let scheme = url.scheme, !scheme.isEmpty else {
                pendingInfo = nil
                pendingGroup = nil
                continue
            }

            let attributes = pendingInfo?.attributes ?? [:]
            let name = nonEmpty(pendingInfo?.name)
                ?? nonEmpty(attributes["tvg-name"])
                ?? url.host()
                ?? line
            let group = nonEmpty(attributes["group-title"]) ?? nonEmpty(pendingGroup)
            let logo = nonEmpty(attributes["tvg-logo"]).flatMap { URL(string: $0) }

            // The same stream may be listed twice (e.g. in two groups); ids must stay unique.
            let count = occurrences[line, default: 0]
            occurrences[line] = count + 1
            let id = count == 0 ? line : "\(line)#\(count)"

            channels.append(Channel(id: id, name: name, url: url, group: group, logo: logo))
            pendingInfo = nil
            pendingGroup = nil
        }
        return channels
    }

    /// `#EXTINF:-1 tvg-id="x" group-title="News, World",Channel name, with commas`
    static func parseInfo(_ line: String) -> (name: String?, attributes: [String: String]) {
        guard let colon = line.firstIndex(of: ":") else { return (nil, [:]) }
        let body = line[line.index(after: colon)...]

        // The title follows the first comma outside quotes; attribute values may contain commas.
        var inQuotes = false
        var titleStart: Substring.Index?
        for index in body.indices {
            let character = body[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                titleStart = body.index(after: index)
                break
            }
        }

        let header = titleStart.map { body[..<body.index(before: $0)] } ?? body
        let title = titleStart.map { String(body[$0...]).trimmingCharacters(in: .whitespaces) }
        return (title, parseAttributes(header))
    }

    static func parseAttributes(_ text: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = text.startIndex
        while let equals = text[index...].range(of: "=\"") {
            var keyStart = equals.lowerBound
            while keyStart > text.startIndex {
                let previous = text.index(before: keyStart)
                let character = text[previous]
                guard character.isLetter || character.isNumber || character == "-" || character == "_" else { break }
                keyStart = previous
            }
            let key = text[keyStart..<equals.lowerBound].lowercased()
            guard let closing = text[equals.upperBound...].firstIndex(of: "\"") else { break }
            if !key.isEmpty {
                attributes[key] = String(text[equals.upperBound..<closing])
            }
            index = text.index(after: closing)
        }
        return attributes
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
