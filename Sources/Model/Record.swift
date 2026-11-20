import Foundation

/// One line in Downloads: a video, or a whole playlist / channel.
struct Record: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, working, paused, done, failed }

    var id = UUID()
    var videoID: String
    var title: String
    var channel: String
    var link: String
    var thumbnail: String?
    var duration: Double
    var choice: Choice
    var quality: String          // "2160p60 · AV1"
    var isPlaylist = false
    var entries: [VideoInfo.Entry] = []
    var doneIDs: [String] = []
    var failedIDs: [String] = []
    var state: State = .queued
    var stage = ""
    var fraction = 0.0
    var bytesTotal: Int64 = 0
    var files: [String] = []
    var error: String?
    var date = Date()

    var mainFile: URL? {
        let urls = files.map { URL(fileURLWithPath: $0) }
        return urls.first { ["mp4", "mkv", "webm", "mov"].contains($0.pathExtension) }
            ?? urls.first { ["m4a", "mp3", "flac", "wav"].contains($0.pathExtension) }
            ?? urls.first
    }
    var isActive: Bool { state == .queued || state == .working }
}


/// Downloads list kept between launches.
enum History {
    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [Record] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    static func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(Array(records.prefix(500))) else { return }
        try? data.write(to: file, options: .atomic)
    }
}


/// What snag-mcp hands to the app through snag://add.
struct AddRequest: Codable {
    var link: String
    var choice: Choice
    var whole: Bool
}

extension Data {
    /// base64url (safe inside a URL query), padding optional.
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
