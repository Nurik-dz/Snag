import Foundation

// snag-mcp: lets Claude use Snag. An MCP server over stdio (newline-delimited
// JSON-RPC, no SDK). It lives inside Snag.app/Contents/MacOS, so it shares the
// app's settings (browser sign-in, folder, formats) and its Downloads list.
//
// Tools: snag_lookup, snag_download (queued in the Snag window), snag_status,
// snag_transcript (subtitles as text, straight into the conversation).

Prefs.register()
setvbuf(stdout, nil, _IOLBF, 0)

let outLock = NSLock()
func send(_ obj: [String: Any]) {
    outLock.lock(); defer { outLock.unlock() }
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func text(_ s: String, error: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": error]
}

struct ToolError: Error { var message: String }

// MARK: - Tools

typealias Handler = ([String: Any]) async throws -> String

struct Tool {
    var name: String
    var description: String
    var schema: [String: Any]
    var run: Handler
}

func str(_ a: [String: Any], _ k: String) -> String? { (a[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
func bool(_ a: [String: Any], _ k: String, _ d: Bool) -> Bool { (a[k] as? Bool) ?? d }

func linkArg(_ a: [String: Any]) throws -> String {
    guard let raw = str(a, "link"), let link = Link.normalized(raw) else {
        throw ToolError(message: "Give a YouTube link (video, Short, playlist or channel), a video ID or an @handle.")
    }
    return link
}

let tools: [Tool] = [
    Tool(name: "snag_lookup",
         description: "Look up a YouTube video, Short, playlist or channel with Snag (signed in through the user's browser). Returns title, channel, length, every quality on offer with sizes and codecs, the best audio, subtitle languages, and for playlists the list of videos.",
         schema: ["type": "object", "properties": [
            "link": ["type": "string", "description": "YouTube link, video ID or @handle"],
            "whole_playlist": ["type": "boolean", "description": "For a watch link that is inside a playlist: look up the whole playlist instead of the one video. Default false."],
         ], "required": ["link"]],
         run: { a in
            let link = try linkArg(a)
            let info = try await Engine.lookup(link, wholePlaylist: bool(a, "whole_playlist", false))
            return describe(info)
         }),

    Tool(name: "snag_download",
         description: "Download from YouTube with Snag at the best quality (or a chosen maximum height). The download is added to the Snag app's Downloads list, where the user sees its progress; Snag opens if it is closed. Files go to the user's Snag folder. Use snag_status to follow it.",
         schema: ["type": "object", "properties": [
            "link": ["type": "string", "description": "YouTube link, video ID, playlist or channel"],
            "video": ["type": "boolean", "description": "Video with sound (default true)"],
            "audio": ["type": "boolean", "description": "A separate audio file in the user's chosen audio format (default false)"],
            "subtitles": ["type": "string", "description": "\"default\" (the video's own language, people's subtitles first, else automatic), \"none\", or comma-separated language codes such as \"en,de\". Default: \"default\"."],
            "thumbnail": ["type": "boolean", "description": "Full-size thumbnail (default true)"],
            "description": ["type": "boolean", "description": "The video description as .txt (default false)"],
            "max_height": ["type": "integer", "description": "Highest resolution wanted, e.g. 1080. Leave out for the best there is."],
            "whole_playlist": ["type": "boolean", "description": "For a watch link inside a playlist: download the whole playlist. Playlist and channel links always download everything."],
         ], "required": ["link"]],
         run: { a in
            let link = try linkArg(a)
            var c = Choice()
            c.video = bool(a, "video", true)
            c.audio = bool(a, "audio", false)
            c.thumbnail = bool(a, "thumbnail", true)
            c.description = bool(a, "description", false)
            c.hdr = Prefs.hdr
            if let h = a["max_height"] as? Int, h > 0 { c.height = h }
            let subs = (str(a, "subtitles") ?? "default").lowercased()
            if subs == "default" { c.subtitles = ["*"] }
            else if subs != "none" {
                c.subtitles = Set(subs.split(separator: ",").map { "lang:" + $0.trimmingCharacters(in: .whitespaces) })
            }
            if c.isEmpty { throw ToolError(message: "Nothing to download: switch on at least one of video, audio, subtitles, thumbnail.") }
            let whole = bool(a, "whole_playlist", false)
            let req = AddRequest(link: link, choice: c, whole: whole)
            let payload = try JSONEncoder().encode(req).base64URL
            try openInApp("snag://add?d=" + payload)
            var what: [String] = []
            if c.video { what.append(c.height.map { "video up to \($0)p" } ?? "video at the best quality") }
            if c.audio { what.append("audio (\(Prefs.audioFormat.title))") }
            if !c.subtitles.isEmpty { what.append(subs == "default" ? "subtitles in the video's language" : "subtitles (\(subs))") }
            if c.thumbnail { what.append("thumbnail") }
            if c.description { what.append("description") }
            return "Queued in Snag: \(what.joined(separator: ", ")).\nLink: \(link)\nFolder: \(Prefs.folder.path)\nThe user can watch it in Snag's window. Call snag_status to see progress and the finished files."
         }),

    Tool(name: "snag_status",
         description: "What Snag is downloading and has downloaded: state, progress, speed, errors and the file paths of finished downloads (newest first).",
         schema: ["type": "object", "properties": [
            "limit": ["type": "integer", "description": "How many entries (default 10)"],
         ]],
         run: { a in
            let limit = (a["limit"] as? Int) ?? 10
            let records = History.load()
            if records.isEmpty { return "Snag's Downloads list is empty." }
            return records.prefix(max(1, limit)).map(describe).joined(separator: "\n\n")
         }),

    Tool(name: "snag_transcript",
         description: "Get a YouTube video's subtitles as text, straight into the conversation (nothing saved). People's subtitles first, else YouTube's automatic captions, cleaned so each line appears once. Good for summarising, quoting or finding moments.",
         schema: ["type": "object", "properties": [
            "link": ["type": "string", "description": "YouTube link or video ID"],
            "language": ["type": "string", "description": "Language code such as en or de. Default: the video's own language."],
            "timestamps": ["type": "boolean", "description": "Start each line with [m:ss] (default true)"],
            "format": ["type": "string", "enum": ["text", "srt"], "description": "Plain lines (default) or the full SRT"],
         ], "required": ["link"]],
         run: { a in
            let link = try linkArg(a)
            return try await transcript(link, language: str(a, "language"), stamps: bool(a, "timestamps", true), srt: str(a, "format") == "srt")
         }),
]

// MARK: - Helpers

func describe(_ info: VideoInfo) -> String {
    var lines: [String] = []
    if info.isPlaylist {
        lines.append("Playlist: \(info.title)")
        if !info.channel.isEmpty { lines.append("Channel: \(info.channel)") }
        lines.append("Videos: \(info.entries.count)")
        for (i, e) in info.entries.prefix(50).enumerated() {
            lines.append("\(i + 1). \(e.title) [\(e.id)]" + (e.duration > 0 ? " \(clock(e.duration))" : ""))
        }
        if info.entries.count > 50 { lines.append("… and \(info.entries.count - 50) more") }
        return lines.joined(separator: "\n")
    }
    lines.append("Title: \(info.title)")
    lines.append("Channel: \(info.channel)")
    lines.append("Length: \(clock(info.duration))")
    lines.append("Link: \(info.link)")
    if info.isLive { lines.append("Live now (can be saved once it ends)") }
    lines.append("Signed in: \(info.usedCookies ? "yes (\(Prefs.browser?.title ?? "browser"))" : "no")")
    lines.append("Qualities:")
    for q in info.qualities {
        if let v = info.pickVideo(height: q.height, hdr: Prefs.hdr) {
            let a = v.hasAudio ? 0 : (info.pickAudio()?.bytes ?? 0)
            lines.append("  \(q.label)\(v.isHDR ? " HDR" : "") · \(v.codecName) · about \(bytes(v.bytes + a))")
        }
    }
    if let au = info.pickAudio() { lines.append("Best audio: \(au.audioName) \(Int(au.bitrate.rounded())) kbps, about \(bytes(au.bytes))") }
    if info.subtitles.isEmpty { lines.append("Subtitles: none") } else {
        lines.append("Subtitles: " + info.subtitles.map { "\($0.name) (\($0.code)\($0.auto ? ", automatic" : ""))" }.joined(separator: "; "))
    }
    if !info.description.isEmpty { lines.append("Description:\n" + String(info.description.prefix(1500))) }
    return lines.joined(separator: "\n")
}

func describe(_ r: Record) -> String {
    var lines = ["\(r.title)" + (r.isPlaylist ? " (playlist, \(r.entries.count) videos)" : "")]
    switch r.state {
    case .working:
        lines.append("Downloading: \(Int(r.fraction * 100))%" + (r.stage.isEmpty ? "" : " · \(r.stage)"))
    case .queued: lines.append("Waiting in the queue")
    case .paused: lines.append("Paused at \(Int(r.fraction * 100))% (the user can resume in Snag)")
    case .done: lines.append("Done" + (r.error.map { " · " + $0 } ?? ""))
    case .failed: lines.append("Failed: " + (r.error ?? "unknown error"))
    }
    if !r.quality.isEmpty { lines.append("Quality: \(r.quality)") }
    lines.append("Link: \(r.link)")
    if r.state == .done {
        let files = r.files.prefix(r.isPlaylist ? 8 : 30)
        lines.append("Files:\n" + files.map { "  " + $0 }.joined(separator: "\n") + (r.files.count > files.count ? "\n  … \(r.files.count - files.count) more" : ""))
    }
    return lines.joined(separator: "\n")
}

func clock(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

/// Hands work to the app (opens it in the background if needed).
func openInApp(_ url: String) throws {
    // This helper sits in Snag.app/Contents/MacOS.
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = app.pathExtension == "app" ? ["-g", "-a", app.path, url] : ["-g", url]
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw ToolError(message: "Couldn't reach the Snag app (open failed). Is Snag.app still in \(app.deletingLastPathComponent().path)?") }
}

func transcript(_ link: String, language: String?, stamps: Bool, srt: Bool) async throws -> String {
    let info = try await Engine.lookup(link, wholePlaylist: false)
    if info.isPlaylist { throw ToolError(message: "That is a playlist. Ask for one video's transcript at a time.") }
    var choice = Choice()
    choice.video = false; choice.audio = false; choice.thumbnail = false
    choice.subtitles = language.map { ["lang:" + $0] } ?? ["*"]
    choice = choice.resolved(for: info)
    guard let id = choice.subtitles.first, let sub = info.subtitles.first(where: { $0.id == id }) else {
        let have = info.subtitles.map(\.code).joined(separator: ", ")
        throw ToolError(message: info.subtitles.isEmpty ? "This video has no subtitles or automatic captions." : "No subtitles in that language. Available: \(have)")
    }
    guard let ytdlp = Tools.ytdlp else { throw Tools.Missing(tool: "yt-dlp") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snag-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var args = ["--skip-download", "--no-playlist", "--no-warnings", "-P", dir.path, "-o", "t.%(ext)s",
                "--sub-langs", sub.code, "--sub-format", "vtt/best", sub.auto ? "--write-auto-subs" : "--write-subs"]
    args += Engine.cookieArgs
    let run = ToolRun(ytdlp, args + [info.link])
    let r = try await run.run()
    guard r.status == 0,
          let file = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "vtt" }),
          let vtt = try? String(contentsOf: file, encoding: .utf8)
    else { throw ToolError(message: Engine.friendly(run.lastError)) }
    let cleaned = SubtitleConverter.srt(fromVTT: vtt)
    let head = "\(info.title) — \(info.channel) (\(clock(info.duration)))\nSubtitles: \(sub.name)\(sub.auto ? " (automatic captions)" : "")\n\n"
    if srt { return head + cleaned }
    var out: [String] = []
    for block in cleaned.components(separatedBy: "\n\n") {
        let lines = block.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { continue }
        let body = lines[2...].joined(separator: " ")
        if stamps {
            let start = lines[1].components(separatedBy: " --> ")[0]
            let p = start.split(separator: ":")
            let secs = p.count == 3 ? (Int(p[0]) ?? 0) * 3600 + (Int(p[1]) ?? 0) * 60 + Int(Double(p[2].replacingOccurrences(of: ",", with: ".")) ?? 0) : 0
            out.append("[\(clock(Double(secs)))] \(body)")
        } else { out.append(body) }
    }
    return head + out.joined(separator: stamps ? "\n" : " ")
}

// MARK: - JSON-RPC loop

let instructions = """
Snag is the user's YouTube downloader on this Mac. It downloads at the best quality YouTube has (4K, HDR, AV1), signed in through the user's browser, with subtitles (SRT/VTT) and thumbnails. \
Use snag_lookup to see what a link offers, snag_download to save something (it appears in the Snag window), snag_status to follow downloads and find the files, and snag_transcript to read a video's subtitles without saving anything.
"""

func handle(_ msg: [String: Any]) async {
    let method = msg["method"] as? String ?? ""
    let id = msg["id"]
    guard let id else { return }   // notifications need no answer
    switch method {
    case "initialize":
        let params = msg["params"] as? [String: Any] ?? [:]
        send(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "snag", "version": "1.0"],
            "instructions": instructions,
        ]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [:]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools.map {
            ["name": $0.name, "description": $0.description, "inputSchema": $0.schema]
        }]])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool \(name)"]])
            return
        }
        do {
            let out = try await tool.run(args)
            send(["jsonrpc": "2.0", "id": id, "result": text(out)])
        } catch let e as ToolError {
            send(["jsonrpc": "2.0", "id": id, "result": text(e.message, error: true)])
        } catch {
            send(["jsonrpc": "2.0", "id": id, "result": text(error.localizedDescription, error: true)])
        }
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
    }
}

let group = DispatchGroup()
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    group.enter()
    Task { await handle(msg); group.leave() }
}
group.wait()
