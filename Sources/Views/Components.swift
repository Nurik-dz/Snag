import SwiftUI
import AppKit

/// Thin rounded bar with a smooth fill (from Swarm).
struct ProgressCapsule: View {
    var value: Double
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                    .opacity(value > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}

/// Shrinks a little while pressed, springs back on release (from Swarm).
struct PressScale: ButtonStyle {
    var amount: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? amount : 1)
            .animation(.spring(duration: 0.22, bounce: 0.3), value: configuration.isPressed)
    }
}

/// Small round icon button used on rows (from Swarm).
struct RoundButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .foregroundStyle(tint ?? (hover ? Color.primary : Color.secondary))
                .background(Circle().fill(.quaternary.opacity(hover ? 1 : 0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale(amount: 0.86))
        .animation(.smooth(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A YouTube thumbnail, kept in memory once loaded so rows never flicker.
struct Thumb: View {
    let url: String?
    var corner: CGFloat = 6

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.07))
            if let url, let image = ThumbCache.shared.image(for: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.tertiary)
                    .task(id: url) { await ThumbCache.shared.load(url) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

@MainActor
@Observable
final class ThumbCache {
    static let shared = ThumbCache()
    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    func image(for url: String) -> NSImage? { images[url] }

    func load(_ url: String?) async {
        guard let url, images[url] == nil, !loading.contains(url), let u = URL(string: url) else { return }
        loading.insert(url)
        defer { loading.remove(url) }
        guard let (data, _) = try? await URLSession.shared.data(from: u), let image = NSImage(data: data) else { return }
        if images.count > 300 { images.removeAll() }
        images[url] = image
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func left(_ seconds: Double) -> String {
        if seconds < 5 { return "a few seconds left" }
        if seconds < 90 { return "\(Int(seconds.rounded())) s left" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min left" }
        return String(format: "%.1f h left", seconds / 3600)
    }
}
