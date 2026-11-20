import Foundation

/// What yt-dlp found for a link: one video, or a playlist / channel.
struct VideoInfo: Sendable, Codable, Hashable {
    struct Format: Sendable, Codable, Hashable {
        var id: String
        var ext: String
        var vcodec: String
        var acodec: String
        var height: Int
        var width: Int
        var fps: Double
        var range: String       // SDR, HDR10, HLG, DV
        var bytes: Int64        // exact or estimated
        var exact: Bool
        var bitrate: Double     // kbit/s
        var proto: String
        var note: String
        var languagePreference: Int

        var hasVideo: Bool { vcodec != "none" && !vcodec.isEmpty && height > 0 }
        var hasAudio: Bool { acodec != "none" && !acodec.isEmpty }
        var isHDR: Bool { range != "SDR" && !range.isEmpty }
        var codecName: String {
            let v = vcodec.lowercased()
            if v.hasPrefix("av01") { return "AV1" }
            if v.hasPrefix("vp09") || v.hasPrefix("vp9") { return "VP9" }
            if v.hasPrefix("avc") || v.hasPrefix("h264") { return "H.264" }
            if v.hasPrefix("hev") || v.hasPrefix("hvc") { return "HEVC" }
            return vcodec.uppercased()
        }
        var isVP9: Bool { codecName == "VP9" }
        var codecRank: Int {
            switch codecName { case "AV1": 4; case "HEVC": 3; case "VP9": 2; case "H.264": 1; default: 0 }
        }
        var audioName: String {
            let a = acodec.lowercased()
            if a.hasPrefix("opus") { return "Opus" }
            if a.hasPrefix("mp4a") { return "AAC" }
            return acodec
        }
    }

    struct Subtitle: Sendable, Codable, Hashable, Identifiable {
        var code: String        // what yt-dlp calls it (en, de-orig, en-de)
        var name: String
        var auto: Bool
        var id: String { (auto ? "auto:" : "") + code }
        var isTranslation: Bool { auto && name == "English (translated)" }
    }

    struct Entry: Sendable, Codable, Hashable {
        var id: String
        var title: String
        var duration: Double
    }

    var id: String
    var title: String
    var channel: String
    var duration: Double
    var link: String
    var thumbnail: String?
    var language: String?
    var formats: [Format]
    var subtitles: [Subtitle]
    var description: String
    var isLive: Bool
    /// For playlists and channels.
    var entries: [Entry]
    var isPlaylist: Bool
    var usedCookies: Bool = false

    // MARK: Parsing yt-dlp's JSON

