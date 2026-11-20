import Foundation

/// WebVTT to SRT. YouTube's automatic captions "roll": each cue repeats the
/// line before it, and 10 ms cues sit between them. A plain conversion
/// shows every line twice, so those are folded into one clean line each.
enum SubtitleConverter {
    struct Cue { var start: Double; var end: Double; var lines: [String] }

    static func parseVTT(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = time(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = time(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "")
            else { continue }
            let body = lines[(ti + 1)...].map(clean)
            cues.append(Cue(start: start, end: end, lines: body))
        }
        return cues
    }

    /// Rolling captions are recognised by their tiny bridge cues.
    static func isRolling(_ cues: [Cue]) -> Bool {
        guard cues.count > 4 else { return false }
        let tiny = cues.filter { $0.end - $0.start < 0.05 }.count
        return Double(tiny) / Double(cues.count) > 0.25
    }

    static func srt(fromVTT text: String) -> String {
        var cues = parseVTT(text)
        if isRolling(cues) {
            var out: [Cue] = []
            var shown: [String] = []
            for cue in cues where cue.end - cue.start >= 0.05 {
                let lines = cue.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                // Keep only the lines this cue adds.
                let fresh = lines.filter { !shown.contains($0) }
                shown = lines
                guard !fresh.isEmpty else {
                    if var last = out.popLast() { last.end = max(last.end, cue.end); out.append(last) }
                    continue
                }
                out.append(Cue(start: cue.start, end: cue.end, lines: fresh))
            }
            cues = out
        } else {
            cues = cues.map { c in
                Cue(start: c.start, end: c.end, lines: c.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }.filter { !$0.lines.isEmpty }
        }
        // Never overlap the next cue.
        for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start {
            cues[i].end = max(cues[i].start + 0.01, cues[i + 1].start)
        }
        var srt = ""
        for (i, c) in cues.enumerated() {
            srt += "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.lines.joined(separator: "\n"))\n\n"
        }
        return srt
    }

    private static func clean(_ line: String) -> String {
        var s = line
        // <00:00:01.234><c> word</c> timing tags and any other markup.
        while let r = s.range(of: "<[^>]*>", options: .regularExpression) { s.removeSubrange(r) }
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&lrm;": "", "&rlm;": ""]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }

    private static func time(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func stamp(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
