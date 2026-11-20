import SwiftUI

/// Four Control Center style tiles: click to switch on or off, the small
/// chevron opens that tile's choices.
struct Tiles: View {
    @Environment(AppModel.self) private var model
    let info: VideoInfo
    @State private var open: String?

    var body: some View {
        HStack(spacing: 8) {
            Tile(id: "video", title: "Video", symbol: "film", value: videoValue,
                 on: model.choice.video, open: $open, toggle: { model.setVideo(!model.choice.video) }) {
                VideoOptions(info: info)
            }
            Tile(id: "audio", title: "Audio", symbol: "waveform", value: Prefs.audioFormat.short,
                 on: model.choice.audio, open: $open, toggle: { model.setAudio(!model.choice.audio) }) {
                AudioOptions(info: info)
            }
            Tile(id: "subs", title: "Subtitles", symbol: "captions.bubble", value: subsValue,
                 on: !model.choice.subtitles.isEmpty, enabled: info.isPlaylist || !info.subtitles.isEmpty,
                 open: $open, toggle: { model.wantSubtitles = model.choice.subtitles.isEmpty }) {
                SubtitleOptions(info: info)
            }
            Tile(id: "thumb", title: "Thumbnail", symbol: "photo", value: Prefs.thumbFormat.uppercased() + (model.choice.description ? " + text" : ""),
                 on: model.choice.thumbnail, open: $open, toggle: { model.setThumb(!model.choice.thumbnail) }) {
                ThumbOptions()
            }
        }
    }

    private var videoValue: String {
        if info.isPlaylist { return model.choice.height.map { "≤ \($0)p" } ?? "Best" }
        guard let v = info.pickVideo(height: model.choice.height, hdr: model.choice.hdr) else { return "—" }
        return "\(v.height)p" + (v.isHDR ? " HDR" : "") + " · " + Prefs.container.uppercased()
    }

    private var subsValue: String {
        if info.isPlaylist { return model.choice.subtitles.isEmpty ? "Off" : "Auto" }
        if info.subtitles.isEmpty { return "None" }
        let chosen = info.subtitles.filter { model.choice.subtitles.contains($0.id) }
        if chosen.isEmpty { return "\(info.subtitles.count) available" }
        if chosen.count == 1 { return chosen[0].code.replacingOccurrences(of: "-orig", with: "") + (chosen[0].auto ? " auto" : "") }
        return "\(chosen.count) languages"
    }
}

struct Tile<Options: View>: View {
    let id: String
    let title: String
    let symbol: String
    let value: String
    let on: Bool
    var enabled = true
    @Binding var open: String?
    let toggle: () -> Void
    @ViewBuilder let options: () -> Options
    @State private var hover = false

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolVariant(on ? .fill : .none)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Text(on ? value : (enabled ? "Off" : value))
                        .font(.system(size: 9.5, weight: .medium))
                        .opacity(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(hover ? 0.11 : 0.07)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScale(amount: 0.95))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .overlay(alignment: .topTrailing) {
            if enabled {
                Button { open = open == id ? nil : id } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .heavy))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .background(Circle().fill(on ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressScale(amount: 0.85))
                .padding(6)
                .help("\(title) choices")
                .popover(isPresented: Binding(get: { open == id }, set: { if !$0 { open = nil } }), arrowEdge: .bottom) {
                    options()
                        .padding(14)
                        .frame(width: 260)
                }
            }
        }
        .onHover { hover = $0 }
        .animation(.smooth(duration: 0.2), value: on)
        .animation(.smooth(duration: 0.15), value: hover)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(on ? "on" : "off"), \(value)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Popovers

