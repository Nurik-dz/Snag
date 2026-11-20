import Foundation
import AppKit

/// What to fetch for one video.
struct Choice: Codable, Hashable, Sendable {
    var video = true
    var audio = false
    var subtitles: Set<String> = []     // VideoInfo.Subtitle ids
    var thumbnail = true
    var description = false
    var height: Int? = nil              // nil = the best there is
    var hdr = true

    var isEmpty: Bool { !video && !audio && subtitles.isEmpty && !thumbnail && !description }
}

extension Choice {
    /// Subtitle choices that name a rule rather than a track:
    /// "*" = the usual pick for that video, "lang:xx" = language xx
    /// (people's subtitles first, else automatic captions).
    func resolved(for info: VideoInfo) -> Choice {
        var c = self
        var ids = Set<String>()
        for s in subtitles {
            if s == "*" { ids.formUnion(info.defaultSubtitles) }
            else if s.hasPrefix("lang:") {
                let lang = String(s.dropFirst(5)).lowercased()
                func match(_ x: VideoInfo.Subtitle) -> Bool {
                    let code = x.code.lowercased().replacingOccurrences(of: "-orig", with: "")
                    return code == lang || code.hasPrefix(lang + "-")
                }
                if let m = info.subtitles.first(where: { !$0.auto && match($0) }) ?? info.subtitles.first(where: { $0.auto && match($0) }) {
                    ids.insert(m.id)
                }
            } else { ids.insert(s) }
        }
        c.subtitles = ids
        return c
    }
}

/// Live progress of one download.
struct Progress: Sendable {
    enum Stage: String, Sendable {
        case starting = "Starting"
        case downloading = "Downloading"
        case joining = "Joining picture and sound"
        case converting = "Converting for QuickTime"
        case audio = "Making the audio file"
        case subtitles = "Subtitles"
        case thumbnail = "Thumbnail"
        case finishing = "Finishing"
    }
    var stage: Stage
    var fraction: Double
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var detail: String = ""
}

enum Engine {
    // MARK: Looking a link up

    static func lookup(_ link: String, wholePlaylist: Bool) async throws -> VideoInfo {
        guard let ytdlp = Tools.ytdlp else { throw Tools.Missing(tool: "yt-dlp") }
        let single = Link.hasVideo(link) && !wholePlaylist
        var base = ["-J", "--no-warnings", "--ignore-no-formats-error"]
        base += single ? ["--no-playlist"] : ["--flat-playlist", "--yes-playlist"]

        func attempt(cookies: Bool) async throws -> VideoInfo {
            let run = ToolRun(ytdlp, base + (cookies ? cookieArgs : []) + [link])
            let result = try await run.run(keepOutput: true)
            try Task.checkCancellation()
            guard result.status == 0, let data = result.output.data(using: .utf8), !data.isEmpty else {
                throw Tools.Failure(message: friendly(run.lastError))
            }
            var info = try VideoInfo.parse(data)
            info.usedCookies = cookies
            if info.link.isEmpty { info.link = link }
            return info
        }

        switch Prefs.cookieMode {
        case .always: return try await attempt(cookies: !cookieArgs.isEmpty)
        case .never: return try await attempt(cookies: false)
        case .whenNeeded:
            do { return try await attempt(cookies: false) } catch {
                guard !cookieArgs.isEmpty, needsSignIn(error.localizedDescription) else { throw error }
                return try await attempt(cookies: true)
            }
        }
    }

    /// Empty while macOS blocks the browser's files: public videos then
    /// still work, and the window offers to fix the access.
    static var cookieArgs: [String] {
        guard Prefs.cookieMode != .never, let b = Prefs.browser, b != .none, b.canRead else { return [] }
        return ["--cookies-from-browser", b.rawValue]
    }

    // MARK: Downloading