    static func parse(_ data: Data) throws -> VideoInfo {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Tools.Failure(message: "YouTube sent something Snag could not read.")
        }
        return parse(j)
    }

    static func parse(_ j: [String: Any]) -> VideoInfo {
        func s(_ k: String, _ d: [String: Any] = j) -> String? { d[k] as? String }
        func n(_ k: String, _ d: [String: Any]) -> Double? {
            if let v = d[k] as? Double { return v }
            if let v = d[k] as? Int { return Double(v) }
            return nil
        }
        let type = s("_type") ?? "video"
        let duration = n("duration", j) ?? 0
        var formats: [Format] = []
        for f in (j["formats"] as? [[String: Any]]) ?? [] {
            let proto = s("protocol", f) ?? ""
            if proto.contains("mhtml") { continue }           // storyboards
            let note = s("format_note", f) ?? ""
            let tbr = n("tbr", f) ?? 0
            var bytes = Int64(n("filesize", f) ?? 0)
            var exact = bytes > 0
            if bytes == 0, let approx = n("filesize_approx", f) { bytes = Int64(approx); exact = false }
            if bytes == 0, tbr > 0, duration > 0 { bytes = Int64(tbr * 1000 / 8 * duration); exact = false }
            formats.append(Format(
                id: s("format_id", f) ?? "",
                ext: s("ext", f) ?? "",
                vcodec: s("vcodec", f) ?? "none",
                acodec: s("acodec", f) ?? "none",
                height: Int(n("height", f) ?? 0),
                width: Int(n("width", f) ?? 0),
                fps: n("fps", f) ?? 0,
                range: s("dynamic_range", f) ?? "SDR",
                bytes: bytes, exact: exact,
                bitrate: tbr,
                proto: proto,
                note: note,
                languagePreference: Int(n("language_preference", f) ?? -1)))
        }

        var subs: [Subtitle] = []
        let language = s("language")
        if let manual = j["subtitles"] as? [String: Any] {
            for (code, value) in manual where code != "live_chat" {
                let name = ((value as? [[String: Any]])?.first?["name"] as? String) ?? code
                subs.append(Subtitle(code: code, name: name, auto: false))
            }
        }
        if let auto = j["automatic_captions"] as? [String: Any] {
            // The speech itself (xx-orig, or the video's language), plus
            // English translated by YouTube when the video is not English.
            let orig = auto.keys.first { $0.hasSuffix("-orig") } ?? language.flatMap { auto[$0] != nil ? $0 : nil }
            if let orig {
                let name = ((auto[orig] as? [[String: Any]])?.first?["name"] as? String) ?? orig
                subs.append(Subtitle(code: orig, name: name.replacingOccurrences(of: " (Original)", with: ""), auto: true))
            }
            let lang = (language ?? orig ?? "").split(separator: "-").first.map(String.init) ?? ""
            if lang != "en", auto["en"] != nil {
                subs.append(Subtitle(code: "en", name: "English (translated)", auto: true))
            }
        }
        subs.sort { a, b in a.auto == b.auto ? a.name < b.name : !a.auto }

        var entries: [Entry] = []
        for e in (j["entries"] as? [[String: Any]]) ?? [] {
            guard let id = s("id", e) else { continue }
            if s("ie_key", e) == "YoutubeTab" { continue }   // a tab of a channel, not a video
            entries.append(Entry(id: id, title: s("title", e) ?? id, duration: n("duration", e) ?? 0))
        }

        return VideoInfo(
            id: s("id") ?? "",
            title: s("title") ?? s("id") ?? "Video",
            channel: s("channel") ?? s("uploader") ?? s("playlist_uploader") ?? "",
            duration: duration,
            link: s("webpage_url") ?? s("original_url") ?? "",
            thumbnail: bestThumbnail(j),
            language: language,
            formats: formats,
            subtitles: subs,
            description: s("description") ?? "",
            isLive: (j["is_live"] as? Bool) ?? false,
            entries: entries,
            isPlaylist: type == "playlist")
    }

    /// The biggest picture, preferring YouTube's own maxresdefault JPG
    /// (so no WebP-to-JPG re-encode is needed).
    static func bestThumbnail(_ j: [String: Any]) -> String? {
        let thumbs = (j["thumbnails"] as? [[String: Any]]) ?? []
        if let max = thumbs.first(where: { ($0["url"] as? String)?.contains("maxresdefault.jpg") == true })?["url"] as? String {
            return max
        }
        let scored = thumbs.compactMap { t -> (String, Int)? in
            guard let url = t["url"] as? String else { return nil }
            let w = (t["width"] as? Int) ?? 0, h = (t["height"] as? Int) ?? 0
            let pref = (t["preference"] as? Int) ?? 0
            let jpg = url.contains(".jpg") ? 1 : 0
            return (url, w * h * 10 + jpg * 5 + pref + 1000)
        }
        return scored.max { $0.1 < $1.1 }?.0 ?? (j["thumbnail"] as? String)
    }

    // MARK: Choosing streams

    struct Quality: Hashable, Identifiable {
        var height: Int
        var fps: Double
        var hdr: Bool
        var id: Int { height }
        var label: String {
            var s = "\(height)p"
            if fps > 30 { s += "\(Int(fps.rounded()))" }
            return s
        }
        var badge: String? {
            if height >= 4320 { return "8K" }
            if height >= 2160 { return "4K" }
            if height >= 1440 { return "2K" }
            if height >= 1080 { return "HD" }
            return nil
        }
    }

    var videoFormats: [Format] { formats.filter { $0.hasVideo && !$0.hasAudio } }
    var audioFormats: [Format] {
        formats.filter { $0.hasAudio && !$0.hasVideo && !$0.note.uppercased().contains("DRC") }
    }

    /// Heights on offer, best first.
    var qualities: [Quality] {
        var best: [Int: Quality] = [:]
        for f in videoFormats {
            let q = Quality(height: f.height, fps: f.fps, hdr: f.isHDR)
            if let old = best[f.height] {
                best[f.height] = Quality(height: f.height, fps: max(old.fps, q.fps), hdr: old.hdr || q.hdr)
            } else { best[f.height] = q }
        }
        if best.isEmpty {   // only combined streams (old videos)
            for f in formats where f.hasVideo { best[f.height] = Quality(height: f.height, fps: f.fps, hdr: f.isHDR) }
        }
        return best.values.sorted { $0.height > $1.height }
    }

    /// The video stream for a height (nil = the best there is): highest
    /// frame rate, HDR if wanted, then AV1 > HEVC > VP9 > H.264, then bitrate.
    /// Direct (https) streams before HLS pieces.
    func pickVideo(height: Int?, hdr: Bool) -> Format? {
        var pool = videoFormats
        if pool.isEmpty { pool = formats.filter(\.hasVideo) }
        if let height { pool = pool.filter { $0.height <= height } }
        return pool.max { a, b in
            if a.height != b.height { return a.height < b.height }
            if Int(a.fps.rounded()) != Int(b.fps.rounded()) { return a.fps < b.fps }
            if a.isHDR != b.isHDR { return hdr ? !a.isHDR : a.isHDR }
            let ah = a.proto.hasPrefix("http"), bh = b.proto.hasPrefix("http")
            if ah != bh { return !ah }
            if a.codecRank != b.codecRank { return a.codecRank < b.codecRank }
            return a.bitrate < b.bitrate
        }
    }

    /// The best sound: the original language track (not a dub), then bitrate.
    func pickAudio() -> Format? {
        audioFormats.max { a, b in
            if a.languagePreference != b.languagePreference { return a.languagePreference < b.languagePreference }
            let ah = a.proto.hasPrefix("http"), bh = b.proto.hasPrefix("http")
            if ah != bh { return !ah }
            if Int(a.bitrate / 8) != Int(b.bitrate / 8) { return a.bitrate < b.bitrate }
            return a.audioName != "Opus" && b.audioName == "Opus"
        }
    }

    /// Subtitles chosen when nothing was picked by hand: the video's own
    /// language written by people, else English by people, else the
    /// automatic captions of the speech.
    var defaultSubtitles: Set<String> {
        let lang = language?.split(separator: "-").first.map(String.init)
        let manual = subtitles.filter { !$0.auto }
        if let lang, let m = manual.first(where: { $0.code == lang || $0.code.hasPrefix(lang + "-") }) { return [m.id] }
        if let m = manual.first(where: { $0.code == "en" || $0.code.hasPrefix("en-") }) { return [m.id] }
        if let m = manual.first, manual.count == 1 { return [m.id] }
        if let a = subtitles.first(where: { $0.auto && !$0.isTranslation }) { return [a.id] }
        return []
    }
}

