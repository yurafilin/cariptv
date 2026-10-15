import os

enum Log {
    static let carplay = Logger(subsystem: "weappico.cariptv", category: "carplay")
    static let mirror = Logger(subsystem: "weappico.cariptv", category: "mirror")
    static let relay = Logger(subsystem: "weappico.cariptv", category: "relay")
    static let playback = Logger(subsystem: "weappico.cariptv", category: "playback")
    static let cast = Logger(subsystem: "weappico.cariptv", category: "cast")
}
