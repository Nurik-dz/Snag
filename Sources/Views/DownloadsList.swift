import SwiftUI

/// Downloads: what is running now, then what was saved before (the recents).
struct DownloadsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.records.isEmpty {
                if model.phase == .idle { EmptyState() } else { Spacer() }
            } else {
                HStack {
                    Text("Downloads").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if model.records.contains(where: { $0.state == .done }) {
                        Button("Clear Finished") { withAnimation(.smooth) { model.clearFinished() } }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 4)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.records) { r in
                            DownloadRow(record: r, speed: model.speeds[r.id])
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                    .animation(.smooth(duration: 0.3), value: model.records.map(\.id))
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 10)
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, options: .nonRepeating)
            VStack(spacing: 5) {
                Text("Paste a link to start")
                    .font(.system(size: 15, weight: .semibold))
                Text("A video, a Short, a playlist or a whole channel. Snag takes the best quality YouTube has, with subtitles and the thumbnail.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Hint(symbol: "doc.on.clipboard", text: "Copy a link in your browser, then press Paste")
                Hint(symbol: "hand.draw", text: "Or drag a link from the browser onto this window")
                Hint(symbol: "person.crop.circle.badge.checkmark",
                     text: Prefs.browser.map { $0 == .none ? "Not signed in: change that in Settings"
                         : !$0.canRead ? "\($0.title) sign-in waits for Full Disk Access (see above)"
                         : "Signed in through \($0.title): members and age-restricted videos work" } ?? "Choose your browser in Settings to sign in")
            }
            .padding(.top, 4)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

private struct Hint: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let record: Record
    let speed: String?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Thumb(url: record.thumbnail, corner: 5)
                .frame(width: 64, height: 36)
                .overlay {
                    if record.isPlaylist {
                        Image(systemName: "list.bullet").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .padding(4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                status
            }
            Spacer(minLength: 4)
            buttons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if record.state == .done { model.open(record) } }
        .contextMenu { menu }
        .animation(.smooth(duration: 0.2), value: record.state)
    }

    @ViewBuilder private var status: some View {
        switch record.state {
        case .working:
            VStack(alignment: .leading, spacing: 3) {
                ProgressCapsule(value: record.fraction, tint: .accentColor)
                Text(workingLine)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        case .queued:
            Text("Waiting · " + record.quality).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        case .paused:
            VStack(alignment: .leading, spacing: 3) {
                ProgressCapsule(value: record.fraction, tint: .secondary)
                Text((record.stage.isEmpty ? "Paused" : record.stage) + " · \(Int(record.fraction * 100))%")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .done:
            HStack(spacing: 4) {
                Image(systemName: record.error == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(record.error == nil ? Color.green : Color.orange)
                Text(record.error ?? doneLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 10))
            .help(record.error ?? "")
        case .failed:
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(record.error ?? "Failed").foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10))
            .help(record.error ?? "")
        }
    }

    private var workingLine: String {
        var parts: [String] = []
        if !record.stage.isEmpty { parts.append(record.stage) }
        if record.stage.isEmpty || record.isPlaylist {
            if !record.isPlaylist, record.bytesTotal > 0 {
                parts.append("\(Int(record.fraction * 100))% of \(Format.bytes(record.bytesTotal))")
            } else {
                parts.append("\(Int(record.fraction * 100))%")
            }
            if let speed { parts.append(speed) }
        }
        return parts.joined(separator: " · ")
    }

    private var doneLine: String {
        var parts: [String] = []
        if record.isPlaylist { parts.append("\(record.doneIDs.count) videos") }
        if !record.quality.isEmpty { parts.append(record.quality) }
        if !record.isPlaylist, record.bytesTotal > 0 { parts.append(Format.bytes(record.bytesTotal)) }
        if record.files.count > 1, !record.isPlaylist { parts.append("\(record.files.count) files") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 4) {
            switch record.state {
            case .working, .queued:
                RoundButton(symbol: "pause.fill", help: "Pause") { model.pause(record.id) }
                RoundButton(symbol: "xmark", help: "Cancel and remove") { model.remove(record.id) }
            case .paused:
                RoundButton(symbol: "arrow.down", help: "Resume", tint: .accentColor) { model.resume(record.id) }
                RoundButton(symbol: "xmark", help: "Remove") { model.remove(record.id) }
            case .done:
                if record.mainFile.map({ ["mp4", "mkv", "webm", "mov", "m4a", "mp3", "flac", "wav"].contains($0.pathExtension) }) == true {
                    RoundButton(symbol: "play.fill", help: "Play") { model.open(record) }
                }
                RoundButton(symbol: "magnifyingglass", help: "Show in Finder") { model.reveal(record) }
            case .failed:
                RoundButton(symbol: "arrow.clockwise", help: "Try Again", tint: .accentColor) { model.resume(record.id) }
                RoundButton(symbol: "xmark", help: "Remove") { model.remove(record.id) }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if record.state == .done {
            Button("Open") { model.open(record) }
            Button("Show in Finder") { model.reveal(record) }
            Divider()
        }
        Button("Copy Link") { model.copyLink(record) }
        Button("Open on YouTube") { if let u = URL(string: record.link) { NSWorkspace.shared.open(u) } }
        Divider()
        Button("Remove from List") { model.remove(record.id) }
    }
}