/// Link checks done before asking yt-dlp anything.
enum Link {
    static func normalized(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") {
            if t.count == 11, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                return "https://www.youtube.com/watch?v=" + t
            }
            if t.hasPrefix("@") { t = "https://www.youtube.com/" + t } else { t = "https://" + t }
        }
        guard let url = URL(string: t), let host = url.host?.lowercased(), host.contains(".") else { return nil }
        // A channel's main page holds tabs; its Videos tab is what people mean.
        if host.contains("youtube.com"), let first = url.pathComponents.dropFirst().first,
           first.hasPrefix("@") || first == "channel" || first == "c" {
            let parts = url.pathComponents.dropFirst()
            let base = first == "channel" || first == "c" ? 2 : 1
            if parts.count == base { return t.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/videos" }
        }
        return t
    }

    static func isYouTube(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host?.lowercased() else { return false }
        return host.contains("youtube.com") || host.contains("youtu.be")
    }

    /// A watch link that also names a playlist: the video alone by default.
    static func hasPlaylist(_ link: String) -> Bool {
        URLComponents(string: link)?.queryItems?.contains { $0.name == "list" } ?? false
    }
    static func hasVideo(_ link: String) -> Bool {
        guard let c = URLComponents(string: link) else { return false }
        if c.queryItems?.contains(where: { $0.name == "v" }) == true { return true }
        if c.host?.contains("youtu.be") == true { return true }
        return c.path.hasPrefix("/shorts/") || c.path.hasPrefix("/live/")
    }
}