struct OptionHeader: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// A row in a popover list with a checkmark when chosen.
struct CheckRow: View {
    let title: String
    var detail: String? = nil
    let checked: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 12)
                Text(title).font(.callout)
                Spacer(minLength: 6)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct VideoOptions: View {
    @Environment(AppModel.self) private var model
    let info: VideoInfo
    @AppStorage(Prefs.Key.container) private var container = "mp4"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OptionHeader(text: "Quality")
            VStack(spacing: 0) {
                if info.isPlaylist {
                    CheckRow(title: "Best there is", checked: model.choice.height == nil) { model.setHeight(nil) }
                    ForEach([2160, 1440, 1080, 720], id: \.self) { h in
                        CheckRow(title: "Up to \(h)p", checked: model.choice.height == h) { model.setHeight(h) }
                    }
                } else {
                    let qs = info.qualities
                    CheckRow(title: "Best · " + (qs.first.map { $0.label + ($0.hdr ? " HDR" : "") } ?? ""),
                             detail: size(nil), checked: model.choice.height == nil) { model.setHeight(nil) }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(qs.dropFirst().filter { $0.height >= 360 }) { q in
                                CheckRow(title: q.label + (q.badge.map { "  " + $0 } ?? ""), detail: size(q.height),
                                         checked: model.choice.height == q.height) { model.setHeight(q.height) }
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }
            if info.isPlaylist || info.qualities.contains(where: \.hdr) {
                Toggle("HDR when the video has it", isOn: Binding(get: { model.choice.hdr }, set: { model.setHDR($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.callout)
            }
            Divider()
            HStack {
                OptionHeader(text: "File")
                Spacer()
                Picker("", selection: $container) {
                    Text("MP4").tag("mp4")
                    Text("MKV").tag("mkv")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(container == "mp4" ? "MP4 plays in QuickTime, Photos and every editor."
                                    : "MKV is for IINA and VLC. QuickTime can't open it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func size(_ height: Int?) -> String? {
        guard let v = info.pickVideo(height: height, hdr: model.choice.hdr) else { return nil }
        let a = v.hasAudio ? 0 : (info.pickAudio()?.bytes ?? 0)
        let total = v.bytes + a
        guard total > 0 else { return nil }
        return Format.bytes(total) + " · " + v.codecName
    }
}

struct AudioOptions: View {
    @Environment(AppModel.self) private var model
    let info: VideoInfo
    @AppStorage(Prefs.Key.audioFormat) private var format = AudioFormat.original.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OptionHeader(text: "Audio file")
            VStack(spacing: 0) {
                ForEach(AudioFormat.allCases) { f in
                    CheckRow(title: f.title, checked: format == f.rawValue) {
                        format = f.rawValue
                        if !model.choice.audio { model.setAudio(true) }
                    }
                }
            }
            Text(explain).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explain: String {
        let src = info.pickAudio().map { "\($0.audioName) \(Int($0.bitrate.rounded())) kbps" } ?? "YouTube's best sound"
        switch AudioFormat(rawValue: format) ?? .original {
        case .original: return "The sound exactly as YouTube has it (\(src)) in an .m4a that plays everywhere. Best quality."
        case .aac, .mp3: return "Converted from \(src). Pick this only for an old player that needs it."
        case .flac, .wav: return "Lossless container of \(src): bigger file, same sound. Useful for editors."
        }
    }
}

struct SubtitleOptions: View {
    @Environment(AppModel.self) private var model
    let info: VideoInfo
    @AppStorage(Prefs.Key.subFormat) private var format = SubFormat.both.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if info.isPlaylist {
                OptionHeader(text: "Languages")
                Text("Each video gets subtitles in its own language: written by people when there are any, else YouTube's automatic captions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                let people = info.subtitles.filter { !$0.auto }
                let auto = info.subtitles.filter(\.auto)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !people.isEmpty {
                            OptionHeader(text: "Written by people")
                            VStack(spacing: 0) {
                                ForEach(people) { s in
                                    CheckRow(title: s.name, detail: s.code, checked: model.choice.subtitles.contains(s.id)) { model.toggleSubtitle(s.id) }
                                }
                            }
                        }
                        if !auto.isEmpty {
                            OptionHeader(text: "Automatic (YouTube's speech recognition)")
                            VStack(spacing: 0) {
                                ForEach(auto) { s in
                                    CheckRow(title: s.name, checked: model.choice.subtitles.contains(s.id)) { model.toggleSubtitle(s.id) }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Divider()
            HStack {
                OptionHeader(text: "Files")
                Spacer()
                Picker("", selection: $format) {
                    ForEach(SubFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("Automatic captions are cleaned so each line shows once in the SRT. The VTT keeps YouTube's word timings.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ThumbOptions: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.Key.thumbFormat) private var format = "jpg"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OptionHeader(text: "Thumbnail")
            Picker("", selection: $format) {
                Text("JPG").tag("jpg")
                Text("PNG").tag("png")
                Text("As YouTube has it").tag("original")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("The full-size original (usually 1280×720), straight from YouTube.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Also save the description (.txt)", isOn: Binding(get: { model.choice.description }, set: { model.setDescription($0) }))
                .toggleStyle(.checkbox)
        }
    }
}
