import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Sign-in", systemImage: "person.crop.circle") { SignInPane() }
            Tab("Quality", systemImage: "sparkles.tv") { QualityPane() }
            Tab("Look", systemImage: "paintpalette") { LookPane() }
            Tab("Engine", systemImage: "engine.combustion") { EnginePane() }
            Tab("Claude", systemImage: "sparkle") { ClaudePane() }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @AppStorage(Prefs.Key.folder) private var folder = ""
    @AppStorage(Prefs.Key.folderPerVideo) private var perVideo = false
    @AppStorage(Prefs.Key.atOnce) private var atOnce = 2
    @AppStorage(Prefs.Key.gentle) private var gentle = true
    @AppStorage(Prefs.Key.notify) private var notify = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Save to") {
                    HStack {
                        Text(Prefs.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: choose)
                    }
                }
                Toggle("Each video in its own folder", isOn: $perVideo)
                Text("Only when a video has more than one file (video, subtitles, thumbnail). Playlists always get their own folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Downloads at once", selection: $atOnce) {
                    Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                Toggle("Short pause between playlist videos", isOn: $gentle)
                Text("A few seconds between videos keeps YouTube from flagging your account for heavy downloading.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify me when a download finishes", isOn: $notify)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.folder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

private struct SignInPane: View {
    @AppStorage(Prefs.Key.browser) private var browser = Browser.brave.rawValue
    @AppStorage(Prefs.Key.cookieMode) private var mode = CookieMode.always.rawValue
    @State private var test: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Picker("Use my YouTube sign-in from", selection: $browser) {
                    ForEach(Browser.installed + [.none]) { b in Text(b.title).tag(b.rawValue) }
                }
                Picker("When", selection: $mode) {
                    ForEach(CookieMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(browser == Browser.none.rawValue)
            } footer: {
                Text("Snag reads the browser's YouTube cookies on this Mac only, the way you're signed in. That unlocks members-only, age-restricted and Premium videos and avoids \"confirm you're not a bot\". Nothing is sent anywhere else.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let b = Browser(rawValue: browser), b != .none {
                Section {
                    LabeledContent("Access") {
                        if b.canRead {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            HStack {
                                Label("Blocked by macOS", systemImage: "lock.fill").foregroundStyle(.orange)
                                Button("Allow…") { NSWorkspace.shared.open(Browser.fullDiskAccessURL) }
                            }
                        }
                    }
                    if !b.canRead {
                        Text("macOS keeps other apps' files private. In Full Disk Access, switch on Snag (if it isn't listed, press + and pick Snag.app), then come back here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = b.note { Label(note, systemImage: "key").font(.callout) }
                }
            }
            Section {
                HStack {
                    Button(testing ? "Checking…" : "Check Sign-in") { check() }.disabled(testing || browser == Browser.none.rawValue)
                    if let test { Text(test).font(.callout).foregroundStyle(.secondary) }
                }
            } footer: {
                Text("Downloading a lot on a signed-in account can get it rate-limited for a while. \"Only when a video needs it\" is the gentlest choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func check() {
        testing = true
        test = nil
        Task {
            guard let ytdlp = Tools.ytdlp else { test = "yt-dlp is missing (see Engine)."; testing = false; return }
            let run = ToolRun(ytdlp, ["--cookies-from-browser", browser, "--simulate", "--no-warnings", "--print", "%(title)s",
                                      "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
            let r = try? await run.run(keepOutput: true)
            if r?.status == 0 { test = "Works: Snag can read \(Browser(rawValue: browser)?.title ?? browser)'s sign-in." }
            else { test = Engine.friendly(run.lastError) }
            testing = false
        }
    }
}

private struct QualityPane: View {
    @AppStorage(Prefs.Key.container) private var container = "mp4"
    @AppStorage(Prefs.Key.vp9) private var vp9 = VP9Rule.convert.rawValue
    @AppStorage(Prefs.Key.hdr) private var hdr = true
    @AppStorage(Prefs.Key.audioFormat) private var audio = AudioFormat.original.rawValue
    @AppStorage(Prefs.Key.subFormat) private var subs = SubFormat.both.rawValue
    @AppStorage(Prefs.Key.thumbFormat) private var thumb = "jpg"
    @AppStorage(Prefs.Key.embed) private var embed = true

    var body: some View {
        Form {
            Section("Video") {
                Picker("File", selection: $container) {
                    Text("MP4 (plays everywhere)").tag("mp4")
                    Text("MKV").tag("mkv")
                }
                Toggle("HDR when the video has it", isOn: $hdr)
                Picker("When the best is only VP9", selection: $vp9) {
                    ForEach(VP9Rule.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Snag always takes the highest resolution and frame rate, preferring AV1, which plays natively on Apple silicon. A few videos have their best only as VP9, which QuickTime can't play; converting keeps full resolution and uses the Mac's hardware encoder.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Add title, chapters and channel to the file", isOn: $embed)
            }
            Section("Other files") {
                Picker("Audio", selection: $audio) { ForEach(AudioFormat.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Subtitles", selection: $subs) { ForEach(SubFormat.allCases) { Text($0.title).tag($0.rawValue) } }
                Picker("Thumbnail", selection: $thumb) {
                    Text("JPG").tag("jpg"); Text("PNG").tag("png"); Text("As YouTube has it").tag("original")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LookPane: View {
    @AppStorage(Prefs.Key.theme) private var theme = Theme.system.rawValue
    @AppStorage(Prefs.Key.look) private var look = WindowLook.glass.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $theme) {
                ForEach(Theme.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Window", selection: $look) {
                ForEach(WindowLook.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Text((WindowLook(rawValue: look) ?? .glass).note + (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? " Reduce Transparency is on, so the window stays solid." : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct EnginePane: View {
    @State private var versions: [String: String] = [:]
    @State private var updating = false
    @State private var log = ""

    var body: some View {
        Form {
            Section {
                row("yt-dlp", "Talks to YouTube", Tools.ytdlp)
                row("ffmpeg", "Joins picture and sound, converts", Tools.ffmpeg)
                row("deno", "Solves YouTube's player challenges", Tools.deno)
            } footer: {
                if Tools.ytdlp == nil || Tools.ffmpeg == nil || Tools.deno == nil {
                    Text("Install what's missing with Homebrew in Terminal:  brew install yt-dlp ffmpeg deno")
                        .font(.caption).textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Button(updating ? "Updating…" : "Update yt-dlp") { update() }.disabled(updating || Tools.ytdlp == nil)
                    if updating { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !log.isEmpty {
                    Text(log).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6)
                }
            } footer: {
                Text("YouTube changes often. When downloads start failing, update first: it usually fixes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await loadVersions() }
    }

    private func row(_ name: String, _ job: String, _ path: String?) -> some View {
        LabeledContent {
            if path != nil {
                Text(versions[name] ?? "…").foregroundStyle(.secondary).monospacedDigit()
            } else {
                Label("Not installed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(job).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadVersions() async {
        for (name, path, args) in [("yt-dlp", Tools.ytdlp, ["--version"]), ("ffmpeg", Tools.ffmpeg, ["-version"]), ("deno", Tools.deno, ["--version"])] {
            guard let path else { continue }
            let r = try? await ToolRun(path, args).run(keepOutput: true)
            var v = r?.output.split(separator: "\n").first.map(String.init) ?? ""
            if name == "ffmpeg" { v = v.components(separatedBy: " ").dropFirst(2).first ?? v }
            if name == "deno" { v = v.components(separatedBy: " ").dropFirst().first ?? v }
            versions[name] = v
        }
    }

    /// Homebrew's yt-dlp refuses its own updater, so Homebrew does it.
    private func update() {
        guard let ytdlp = Tools.ytdlp else { return }
        updating = true
        log = ""
        Task {
            let viaBrew = ytdlp.hasPrefix("/opt/homebrew") || ytdlp.hasPrefix("/usr/local/Cellar") || ytdlp.hasPrefix("/usr/local/bin")
            let run = viaBrew && Tools.brew != nil ? ToolRun(Tools.brew!, ["upgrade", "yt-dlp"]) : ToolRun(ytdlp, ["-U"])
            let r = try? await run.run(keepOutput: true)
            let out = (r?.output ?? "") + "\n" + run.stderrTail.joined(separator: "\n")
            let lines = out.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if r?.status == 0 {
                log = lines.contains(where: { $0.contains("already installed") || $0.contains("up to date") })
                    ? "Already the newest version." : (lines.suffix(3).joined(separator: "\n"))
            } else {
                log = lines.suffix(4).joined(separator: "\n")
            }
            await loadVersions()
            updating = false
        }
    }
}

/// Lets Claude use Snag: registers snag-mcp (inside this app) with
/// Claude Code (`claude mcp add`) and, when installed, the Claude app.
private struct ClaudePane: View {
    @State private var code: Bool?
    @State private var desktop: Bool?
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code") { status(code, available: ClaudeLink.cli != nil) }
                if ClaudeLink.desktopInstalled {
                    LabeledContent("Claude app") { status(desktop, available: true) }
                }
                HStack {
                    Button(connected ? "Connect Again" : "Connect") { act(connect: true) }.disabled(busy)
                    if connected { Button("Disconnect") { act(connect: false) }.disabled(busy) }
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Claude can then look up videos, download them (they show up here in Downloads), check progress and read a video's transcript. Try: \"use Snag to download this in 4K with English subtitles\" or \"summarise this video with Snag\". If you move Snag.app, press Connect Again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private var connected: Bool { code == true || desktop == true }

    @ViewBuilder private func status(_ on: Bool?, available: Bool) -> some View {
        if !available { Text("Not installed").foregroundStyle(.secondary) }
        else if let on {
            Label(on ? "Connected" : "Not connected", systemImage: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
        } else { ProgressView().controlSize(.small) }
    }

    private func refresh() async {
        code = await ClaudeLink.codeConnected()
        desktop = ClaudeLink.desktopConnected()
    }

    private func act(connect: Bool) {
        busy = true
        Task {
            message = connect ? await ClaudeLink.connect() : await ClaudeLink.disconnect()
            await refresh()
            busy = false
        }
    }
}

enum ClaudeLink {
    static var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/snag-mcp").path }
    static var cli: String? {
        [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", NSHomeDirectory() + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var desktopConfig: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json")
    }
    static var desktopInstalled: Bool {
        FileManager.default.fileExists(atPath: desktopConfig.deletingLastPathComponent().path)
    }

    static func codeConnected() async -> Bool {
        guard let cli else { return false }
        let run = ToolRun(cli, ["mcp", "get", "snag"])
        let r = try? await run.run(keepOutput: true)
        return r?.status == 0 && (r?.output.contains("snag-mcp") ?? false)
    }

    static func desktopConnected() -> Bool {
        guard let data = try? Data(contentsOf: desktopConfig),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = j["mcpServers"] as? [String: Any] else { return false }
        return servers["snag"] != nil
    }

    static func connect() async -> String {
        var done: [String] = []
        var problems: [String] = []
        if let cli {
            _ = try? await ToolRun(cli, ["mcp", "remove", "--scope", "user", "snag"]).run()
            let run = ToolRun(cli, ["mcp", "add", "--scope", "user", "snag", "--", helper])
            let r = try? await run.run(keepOutput: true)
            if r?.status == 0 { done.append("Claude Code") } else { problems.append("Claude Code: " + run.lastError) }
        }
        if desktopInstalled {
            if editDesktop({ $0["snag"] = ["command": helper, "args": [String]()] }) { done.append("the Claude app (restart it)") }
            else { problems.append("Couldn't update the Claude app's settings file.") }
        }
        if done.isEmpty && problems.isEmpty { return "Neither Claude Code nor the Claude app was found on this Mac." }
        return (done.isEmpty ? "" : "Connected to " + done.joined(separator: " and ") + ". ") + problems.joined(separator: " ")
    }

    static func disconnect() async -> String {
        if let cli { _ = try? await ToolRun(cli, ["mcp", "remove", "--scope", "user", "snag"]).run() }
        if desktopInstalled { _ = editDesktop { $0["snag"] = nil } }
        return "Disconnected."
    }

    /// Changes only the "snag" entry, keeping everything else in the file.
    private static func editDesktop(_ change: (inout [String: Any]) -> Void) -> Bool {
        var j: [String: Any] = [:]
        if let data = try? Data(contentsOf: desktopConfig) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            j = parsed
        }
        var servers = j["mcpServers"] as? [String: Any] ?? [:]
        change(&servers)
        j["mcpServers"] = servers
        guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
        return (try? out.write(to: desktopConfig, options: .atomic)) != nil
    }
}