    /// Downloads into a hidden work folder (so a cancelled download resumes),
    /// then moves the finished files next to each other with clean names.
    static func download(_ info: VideoInfo, _ choice: Choice, into folder: URL,
                         progress: @escaping @Sendable (Progress) -> Void) async throws -> [URL] {
        guard let ytdlp = Tools.ytdlp else { throw Tools.Missing(tool: "yt-dlp") }
        guard let ffmpeg = Tools.ffmpeg else { throw Tools.Missing(tool: "ffmpeg") }
        let fm = FileManager.default
        let work = folder.appendingPathComponent(".snag/\(info.id)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        progress(Progress(stage: .starting, fraction: 0))

        let wantMedia = choice.video || choice.audio
        let video = choice.video ? info.pickVideo(height: choice.height, hdr: choice.hdr) : nil
        let audio = wantMedia && !(video?.hasAudio ?? false) ? info.pickAudio() : nil
        if choice.video && video == nil && audio == nil {
            throw Tools.Failure(message: info.isLive ? "Live streams can be saved once they have ended." : "YouTube offered no video stream for this one.")
        }
        let container = Prefs.container

        var args = ["--no-playlist", "--newline", "--no-mtime", "--no-overwrites", "--continue",
                    "--ffmpeg-location", ffmpeg,
                    "-P", work.path, "-o", "%(id)s.%(ext)s",
                    "--progress-template",
                    "download:SNAGP %(info.format_id)s %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s"]
        args += cookieArgs.isEmpty || (Prefs.cookieMode == .whenNeeded && !info.usedCookies) ? [] : cookieArgs

        var parts: [VideoInfo.Format] = []
        if wantMedia {
            if let video, choice.video {
                parts.append(video)
                if let audio { parts.append(audio) }
                args += ["-f", parts.map(\.id).joined(separator: "+")]
                if audio != nil { args += ["--merge-output-format", container] }
                if choice.audio, audio != nil { args.append("-k") }   // keep the sound part for the audio file
                if Prefs.embed { args += ["--embed-metadata", "--embed-chapters"] }
            } else if let audio {
                parts.append(audio)
                args += ["-f", audio.id]
            } else {
                args += ["-f", choice.video ? "bv*+ba/b" : "ba/b"]
            }
        } else {
            args.append("--skip-download")
        }

        let subs = info.subtitles.filter { choice.subtitles.contains($0.id) }
        if !subs.isEmpty {
            if subs.contains(where: { !$0.auto }) { args.append("--write-subs") }
            if subs.contains(where: \.auto) { args.append("--write-auto-subs") }
            args += ["--sub-langs", Array(Set(subs.map(\.code))).joined(separator: ","), "--sub-format", "vtt/best"]
        }
        let needsDownload = wantMedia || !subs.isEmpty
        let total = max(1, parts.reduce(Int64(0)) { $0 + $1.bytes })

        if needsDownload {
            let tracker = ByteTracker(parts: parts, total: total, onUpdate: progress)
            let run = ToolRun(ytdlp, args + [info.link.isEmpty ? info.id : info.link])
            let result = try await run.run { line in tracker.line(line) }
            if Task.isCancelled { throw CancellationError() }
            if result.status != 0 {
                if result.status == 130 || result.status == 2 && run.lastError.isEmpty { throw CancellationError() }
                throw Tools.Failure(message: friendly(run.lastError))
            }
        }

        // Collect what yt-dlp made.
        let made = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        func file(_ name: String) -> URL? { made.first { $0.lastPathComponent == name } }
        let base = cleanName(info.title)
        var finals: [(URL, String)] = []   // (temp file, final file name)

        if choice.video, let video {
            let ext = audio == nil ? video.ext : container
            guard var merged = file("\(info.id).\(ext)") ?? made.first(where: {
                $0.deletingPathExtension().lastPathComponent == info.id && ["mp4", "mkv", "webm", "mov"].contains($0.pathExtension)
            }) else { throw Tools.Failure(message: "The video file was not made. Try again.") }
            if video.isVP9, Prefs.vp9 == .convert {
                progress(Progress(stage: .converting, fraction: 0, detail: "Same \(video.height)p, using the Mac's video engine"))
                merged = try await toHEVC(merged, video: video, duration: info.duration, ffmpeg: ffmpeg) { f in
                    progress(Progress(stage: .converting, fraction: f, detail: "Same \(video.height)p, using the Mac's video engine"))
                }
            }
            finals.append((merged, base + "." + merged.pathExtension))
        }

        if choice.audio, let audio {
            let source = file("\(info.id).f\(audio.id).\(audio.ext)") ?? file("\(info.id).\(audio.ext)")
                ?? made.first { $0.lastPathComponent.hasPrefix(info.id) && ["webm", "m4a", "opus", "mp3"].contains($0.pathExtension) && $0.lastPathComponent.contains("f\(audio.id)") }
            guard let source else { throw Tools.Failure(message: "The sound was not downloaded. Try again.") }
            progress(Progress(stage: .audio, fraction: 0.5, detail: Prefs.audioFormat.title))
            let out = try await makeAudio(source, format: Prefs.audioFormat, audio: audio, info: info, ffmpeg: ffmpeg)
            finals.append((out, base + "." + out.pathExtension))
        }

        if !subs.isEmpty {
            progress(Progress(stage: .subtitles, fraction: 1))
            let manualCodes = Set(subs.filter { !$0.auto }.map(\.code))
            for sub in subs {
                guard let vtt = made.first(where: { $0.lastPathComponent.hasPrefix("\(info.id).\(sub.code).") }) else { continue }
                // Players load "Name.en.srt" by itself. Automatic captions
                // keep the plain code unless people's subtitles share it.
                var code = sub.code.replacingOccurrences(of: "-orig", with: "")
                if sub.auto && manualCodes.contains(code) { code += ".auto" }
                let format = Prefs.subFormat
                if format != .vtt, vtt.pathExtension == "vtt", let text = try? String(contentsOf: vtt, encoding: .utf8) {
                    let srt = work.appendingPathComponent("\(info.id).\(code).out.srt")
                    try SubtitleConverter.srt(fromVTT: text).write(to: srt, atomically: true, encoding: .utf8)
                    finals.append((srt, "\(base).\(code).srt"))
                }
                if format != .srt || vtt.pathExtension != "vtt" {
                    finals.append((vtt, "\(base).\(code).\(vtt.pathExtension)"))
                }
            }
        }

        if choice.thumbnail {
            progress(Progress(stage: .thumbnail, fraction: 1))
            // Old videos have no maxresdefault: step down to the next size.
            let tries = [info.thumbnail].compactMap { $0 } + ["sddefault", "hqdefault"].map { "https://i.ytimg.com/vi/\(info.id)/\($0).jpg" }
            for link in tries {
                guard let url = URL(string: link),
                      let pic = try? await fetchThumbnail(url, to: work.appendingPathComponent("\(info.id).thumb")) else { continue }
                finals.append((pic, base + "." + pic.pathExtension))
                break
            }
        }

        if choice.description, !info.description.isEmpty {
            let txt = work.appendingPathComponent("\(info.id).description.txt")
            let text = "\(info.title)\n\(info.channel)\n\(info.link)\n\n\(info.description)\n"
            try text.write(to: txt, atomically: true, encoding: .utf8)
            finals.append((txt, base + ".txt"))
        }

        // Move into place.
        progress(Progress(stage: .finishing, fraction: 1))
        var target = folder
        if Prefs.folderPerVideo && finals.count > 1 { target = folder.appendingPathComponent(base, isDirectory: true) }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var results: [URL] = []
        for (temp, name) in finals {
            let dest = target.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: temp, to: dest)
            results.append(dest)
        }
        try? fm.removeItem(at: work)
        let snag = folder.appendingPathComponent(".snag")
        if (try? fm.contentsOfDirectory(atPath: snag.path))?.isEmpty == true { try? fm.removeItem(at: snag) }
        return results
    }

