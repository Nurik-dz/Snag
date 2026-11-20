import Foundation
// snag-test-engine: lookup + download against the real YouTube.
// usage: snag-test-engine <link> <outdir> [video,audio,subs,thumb,desc] [height] [playlist]
let a = CommandLine.arguments
Prefs.register()
UserDefaults.standard.set(a.count > 5 && a[5] == "keepvp9" ? "keep" : "convert", forKey: Prefs.Key.vp9)
let sem = DispatchSemaphore(value: 0)
if a[1] == "hevc" {   // snag-test-engine hevc <vp9 file> <duration>
    Task {
        let f = VideoInfo.Format(id: "248", ext: "webm", vcodec: "vp9", acodec: "none", height: 1080, width: 1920, fps: 25, range: "SDR", bytes: 0, exact: false, bitrate: 1200, proto: "https", note: "", languagePreference: -1)
        let t0 = Date()
        do {
            let out = try await Engine.toHEVC(URL(fileURLWithPath: a[2]), video: f, duration: Double(a[3])!, ffmpeg: Tools.ffmpeg!) { p in print(String(format: "  %.0f%%", p * 100)) }
            print("HEVC DONE \(String(format: "%.1f", Date().timeIntervalSince(t0)))s", out.path)
        } catch { print("FAILED", error.localizedDescription) }
        sem.signal()
    }
    sem.wait(); exit(0)
}
Task {
    do {
        let t0 = Date()
        let info = try await Engine.lookup(Link.normalized(a[1]) ?? a[1], wholePlaylist: a.count > 5 && a[5] == "playlist")
        print("LOOKUP \(String(format: "%.1f", Date().timeIntervalSince(t0)))s cookies=\(info.usedCookies) playlist=\(info.isPlaylist) entries=\(info.entries.count) title=\(info.title)")
        print("qualities:", info.qualities.map { $0.label + ($0.hdr ? " HDR" : "") })
        if let v = info.pickVideo(height: nil, hdr: true) { print("video:", v.id, v.codecName, v.height, v.range, v.bytes) }
        if let au = info.pickAudio() { print("audio:", au.id, au.audioName, au.bitrate, au.bytes) }
        print("subs:", info.subtitles.map(\.id), "default:", info.defaultSubtitles)
        print("thumb:", info.thumbnail ?? "-")
        if info.isPlaylist { print(info.entries.prefix(3)); exit(0) }
        let want = Set((a.count > 3 ? a[3] : "video,subs,thumb").split(separator: ",").map(String.init))
        var c = Choice()
        c.video = want.contains("video"); c.audio = want.contains("audio"); c.thumbnail = want.contains("thumb")
        c.description = want.contains("desc")
        c.subtitles = want.contains("subs") ? info.defaultSubtitles : []
        if want.contains("allsubs") { c.subtitles = Set(info.subtitles.map(\.id)) }
        if a.count > 4, let h = Int(a[4]) { c.height = h }
        let t1 = Date()
        let files = try await Engine.download(info, c, into: URL(fileURLWithPath: a[2])) { p in
            print(String(format: "  %@ %.0f%% %@", p.stage.rawValue, p.fraction * 100, p.detail))
        }
        print("DONE \(String(format: "%.1f", Date().timeIntervalSince(t1)))s")
        for f in files { print(" ", f.lastPathComponent, (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    } catch { print("FAILED:", error.localizedDescription) }
    sem.signal()
}
sem.wait()
