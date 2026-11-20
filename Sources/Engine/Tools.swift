import Foundation

/// Finds yt-dlp, ffmpeg and deno, and runs them with a PATH that works when
/// the app is opened from Finder (which has no /opt/homebrew/bin on its PATH:
/// without deno, YouTube's challenges go unsolved and formats go missing).
enum Tools {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                             NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.deno/bin"]

    static func find(_ name: String) -> String? {
        for dir in searchDirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var ytdlp: String? { find("yt-dlp") }
    static var ffmpeg: String? { find("ffmpeg") }
    static var deno: String? { find("deno") }
    static var brew: String? { find("brew") }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? ""
        env["PATH"] = (searchDirs + [current]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return env
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    struct Missing: LocalizedError {
        var tool: String
        var errorDescription: String? {
            "\(tool) is not installed. Open Snag's Settings for the one-line install."
        }
    }
}

/// One running command-line tool. Lines from stdout and stderr arrive as
/// they are printed; `interrupt()` stops it the way Control-C does, so
/// yt-dlp keeps its .part files and the next run resumes.
final class ToolRun: @unchecked Sendable {
    private let process = Process()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let lock = NSLock()
    private(set) var stderrTail: [String] = []
    private var collected = Data()

    init(_ executable: String, _ arguments: [String], directory: URL? = nil) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Tools.environment
        if let directory { process.currentDirectoryURL = directory }
    }

    /// Runs to the end. `onLine` gets every line (stdout and stderr).
    /// Returns the exit status; stdout is kept when `keepOutput`.
    func run(keepOutput: Bool = false, onLine: (@Sendable (String) -> Void)? = nil) async throws -> (status: Int32, output: String) {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            if keepOutput { self.collected.append(data) }
            let lines = Self.split(&self.stdoutBuffer, adding: data)
            self.lock.unlock()
            if let onLine { lines.forEach(onLine) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            let lines = Self.split(&self.stderrBuffer, adding: data)
            self.stderrTail.append(contentsOf: lines)
            if self.stderrTail.count > 60 { self.stderrTail.removeFirst(self.stderrTail.count - 60) }
            self.lock.unlock()
            if let onLine { lines.forEach(onLine) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(status: Int32, output: String), Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    // Whatever is still in the pipes.
                    let restOut = out.fileHandleForReading.readDataToEndOfFile()
                    let restErr = err.fileHandleForReading.readDataToEndOfFile()
                    self.lock.lock()
                    if keepOutput { self.collected.append(restOut) }
                    var lines = Self.split(&self.stdoutBuffer, adding: restOut)
                    if !self.stdoutBuffer.isEmpty, let s = String(data: self.stdoutBuffer, encoding: .utf8) { lines.append(s) }
                    var errLines = Self.split(&self.stderrBuffer, adding: restErr)
                    if !self.stderrBuffer.isEmpty, let s = String(data: self.stderrBuffer, encoding: .utf8) { errLines.append(s) }
                    self.stderrTail.append(contentsOf: errLines)
                    let output = String(decoding: self.collected, as: UTF8.self)
                    self.lock.unlock()
                    if let onLine { (lines + errLines).forEach(onLine) }
                    cont.resume(returning: (p.terminationStatus, output))
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            self.interrupt()
        }
    }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    var lastError: String {
        lock.lock(); defer { lock.unlock() }
        let errors = stderrTail.filter { $0.hasPrefix("ERROR") }
        if let e = errors.last { return e }
        return stderrTail.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }

    private static func split(_ buffer: inout Data, adding data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let lineData = buffer[buffer.startIndex..<i]
            buffer.removeSubrange(buffer.startIndex...i)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        return lines
    }
}