    /// The final files a choice would make, to spot "already downloaded".
    static func existing(_ info: VideoInfo, _ choice: Choice, in folder: URL) -> [URL] {
        guard choice.video || choice.audio else { return [] }
        let base = cleanName(info.title)
        let dirs = [folder, folder.appendingPathComponent(base)]
        var found: [URL] = []
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            found += items.filter { $0.deletingPathExtension().lastPathComponent == base }
        }
        let videoOK = !choice.video || found.contains { ["mp4", "mkv", "webm", "mov"].contains($0.pathExtension) }
        let audioOK = !choice.audio || found.contains { $0.pathExtension == Prefs.audioFormat.ext }
        return videoOK && audioOK ? found : []
    }

    // MARK: After the download

    /// VP9 does not play in QuickTime, Photos or Final Cut. Same resolution,
    /// HEVC from the Mac's hardware encoder at a generous bitrate.
    static func toHEVC(_ input: URL, video: VideoInfo.Format, duration: Double, ffmpeg: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = input.deletingLastPathComponent().appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".hevc.mp4")
        try? FileManager.default.removeItem(at: out)
        let floor: Double = video.height >= 2160 ? 45_000 : video.height >= 1440 ? 24_000 : video.height >= 1080 ? 12_000 : 7_000
        let kbps = Int(max(video.bitrate * 1.6, floor * (video.fps > 30 ? 1.3 : 1)))
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-map", "0:v:0", "-map", "0:a?",
                    "-c:v", "hevc_videotoolbox", "-b:v", "\(kbps)k", "-maxrate", "\(kbps * 2)k", "-tag:v", "hvc1",
                    "-c:a", "copy", "-map_metadata", "0", "-map_chapters", "0", "-movflags", "+faststart"]
        if video.isHDR || video.vcodec.hasPrefix("vp09.02") { args += ["-profile:v", "main10", "-pix_fmt", "p010le"] }
        args += ["-progress", "pipe:1", "-nostats", out.path]
        let run = ToolRun(ffmpeg, args)
        let result = try await run.run { line in
            if line.hasPrefix("out_time_us="), duration > 0, let us = Double(line.dropFirst(12)) {
                progress(min(1, us / 1_000_000 / duration))
            }
        }
        if Task.isCancelled { throw CancellationError() }
        guard result.status == 0 else { throw Tools.Failure(message: "Converting for QuickTime failed: " + run.lastError) }
        try? FileManager.default.removeItem(at: input)
        return out
    }

    static func makeAudio(_ input: URL, format: AudioFormat, audio: VideoInfo.Format, info: VideoInfo, ffmpeg: String) async throws -> URL {
        let out = input.deletingLastPathComponent().appendingPathComponent("\(info.id).audio.\(format.ext)")
        try? FileManager.default.removeItem(at: out)
        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-vn", "-map_metadata", "-1",
                    "-metadata", "title=\(info.title)", "-metadata", "artist=\(info.channel)", "-metadata", "comment=\(info.link)"]
        switch format {
        case .original: args += ["-c:a", "copy", "-f", "mp4", "-movflags", "+faststart"]   // Opus or AAC, untouched, in .m4a (plays in QuickTime)
        case .aac: args += ["-c:a", "aac_at", "-b:a", "256k"]
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", "320k"]
        case .flac: args += ["-c:a", "flac"]
        case .wav: args += ["-c:a", "pcm_s16le"]
        }
        args.append(out.path)
        let run = ToolRun(ffmpeg, args)
        let result = try await run.run()
        guard result.status == 0 else { throw Tools.Failure(message: "Making the audio file failed: " + run.lastError) }
        try? FileManager.default.removeItem(at: input)
        return out
    }

    static func fetchThumbnail(_ url: URL, to base: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
        let wanted = Prefs.thumbFormat
        let isJPG = data.starts(with: [0xFF, 0xD8])
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        if (wanted == "jpg" && isJPG) || (wanted == "png" && isPNG) || wanted == "original" {
            let ext = isJPG ? "jpg" : isPNG ? "png" : "webp"
            let out = base.appendingPathExtension(ext)
            try data.write(to: out)
            return out
        }
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            throw URLError(.cannotDecodeContentData)
        }
        let png = wanted == "png"
        guard let encoded = rep.representation(using: png ? .png : .jpeg, properties: png ? [:] : [.compressionFactor: 0.95]) else {
            throw URLError(.cannotDecodeContentData)
        }
        let out = base.appendingPathExtension(png ? "png" : "jpg")
        try encoded.write(to: out)
        return out
    }

    // MARK: Names and messages

    static func cleanName(_ title: String) -> String {
        var s = title
        for ch in ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"] { s = s.replacingOccurrences(of: ch, with: ch == ":" ? " -" : " ") }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 150 { s = String(s.prefix(150)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Video" : s
    }

    static func needsSignIn(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["sign in", "age", "members", "private", "bot", "cookies", "login", "premium", "confirm"].contains { m.contains($0) }
    }

    static func friendly(_ raw: String) -> String {
        let m = raw.lowercased()
        let browser = Prefs.browser?.title ?? "your browser"
        if m.contains("could not find") && m.contains("cookies database") || m.contains("operation not permitted") {
            return "macOS is blocking Snag from reading \(browser)'s sign-in. Turn on Snag in Full Disk Access."
        }
        if m.contains("could not copy") && m.contains("cookie") || m.contains("database is locked") {
            return "Couldn't read \(browser)'s cookies. Quit \(browser) once and try again."
        }
        if m.contains("keyring") || m.contains("safe storage") || m.contains("decrypt") {
            return "macOS didn't allow reading \(browser)'s cookies. Try again and choose Always Allow."
        }
        if m.contains("operation not permitted") && m.contains("safari") {
            return "Safari's cookies need Full Disk Access for Snag (System Settings › Privacy & Security)."
        }
        if m.contains("not a bot") || m.contains("confirm you") {
            return Prefs.browser?.canRead == false
                ? "YouTube wants a signed-in request. Turn on Snag in Full Disk Access so it can use \(browser)'s sign-in."
                : "YouTube wants to check you're not a bot. Sign in to YouTube in \(browser), then try again."
        }
        if m.contains("age") && (m.contains("sign in") || m.contains("confirm")) {
            return "This video is age-restricted. Sign in to YouTube in \(browser) (Settings › Your browser), then try again."
        }
        if m.contains("members") { return "This video is for channel members. Sign in to YouTube in \(browser) with a member account." }
        if m.contains("private video") { return "This video is private." }
        if m.contains("premieres") || m.contains("live event will begin") { return "This video hasn't started yet." }
        if m.contains("unavailable") || m.contains("removed") || m.contains("terminated") { return "This video is unavailable on YouTube." }
        if m.contains("unsupported url") { return "Snag doesn't recognise that link. Paste the address of a video, playlist or channel." }
        if m.contains("http error 429") || m.contains("too many requests") {
            return "YouTube is asking to slow down. Wait a few minutes, then try again."
        }
        if m.contains("no space left") { return "The disk is full." }
        if m.contains("unable to download") && m.contains("network") || m.contains("timed out") || m.contains("internet") {
            return "Network problem. Check your connection and try again."
        }
        let cleaned = raw.replacingOccurrences(of: "ERROR: ", with: "").replacingOccurrences(of: "\\[[^\\]]*\\] ?", with: "", options: .regularExpression)
        return cleaned.isEmpty ? "Something went wrong. Try again." : cleaned
    }
}

