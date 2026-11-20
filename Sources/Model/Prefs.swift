import Foundation

/// Every setting, kept in UserDefaults.
enum Prefs {
    enum Key {
        static let theme = "theme"
        static let look = "look"
        static let browser = "browser"
        static let cookieMode = "cookieMode"
        static let folder = "folder"
        static let container = "container"
        static let vp9 = "vp9"
        static let hdr = "hdr"
        static let audioFormat = "audioFormat"
        static let subFormat = "subFormat"
        static let thumbFormat = "thumbFormat"
        static let embed = "embed"
        static let folderPerVideo = "folderPerVideo"
        static let gentle = "gentle"
        static let notify = "notify"
        static let wantVideo = "wantVideo"
        static let wantAudio = "wantAudio"
        static let wantSubs = "wantSubs"
        static let wantThumb = "wantThumb"
        static let wantDescription = "wantDescription"
        static let atOnce = "atOnce"
    }

    static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            Key.browser: Browser.installed.first?.rawValue ?? "none",
            Key.cookieMode: CookieMode.always.rawValue,
            Key.container: "mp4",
            Key.vp9: VP9Rule.convert.rawValue,
            Key.hdr: true,
            Key.audioFormat: AudioFormat.original.rawValue,
            Key.subFormat: SubFormat.both.rawValue,
            Key.thumbFormat: "jpg",
            Key.embed: true,
            Key.folderPerVideo: false,
            Key.gentle: true,
            Key.notify: true,
            Key.wantVideo: true,
            Key.wantAudio: false,
            Key.wantSubs: true,
            Key.wantThumb: true,
            Key.wantDescription: false,
            Key.atOnce: 2,
        ])
    }

    static var browser: Browser? { Browser(rawValue: d.string(forKey: Key.browser) ?? "") }
    static var cookieMode: CookieMode { CookieMode(rawValue: d.string(forKey: Key.cookieMode) ?? "") ?? .always }
    static var container: String { d.string(forKey: Key.container) ?? "mp4" }
    static var vp9: VP9Rule { VP9Rule(rawValue: d.string(forKey: Key.vp9) ?? "") ?? .convert }
    static var hdr: Bool { d.bool(forKey: Key.hdr) }
    static var audioFormat: AudioFormat { AudioFormat(rawValue: d.string(forKey: Key.audioFormat) ?? "") ?? .original }
    static var subFormat: SubFormat { SubFormat(rawValue: d.string(forKey: Key.subFormat) ?? "") ?? .both }
    static var thumbFormat: String { d.string(forKey: Key.thumbFormat) ?? "jpg" }
    static var embed: Bool { d.bool(forKey: Key.embed) }
    static var folderPerVideo: Bool { d.bool(forKey: Key.folderPerVideo) }
    static var gentle: Bool { d.bool(forKey: Key.gentle) }
    static var notify: Bool { d.bool(forKey: Key.notify) }
    static var atOnce: Int { max(1, min(3, d.integer(forKey: Key.atOnce))) }

    static var folder: URL {
        if let path = d.string(forKey: Key.folder), !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Snag")
    }
}

enum CookieMode: String, CaseIterable, Identifiable {
    case always, whenNeeded, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: "Always"
        case .whenNeeded: "Only when a video needs it"
        case .never: "Never"
        }
    }
}

enum VP9Rule: String, CaseIterable, Identifiable {
    case convert, keep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .convert: "Convert to HEVC so it plays everywhere"
        case .keep: "Keep the original VP9"
        }
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case original, aac, mp3, flac, wav
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original (no conversion)"
        case .aac: "AAC 256 kbps"
        case .mp3: "MP3 320 kbps"
        case .flac: "FLAC"
        case .wav: "WAV"
        }
    }
    var short: String {
        switch self {
        case .original: "Original"
        case .aac: "AAC"
        case .mp3: "MP3"
        case .flac: "FLAC"
        case .wav: "WAV"
        }
    }
    var ext: String {
        switch self {
        case .original, .aac: "m4a"
        case .mp3: "mp3"
        case .flac: "flac"
        case .wav: "wav"
        }
    }
}

enum SubFormat: String, CaseIterable, Identifiable {
    case both, srt, vtt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "SRT and VTT"
        case .srt: "SRT"
        case .vtt: "VTT"
        }
    }
}

/// Browsers yt-dlp can take your YouTube sign-in from.
enum Browser: String, CaseIterable, Identifiable {
    case brave, chrome, edge, firefox, vivaldi, opera, chromium, safari, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brave: "Brave"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .firefox: "Firefox"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .chromium: "Chromium"
        case .safari: "Safari"
        case .none: "Don't use cookies"
        }
    }

    /// macOS hides other apps' data from Snag until it has Full Disk
    /// Access (a silent "Operation not permitted", no prompt). Measured:
    /// Terminal could read Brave's cookies, Snag.app could not.
    var canRead: Bool {
        guard let folder = dataFolder else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
    }

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    private var dataFolder: String? {
        let base = NSHomeDirectory() + "/Library/Application Support/"
        switch self {
        case .brave: return base + "BraveSoftware/Brave-Browser"
        case .chrome: return base + "Google/Chrome"
        case .edge: return base + "Microsoft Edge"
        case .firefox: return base + "Firefox/Profiles"
        case .vivaldi: return base + "Vivaldi"
        case .opera: return base + "com.operasoftware.Opera"
        case .chromium: return base + "Chromium"
        case .safari: return NSHomeDirectory() + "/Library/Containers/com.apple.Safari"
        case .none: return nil
        }
    }

    /// Chromium browsers keep the key to their cookies in the Keychain:
    /// the first read asks for the login password once ("Always Allow").
    var note: String? {
        switch self {
        case .safari, .firefox, .none: nil
        default: "The first time, macOS asks to let Snag read \"\(title) Safe Storage\". Choose Always Allow."
        }
    }

    static var installed: [Browser] {
        allCases.filter { b in
            guard let folder = b.dataFolder else { return false }
            return FileManager.default.fileExists(atPath: folder)
        }
    }
}
