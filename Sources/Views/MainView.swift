import SwiftUI
import UniformTypeIdentifiers

/// The one small window: link on top, what it found, then Downloads.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                if model.accessBlocked { AccessBanner().transition(.opacity) }
                LinkField()
                FoundArea()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
            DownloadsList()
        }
        .background(WindowBackdrop(look: AppearanceModel.shared.look).ignoresSafeArea())
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.url, .plainText], isTargeted: $dropping) { providers in
            for p in providers {
                if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in AppModel.shared.text = url.absoluteString } }
                    }
                    return true
                }
                if p.canLoadObject(ofClass: String.self) {
                    _ = p.loadObject(ofClass: String.self) { s, _ in
                        if let s { Task { @MainActor in AppModel.shared.text = s } }
                    }
                    return true
                }
            }
            return false
        }
        .animation(.smooth(duration: 0.3), value: model.phase)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openFolder() } label: { Label("Downloads Folder", systemImage: "folder") }
                    .help("Open the folder Snag saves to")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Settings (⌘,)")
            }
        }
    }
}

// MARK: - Link field

struct LinkField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Paste a YouTube link", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { model.download() }
            if model.phase == .looking {
                ProgressView().controlSize(.small)
            } else if !model.text.isEmpty {
                Button { model.clear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Clear")
            }
            if model.text.isEmpty {
                // The system paste button reads the clipboard without the
                // macOS privacy alert a silent read would cause.
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { model.text = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { focused = true }
    }
}

// MARK: - What the link is

struct FoundArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .looking:
            LookingCard()
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if message.contains("Full Disk Access") {
                    Button("Allow…") { model.openAccessSettings() }.controlSize(.small)
                } else {
                    Button("Try Again") { let t = model.text; model.text = ""; model.text = t }
                        .controlSize(.small)
                }
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity)
        case .found:
            if let info = model.found {
                FoundCard(info: info)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }
}

/// Placeholder shaped like the card while yt-dlp looks (2-5 s).
struct LookingCard: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
                .frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 7) {
                Text("Looking up the link…").font(.headline)
                Text(Engine.cookieArgs.isEmpty ? "Asking YouTube what it has" : "Asking YouTube what it has, signed in with \(Prefs.browser?.title ?? "your browser")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Found card

struct FoundCard: View {
    @Environment(AppModel.self) private var model
    let info: VideoInfo

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Thumb(url: info.isPlaylist ? info.entries.first.map { "https://i.ytimg.com/vi/\($0.id)/mqdefault.jpg" } ?? info.thumbnail
                                           : "https://i.ytimg.com/vi/\(info.id)/mqdefault.jpg", corner: 8)
                    .frame(width: 112, height: 63)
                    .overlay(alignment: .bottomTrailing) {
                        if !info.isPlaylist, info.duration > 0 {
                            Text(Format.clock(info.duration))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .padding(4)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let best = info.qualities.first, !info.isPlaylist {
                        HStack(spacing: 4) {
                            if let badge = best.badge { Tag(text: badge, strong: true) }
                            Tag(text: best.label)
                            if best.hdr { Tag(text: "HDR") }
                            if info.usedCookies { Tag(text: "Signed in", symbol: "person.crop.circle.badge.checkmark") }
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if model.linkHasPlaylist {
                Toggle(isOn: $model.wholePlaylist) {
                    Text("Download the whole playlist").font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            Tiles(info: info)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary).font(.caption.weight(.medium)).lineLimit(1)
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { model.download() } label: {
                    Label(buttonTitle, systemImage: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.choice.isEmpty)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var subtitle: String {
        if info.isPlaylist {
            return ["\(info.entries.count) videos", info.channel].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return info.channel
    }

    private var buttonTitle: String {
        if info.isPlaylist { return "Download \(info.entries.count)" }
        return model.alreadyHave.isEmpty ? "Download" : "Again"
    }

    private var summary: String {
        if info.isPlaylist { return model.qualityText(info).isEmpty ? "Choose what to save" : model.qualityText(info) }
        let q = model.qualityText(info)
        let size = model.estimate
        return [q, size > 0 ? "about " + Format.bytes(size) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var note: String {
        if !model.alreadyHave.isEmpty { return "You already have this in your Snag folder." }
        if model.choice.isEmpty { return "Turn on at least one of the four." }
        if info.isPlaylist {
            return Prefs.gentle ? "One after another, with a short pause between videos." : "One after another."
        }
        if model.choice.video, let v = info.pickVideo(height: model.choice.height, hdr: model.choice.hdr), v.isVP9 {
            return Prefs.vp9 == .convert
                ? "YouTube has this only as VP9, so it's converted to HEVC at full quality to play everywhere."
                : "Kept as VP9: plays in IINA or VLC, not in QuickTime."
        }
        return "Saved to " + Prefs.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

struct Tag: View {
    let text: String
    var strong = false
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: 9.5, weight: .bold))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .foregroundStyle(strong ? Color.white : Color.secondary)
        .background(Capsule().fill(strong ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.08))))
    }
}

/// macOS keeps the browser's sign-in from Snag until Full Disk Access is on.
struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not signed in yet").font(.system(size: 12, weight: .semibold))
                Text("macOS needs your OK before Snag can use \(Prefs.browser?.title ?? "your browser")'s YouTube sign-in. Public videos work meanwhile.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Allow…") { model.openAccessSettings() }
                .controlSize(.small)
                .help("Opens Privacy & Security › Full Disk Access. Switch on Snag (or add it with +), then come back.")
        }
        .padding(10)
        .glassEffect(.regular.tint(.orange.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