/// Turns yt-dlp's per-stream progress into one bar for the whole video
/// (picture and sound are two downloads; the bar must not reach 100% twice).
final class ByteTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [String: Int64] = [:]
    private var done: [String: Int64] = [:]
    private var total: Int64
    private let onUpdate: @Sendable (Progress) -> Void
    private var joining = false
    private var lastSent = Date.distantPast

    init(parts: [VideoInfo.Format], total: Int64, onUpdate: @escaping @Sendable (Progress) -> Void) {
        for p in parts { sizes[p.id] = p.bytes }
        self.total = total
        self.onUpdate = onUpdate
    }

    func line(_ line: String) {
        if line.hasPrefix("[Merger]") || line.hasPrefix("[VideoConvertor]") {
            lock.lock(); joining = true; lock.unlock()
            onUpdate(Progress(stage: .joining, fraction: 1, bytesDone: total, bytesTotal: total))
            return
        }
        if line.hasPrefix("[info] Writing video subtitles") || line.contains("Writing video subtitles") {
            return
        }
        guard line.hasPrefix("SNAGP ") else { return }
        let f = line.split(separator: " ").map(String.init)
        guard f.count >= 5 else { return }
        let id = f[1]
        let got = Int64(Double(f[2]) ?? 0)
        let size = Int64(Double(f[3]) ?? Double(f[4]) ?? 0)
        lock.lock()
        if joining { lock.unlock(); return }
        if size > 0 {
            if sizes[id] == nil || sizes[id] == 0 || abs((sizes[id] ?? 0) - size) > 0 { sizes[id] = size }
            total = max(1, sizes.values.reduce(0, +))
        }
        done[id] = got
        let all = done.reduce(Int64(0)) { $0 + min($1.value, sizes[$1.key] ?? $1.value) }
        let now = Date()
        let send = now.timeIntervalSince(lastSent) > 0.25
        if send { lastSent = now }
        let t = total
        lock.unlock()
        if send {
            onUpdate(Progress(stage: .downloading, fraction: min(1, Double(all) / Double(t)), bytesDone: all, bytesTotal: t))
        }
    }
}
