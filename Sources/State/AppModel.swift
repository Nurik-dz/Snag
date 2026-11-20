import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable { case idle, looking, found, failed(String) }

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleLookup()
        }
    }
    private(set) var phase: Phase = .idle
    private(set) var found: VideoInfo?
    var choice = Choice()
    /// A watch link inside a playlist: just the video unless this is on.
    var wholePlaylist = false {
        didSet { if wholePlaylist != oldValue { scheduleLookup(immediately: true) } }
    }
    private(set) var records: [Record] = []
    private(set) var speeds: [UUID: String] = [:]
    private(set) var alreadyHave: [URL] = []
    /// The chosen browser's sign-in is unreadable until Full Disk Access.
    private(set) var accessBlocked = false

    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var infos: [UUID: VideoInfo] = [:]
    @ObservationIgnored private var samples: [UUID: [(Date, Int64)]] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var lastProgressSave = Date.distantPast

    // MARK: - Start

    func launch() {
        guard !launched else { return }
        launched = true
        Prefs.register()
        AppearanceModel.shared.start()
        Notifier.shared.setUp()
        records = History.load()
        checkAccess()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.checkAccess() }
        }
        // Anything cut off by a quit waits to be resumed (its parts are kept).
        for i in records.indices where records[i].isActive {
            records[i].state = .paused
            records[i].stage = "Stopped when Snag quit"
        }
        restoreChoice()
    }

    private func restoreChoice() {
        let d = UserDefaults.standard
        choice.video = d.bool(forKey: Prefs.Key.wantVideo)
        choice.audio = d.bool(forKey: Prefs.Key.wantAudio)
        choice.thumbnail = d.bool(forKey: Prefs.Key.wantThumb)
        choice.description = d.bool(forKey: Prefs.Key.wantDescription)
        choice.hdr = Prefs.hdr
    }

    var wantSubtitles: Bool {
        get { UserDefaults.standard.bool(forKey: Prefs.Key.wantSubs) }
        set {
            UserDefaults.standard.set(newValue, forKey: Prefs.Key.wantSubs)
            if newValue { choice.subtitles = found?.defaultSubtitles ?? [] } else { choice.subtitles = [] }
            if found?.isPlaylist == true { choice.subtitles = newValue ? ["*"] : [] }
            checkExisting()
        }
    }

    func setVideo(_ on: Bool) { choice.video = on; UserDefaults.standard.set(on, forKey: Prefs.Key.wantVideo); checkExisting() }
    func setAudio(_ on: Bool) { choice.audio = on; UserDefaults.standard.set(on, forKey: Prefs.Key.wantAudio); checkExisting() }
    func setThumb(_ on: Bool) { choice.thumbnail = on; UserDefaults.standard.set(on, forKey: Prefs.Key.wantThumb) }
    func setDescription(_ on: Bool) { choice.description = on; UserDefaults.standard.set(on, forKey: Prefs.Key.wantDescription) }
    func setHeight(_ h: Int?) { choice.height = h }
    func setHDR(_ on: Bool) { choice.hdr = on }

    func toggleSubtitle(_ id: String) {
        if choice.subtitles.contains(id) { choice.subtitles.remove(id) } else { choice.subtitles.insert(id) }
        if choice.subtitles.isEmpty { UserDefaults.standard.set(false, forKey: Prefs.Key.wantSubs) }
        else { UserDefaults.standard.set(true, forKey: Prefs.Key.wantSubs) }
    }

    // MARK: - Link

    func clear() {
        lookupTask?.cancel()
        text = ""
        found = nil
        phase = .idle
        wholePlaylist = false
    }

    private func scheduleLookup(immediately: Bool = false) {
        lookupTask?.cancel()
        alreadyHave = []
        guard let link = Link.normalized(text) else {
            found = nil
            phase = text.trimmingCharacters(in: .whitespaces).isEmpty ? .idle : .failed("That doesn't look like a link. Paste the address of a video, playlist or channel.")
            return
        }
        if found?.link != link { found = nil }
        phase = .looking
        let whole = wholePlaylist || !Link.hasVideo(link)
        lookupTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            do {
                let info = try await Engine.lookup(link, wholePlaylist: whole)
                guard !Task.isCancelled else { return }
                found = info
                choice.height = nil
                choice.hdr = Prefs.hdr
                choice.subtitles = UserDefaults.standard.bool(forKey: Prefs.Key.wantSubs)
                    ? (info.isPlaylist ? ["*"] : info.defaultSubtitles) : []
                phase = .found
                checkExisting()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                found = nil
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func checkExisting() {
        guard let found, !found.isPlaylist else { alreadyHave = []; return }
        alreadyHave = Engine.existing(found, choice, in: Prefs.folder)
    }

    var linkHasPlaylist: Bool {
        guard let link = Link.normalized(text) else { return false }
        return Link.hasVideo(link) && Link.hasPlaylist(link)
    }

    /// Estimated size of what is chosen.
    var estimate: Int64 {
        guard let found, !found.isPlaylist else { return 0 }
        var total: Int64 = 0
        let v = choice.video ? found.pickVideo(height: choice.height, hdr: choice.hdr) : nil
        if let v { total += v.bytes }
        if (choice.video && !(v?.hasAudio ?? false)) || choice.audio { total += found.pickAudio()?.bytes ?? 0 }
        return total
    }

    // MARK: - Downloads

    func download() {
        guard let info = found, phase == .found, !choice.isEmpty else { return }
        var r = Record(videoID: info.id, title: info.title, channel: info.channel, link: info.link,
                       thumbnail: info.isPlaylist ? (info.entries.first.map { "https://i.ytimg.com/vi/\($0.id)/mqdefault.jpg" } ?? info.thumbnail)
                                                  : "https://i.ytimg.com/vi/\(info.id)/mqdefault.jpg",
                       duration: info.duration, choice: choice, quality: qualityText(info))
        if info.isPlaylist {
            r.isPlaylist = true
            r.entries = info.entries
        } else {
            infos[r.id] = info
            r.bytesTotal = estimate
        }
        records.insert(r, at: 0)
        clear()
        save()
        pump()
    }

    /// A download asked for from outside the window (Claude, through
    /// snag://add). It shows up in Downloads like any other.
    func enqueue(link: String, choice: Choice, whole: Bool) {
        guard let link = Link.normalized(link) else { return }
        var r = Record(videoID: "", title: link, channel: "", link: link, thumbnail: nil, duration: 0, choice: choice, quality: "")
        r.isPlaylist = whole || !Link.hasVideo(link)
        if r.isPlaylist {
            r.quality = choice.video ? (choice.height.map { "Up to \($0)p" } ?? "Best quality") : ""
            if r.choice.subtitles.contains(where: { $0.hasPrefix("lang:") }) { r.choice.subtitles = ["*"] }
        }
        records.insert(r, at: 0)
        save()
        pump()
    }

    static func estimate(_ info: VideoInfo, _ choice: Choice) -> Int64 {
        var total: Int64 = 0
        let v = choice.video ? info.pickVideo(height: choice.height, hdr: choice.hdr) : nil
        if let v { total += v.bytes }
        if (choice.video && !(v?.hasAudio ?? false)) || choice.audio { total += info.pickAudio()?.bytes ?? 0 }
        return total
    }

    static func quality(_ info: VideoInfo, _ choice: Choice) -> String {
        var parts: [String] = []
        if choice.video, let v = info.pickVideo(height: choice.height, hdr: choice.hdr) {
            parts.append(VideoInfo.Quality(height: v.height, fps: v.fps, hdr: v.isHDR).label + (v.isHDR ? " HDR" : ""))
            parts.append(v.isVP9 && Prefs.vp9 == .convert ? "HEVC" : v.codecName)
        }
        if choice.audio { parts.append(Prefs.audioFormat.short + " audio") }
        if !choice.video && !choice.audio {
            if !choice.subtitles.isEmpty { parts.append("Subtitles") }
            if choice.thumbnail { parts.append("Thumbnail") }
        }
        return parts.joined(separator: " · ")
    }

    func qualityText(_ info: VideoInfo) -> String {
        var parts: [String] = []
        if choice.video {
            if info.isPlaylist {
                parts.append(choice.height.map { "Up to \($0)p" } ?? "Best quality")
            } else if let v = info.pickVideo(height: choice.height, hdr: choice.hdr) {
                var q = VideoInfo.Quality(height: v.height, fps: v.fps, hdr: v.isHDR).label
                if v.isHDR { q += " HDR" }
                parts.append(q)
                parts.append(v.isVP9 && Prefs.vp9 == .convert ? "HEVC" : v.codecName)
            }
        }
        if choice.audio { parts.append(Prefs.audioFormat.short + " audio") }
        if !choice.video && !choice.audio {
            if !choice.subtitles.isEmpty { parts.append("Subtitles") }
            if choice.thumbnail { parts.append("Thumbnail") }
        }
        return parts.joined(separator: " · ")
    }

    private func pump() {
        let running = records.filter { $0.state == .working }.count
        var free = Prefs.atOnce - running
        for r in records.reversed() where r.state == .queued && free > 0 && tasks[r.id] == nil {
            free -= 1
            start(r.id)
        }
        updateDock()
    }

    private func start(_ id: UUID) {
        update(id) { $0.state = .working; $0.stage = "Getting ready"; $0.error = nil }
        tasks[id] = Task { [weak self] in
            await self?.run(id)
            self?.tasks[id] = nil
            self?.pump()
        }
    }

    private func run(_ id: UUID) async {
        guard let r = record(id) else { return }
        let folder = Prefs.folder
        do {
            if r.isPlaylist && r.entries.isEmpty {
                update(id) { $0.stage = "Looking up the playlist" }
                let list = try await Engine.lookup(r.link, wholePlaylist: true)
                update(id) {
                    $0.title = list.title
                    $0.channel = list.channel
                    $0.entries = list.entries
                    $0.isPlaylist = list.isPlaylist
                    if let first = list.entries.first { $0.thumbnail = "https://i.ytimg.com/vi/\(first.id)/mqdefault.jpg" }
                }
                if !list.isPlaylist { infos[id] = list }
            }
            guard let r = record(id) else { return }
            if r.isPlaylist {
                try await runPlaylist(id, folder: folder.appendingPathComponent(Engine.cleanName(r.title), isDirectory: true))
            } else {
                var info = infos[id]
                if info == nil {
                    update(id) { $0.stage = "Looking up the video" }
                    info = try await Engine.lookup(r.link, wholePlaylist: false)
                    infos[id] = info
                }
                let found = info!
                update(id) {
                    $0.title = found.title
                    $0.channel = found.channel
                    $0.videoID = found.id
                    $0.thumbnail = "https://i.ytimg.com/vi/\(found.id)/mqdefault.jpg"
                    if $0.quality.isEmpty { $0.quality = Self.quality(found, $0.choice) }
                    if $0.bytesTotal == 0 { $0.bytesTotal = Self.estimate(found, $0.choice) }
                }
                let report: @Sendable (Progress) -> Void = { [weak self] p in
                    Task { @MainActor in self?.apply(p, to: id) }
                }
                var files: [URL]
                do {
                    files = try await Engine.download(found, r.choice.resolved(for: found), into: folder, progress: report)
                } catch where !Task.isCancelled && "\(error.localizedDescription)".contains("403") {
                    // YouTube's stream links go stale: fresh lookup, one more try.
                    update(id) { $0.stage = "YouTube refused the link, trying again" }
                    let fresh = try await Engine.lookup(r.link, wholePlaylist: false)
                    infos[id] = fresh
                    files = try await Engine.download(fresh, r.choice.resolved(for: fresh), into: folder, progress: report)
                }
                finish(id, files: files)
            }
        } catch is CancellationError {
            update(id) { if $0.state == .working { $0.state = .paused; $0.stage = "Paused" } }
        } catch {
            if Task.isCancelled {
                update(id) { if $0.state == .working { $0.state = .paused; $0.stage = "Paused" } }
            } else {
                update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
        }
        speeds[id] = nil
        samples[id] = nil
        save()
        updateDock()
    }

    private func runPlaylist(_ id: UUID, folder: URL) async throws {
        guard let r = record(id) else { return }
        let todo = r.entries.filter { !r.doneIDs.contains($0.id) }
        var first = true
        for entry in todo {
            try Task.checkCancellation()
            // A short pause between videos keeps YouTube (and your account) calm.
            if Prefs.gentle && !first {
                update(id) { $0.stage = "Short pause before the next video" }
                try await Task.sleep(for: .seconds(Double.random(in: 3...7)))
            }
            first = false
            guard let now = record(id) else { return }
            let index = now.doneIDs.count + now.failedIDs.count + 1
            update(id) {
                $0.stage = "\(index) of \($0.entries.count) · \(entry.title)"
                $0.thumbnail = "https://i.ytimg.com/vi/\(entry.id)/mqdefault.jpg"
            }
            do {
                let info = try await Engine.lookup("https://www.youtube.com/watch?v=\(entry.id)", wholePlaylist: false)
                let c = now.choice.resolved(for: info)
                let count = Double(now.entries.count)
                let done = Double(now.doneIDs.count + now.failedIDs.count)
                let files = try await Engine.download(info, c, into: folder) { [weak self] p in
                    Task { @MainActor in
                        self?.update(id) { $0.fraction = (done + p.fraction) / count }
                        self?.trackSpeed(id, p)
                    }
                }
                update(id) {
                    $0.doneIDs.append(entry.id)
                    $0.files += files.map(\.path)
                    $0.fraction = Double($0.doneIDs.count + $0.failedIDs.count) / count
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                update(id) { $0.failedIDs.append(entry.id) }
            }
            save()
        }
        guard let end = record(id) else { return }
        update(id) {
            $0.state = .done
            $0.fraction = 1
            $0.stage = ""
            $0.error = end.failedIDs.isEmpty ? nil : "\(end.failedIDs.count) of \(end.entries.count) couldn't be downloaded (private, removed or members-only)."
        }
        Notifier.shared.post(title: "Playlist downloaded", body: "\(end.doneIDs.count) videos · \(end.title)", file: folder)
    }

    private func finish(_ id: UUID, files: [URL]) {
        var total: Int64 = 0
        for f in files { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        update(id) {
            $0.state = .done
            $0.fraction = 1
            $0.stage = ""
            $0.files = files.map(\.path)
            $0.bytesTotal = total
        }
        infos[id] = nil
        if let r = record(id) { Notifier.shared.post(title: "Downloaded", body: r.title, file: r.mainFile) }
    }

    private func apply(_ p: Progress, to id: UUID) {
        guard let r = record(id), r.state == .working else { return }
        // Claude reads progress from the saved list: keep it fresh.
        if Date().timeIntervalSince(lastProgressSave) > 2 { lastProgressSave = Date(); save() }
        update(id) {
            $0.stage = p.stage == .downloading ? "" : (p.detail.isEmpty ? p.stage.rawValue : "\(p.stage.rawValue) · \(p.detail)")
            if p.stage == .downloading || p.stage == .converting { $0.fraction = p.stage == .converting ? p.fraction : p.fraction }
            if p.bytesTotal > 1 { $0.bytesTotal = p.bytesTotal }
        }
        trackSpeed(id, p)
    }

    /// Speed and time left from the last minute, never from the start.
    private func trackSpeed(_ id: UUID, _ p: Progress) {
        guard p.stage == .downloading else { speeds[id] = nil; samples[id] = nil; return }
        let now = Date()
        var list = samples[id] ?? []
        if let last = list.last, p.bytesDone < last.1 { list = [] }
        list.append((now, p.bytesDone))
        list.removeAll { now.timeIntervalSince($0.0) > 60 }
        samples[id] = list
        guard let first = list.first, now.timeIntervalSince(first.0) >= 2 else { return }
        let rate = Double(p.bytesDone - first.1) / now.timeIntervalSince(first.0)
        guard rate > 0 else { return }
        var text = Format.bytes(Int64(rate)) + "/s"
        if p.bytesTotal > p.bytesDone, record(id)?.isPlaylist == false {
            text += " · " + Format.left(Double(p.bytesTotal - p.bytesDone) / rate)
        }
        speeds[id] = text
        updateDock()
    }

    func pause(_ id: UUID) {
        if let t = tasks[id] { t.cancel() }
        update(id) { if $0.state == .queued { $0.state = .paused; $0.stage = "Paused" } }
        save()
    }

    func resume(_ id: UUID) {
        update(id) { $0.state = .queued; $0.stage = "Waiting"; $0.error = nil; $0.failedIDs = [] }
        pump()
    }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        records.removeAll { $0.id == id }
        infos[id] = nil
        save()
        updateDock()
    }

    func clearFinished() {
        records.removeAll { $0.state == .done }
        save()
    }

    // MARK: - Helpers

    func record(_ id: UUID) -> Record? { records.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Record) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        var r = records[i]
        change(&r)
        if r != records[i] { records[i] = r }
    }

    private func save() {
        saveTask?.cancel()
        let snapshot = records
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            History.save(snapshot)
        }
    }

    func saveNow() { History.save(records) }

    private func updateDock() {
        let active = records.filter { $0.state == .working }
        let fraction = active.isEmpty ? nil : active.map(\.fraction).reduce(0, +) / Double(active.count)
        DockProgress.shared.update(progress: fraction, active: records.filter(\.isActive).count)
    }

    func reveal(_ r: Record) {
        let urls = r.files.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { NSWorkspace.shared.open(Prefs.folder) } else { NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(20))) }
    }

    func open(_ r: Record) {
        if let f = r.mainFile, FileManager.default.fileExists(atPath: f.path) { NSWorkspace.shared.open(f) } else { reveal(r) }
    }

    func checkAccess() {
        let blocked = Prefs.cookieMode != .never && (Prefs.browser.map { $0 != .none && !$0.canRead } ?? false)
        if blocked != accessBlocked {
            accessBlocked = blocked
            // Just allowed: look the current link up again, signed in.
            if !blocked, found != nil { scheduleLookup(immediately: true) }
        }
    }

    func openAccessSettings() { NSWorkspace.shared.open(Browser.fullDiskAccessURL) }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Prefs.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.folder)
    }

    func copyLink(_ r: Record) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.link, forType: .string)
    }
}

#if HARNESS
extension AppModel {
    /// Snapshot harness only: put the window into a given state.
    func showSample(text: String, phase: Phase, found: VideoInfo?, records: [Record], speeds: [UUID: String] = [:]) {
        self.launched = true
        self.lookupTask?.cancel()
        self.records = records
        self.speeds = speeds
        self.found = found
        if let found { self.choice.subtitles = found.defaultSubtitles }
        self.phase = phase
        self.text = text
        self.lookupTask?.cancel()
        self.phase = phase
        self.found = found
    }
}
#endif
