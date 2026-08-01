import Foundation

/// Locates and runs ffmpeg/ffprobe. The app never links ffmpeg — it runs it as a
/// child process, looking inside its own bundle first, then Homebrew, then PATH.
enum FFmpeg {
    static let ffmpegPath: String? = locate("ffmpeg")
    static let ffprobePath: String? = locate("ffprobe")

    static var isAvailable: Bool { ffmpegPath != nil && ffprobePath != nil }

    private static func locate(_ name: String) -> String? {
        var candidates: [String] = []
        // Bundled copy wins, so a packaged app is self-contained if we ship one.
        if let res = Bundle.main.resourceURL?.appendingPathComponent(name).path {
            candidates.append(res)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ])
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to PATH.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", name]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        if which.terminationStatus == 0,
           let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return nil
    }

    struct ProcessError: Error, LocalizedError {
        let command: String
        let stderr: String
        var errorDescription: String? {
            "ffmpeg failed:\n\(stderr.split(separator: "\n").suffix(6).joined(separator: "\n"))"
        }
    }

    /// Run ffmpeg synchronously (call from a background thread). Returns stderr on success too.
    @discardableResult
    static func run(_ args: [String],
                    tool: String? = nil,
                    onProgressSeconds: ((Double) -> Void)? = nil,
                    isCancelled: (() -> Bool)? = nil) throws -> String {
        guard let exe = tool ?? ffmpegPath else {
            throw ProcessError(command: "ffmpeg", stderr: "ffmpeg not found. Install it with: brew install ffmpeg")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        var fullArgs = args
        if onProgressSeconds != nil {
            fullArgs = ["-progress", "pipe:1", "-nostats"] + args
        }
        proc.arguments = ["-hide_banner"] + fullArgs

        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe

        var stderrData = Data()
        let stderrLock = NSLock()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            stderrLock.lock(); stderrData.append(d); stderrLock.unlock()
        }

        var outBuffer = ""
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            outBuffer += s
            // -progress emits key=value lines; out_time_us is microseconds of output written.
            var lastUS: Double?
            for line in outBuffer.split(separator: "\n") {
                if line.hasPrefix("out_time_us="), let v = Double(line.dropFirst("out_time_us=".count)) {
                    lastUS = v
                }
            }
            if let us = lastUS, us > 0 { onProgressSeconds?(us / 1_000_000) }
            if let idx = outBuffer.lastIndex(of: "\n") {
                outBuffer = String(outBuffer[outBuffer.index(after: idx)...])
            }
        }

        try proc.run()
        while proc.isRunning {
            if isCancelled?() == true {
                proc.terminate()
                usleep(200_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                break
            }
            usleep(100_000)
        }
        proc.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        stderrLock.lock()
        stderrData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        stderrLock.unlock()

        if isCancelled?() == true {
            throw CancellationError()
        }
        guard proc.terminationStatus == 0 else {
            throw ProcessError(command: ([exe] + fullArgs).joined(separator: " "), stderr: stderr)
        }
        return stderr
    }
}

// MARK: - Probing

struct ClipInfo: Equatable {
    var duration: Double
    var width: Int
    var height: Int
    var fps: Double
    var videoCodec: String
    var hasAudio: Bool
    var colorRange: String?     // "pc" (full) or "tv" (limited)
    var fileSize: Int64
}

enum Probe {
    private struct FFProbeOut: Decodable {
        struct Stream: Decodable {
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let avg_frame_rate: String?
            let color_range: String?
        }
        struct Format: Decodable {
            let duration: String?
            let size: String?
        }
        let streams: [Stream]?
        let format: Format?
    }

    static func probe(_ url: URL) throws -> ClipInfo {
        guard let ffprobe = FFmpeg.ffprobePath else {
            throw FFmpeg.ProcessError(command: "ffprobe", stderr: "ffprobe not found. Install it with: brew install ffmpeg")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_streams", "-show_format",
            url.path,
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw FFmpeg.ProcessError(command: "ffprobe", stderr: "could not read \(url.lastPathComponent)")
        }
        let decoded = try JSONDecoder().decode(FFProbeOut.self, from: data)
        let video = decoded.streams?.first { $0.codec_type == "video" }
        let audio = decoded.streams?.first { $0.codec_type == "audio" }

        var fps = 0.0
        if let r = video?.avg_frame_rate {
            let parts = r.split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 {
                fps = n / d
            } else if let n = Double(r) {
                fps = n
            }
        }
        return ClipInfo(
            duration: Double(decoded.format?.duration ?? "") ?? 0,
            width: video?.width ?? 0,
            height: video?.height ?? 0,
            fps: fps,
            videoCodec: video?.codec_name ?? "?",
            hasAudio: audio != nil,
            colorRange: video?.color_range,
            fileSize: Int64(decoded.format?.size ?? "") ?? 0
        )
    }
}
