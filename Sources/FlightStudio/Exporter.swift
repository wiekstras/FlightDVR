import SwiftUI
import Combine

enum ColorMode: String, CaseIterable, Identifiable {
    case fixRange = "Fix levels"
    case leaveAlone = "Leave colour alone"
    var id: String { rawValue }
}

enum Preset: String, CaseIterable, Identifiable {
    case edit = "Edit (ProRes)"
    case master = "Master (H.264)"
    case social = "Social (target size)"
    case remux = "Remux (no re-encode)"
    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .edit: "ProRes 422 in .mov — DaVinci/Final Cut timelines, instant scrubbing."
        case .master: "Quality-based H.264 .mp4 — archiving and sharing at full quality."
        case .social: "Two-pass H.264 aimed at an exact file size — WhatsApp, Discord."
        case .remux: "Instant lossless rewrap to .mp4. Cuts land on keyframes only."
        }
    }
    var fileExtension: String { self == .edit ? "mov" : "mp4" }
}

enum ProResProfile: String, CaseIterable, Identifiable {
    case lt = "ProRes 422 LT"
    case standard = "ProRes 422"
    case hq = "ProRes 422 HQ"
    var id: String { rawValue }
    var ffmpegProfile: String {
        switch self {
        case .lt: "1"
        case .standard: "2"
        case .hq: "3"
        }
    }
}

enum MasterQuality: String, CaseIterable, Identifiable {
    case archive = "Archive"
    case high = "High"
    case good = "Good"
    case compact = "Compact"
    var id: String { rawValue }
    var crf: Int {
        switch self {
        case .archive: 16
        case .high: 18
        case .good: 21
        case .compact: 25
        }
    }
}

enum SocialProfile: String, CaseIterable, Identifiable {
    case tiktok = "TikTok"
    case instagramReel = "Instagram Reel"
    case youtubeShort = "YouTube Short"
    case youtube = "YouTube"
    var id: String { rawValue }

    var canvasLabel: String { isVertical ? "1080 × 1920 · 9:16" : "1920 × 1080 · 16:9" }
    var isVertical: Bool { self != .youtube }
    func videoFilter(framing: SocialFraming) -> String {
        let size = isVertical ? "1080:1920" : "1920:1080"
        if framing == .fill {
            return "scale=\(size):force_original_aspect_ratio=increase,crop=\(size)"
        }
        if isVertical {
            return "scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:black"
        }
        return "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black"
    }
}

enum SocialFraming: String, CaseIterable, Identifiable {
    case fit = "Fit entire frame"
    case fill = "Fill canvas"
    var id: String { rawValue }
}

struct ExportSettings {
    var preset: Preset = .master
    var colorMode: ColorMode = .fixRange
    var proResProfile: ProResProfile = .standard
    var masterQuality: MasterQuality = .high
    var socialTargetMB: Double = 25
    var socialProfile: SocialProfile = .tiktok
    var socialFraming: SocialFraming = .fit
    var keepAudio = true
    var useHardware = false
    var outputFolder: URL?

    var resolvedOutputFolder: URL {
        outputFolder ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flight Studio", isDirectory: true)
    }
}

/// Produces a non-destructive export name.  A card can contain clips with the
/// same filename in different folders, and existing exports are never replaced
/// just because they were queued together.
enum OutputNamer {
    static func uniqueURL(in folder: URL, baseName: String, fileExtension: String,
                          reserved: Set<URL> = [],
                          fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let safeBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled clip" : baseName
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " \(index)"
            let candidate = folder.appendingPathComponent("\(safeBase)\(suffix).\(fileExtension)")
            if !reserved.contains(candidate) && !fileExists(candidate) { return candidate }
            index += 1
        }
    }
}

// MARK: - Jobs

@MainActor
final class ExportJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting, running, done, cancelled
        case failed(String)

        var canRetry: Bool {
            switch self {
            case .cancelled, .failed: true
            case .waiting, .running, .done: false
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }
    let id = UUID()
    let clips: [Clip]
    let settings: ExportSettings
    let outputURL: URL
    @Published var state: State = .waiting
    @Published var progress: Double = 0      // 0…1
    nonisolated(unsafe) var cancelFlag = false

    var clip: Clip { clips[0] }
    var isStitch: Bool { clips.count > 1 }
    var displayName: String { isStitch ? "Sequence (\(clips.count) clips)" : clip.name }

    init(clips: [Clip], settings: ExportSettings, outputURL: URL) {
        precondition(!clips.isEmpty, "an export needs at least one clip")
        self.clips = clips
        self.settings = settings
        self.outputURL = outputURL
    }
}

@MainActor
final class ExportQueue: ObservableObject {
    @Published var jobs: [ExportJob] = []
    @Published var isRunning = false
    @Published var currentMessage = ""

    func enqueue(clips: [Clip], settings: ExportSettings) {
        let folder = settings.resolvedOutputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for clip in clips {
            let base = clip.url.deletingPathExtension().lastPathComponent
            let out = OutputNamer.uniqueURL(in: folder, baseName: base,
                                             fileExtension: settings.preset.fileExtension,
                                             reserved: Set(jobs.map(\.outputURL)))
            jobs.append(ExportJob(clips: [clip], settings: settings, outputURL: out))
        }
    }

    /// Join the selected clips in their current list order into one H.264
    /// sequence. Stitching deliberately re-encodes, so differing source codecs
    /// are fine; matching dimensions are required for a clean timeline.
    func enqueueStitch(clips: [Clip], settings: ExportSettings) {
        guard clips.count > 1 else { return }
        let folder = settings.resolvedOutputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stitchSettings = settings
        if stitchSettings.preset == .remux || stitchSettings.preset == .social {
            stitchSettings.preset = .master
        }
        let out = OutputNamer.uniqueURL(in: folder, baseName: "Flight sequence",
                                        fileExtension: stitchSettings.preset.fileExtension,
                                        reserved: Set(jobs.map(\.outputURL)))
        jobs.append(ExportJob(clips: clips, settings: stitchSettings, outputURL: out))
    }

    func remove(_ job: ExportJob) {
        if job.state == .running { job.cancelFlag = true }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled }
    }

    func clearFailed() {
        jobs.removeAll { $0.state.isFailure }
    }

    func cancel(_ job: ExportJob) { job.cancelFlag = true }

    /// Stop the active encode and prevent all queued exports from starting.
    func cancelAll() {
        for job in jobs {
            switch job.state {
            case .running:
                job.cancelFlag = true
            case .waiting:
                job.cancelFlag = true
                job.state = .cancelled
            case .done, .cancelled, .failed:
                break
            }
        }
    }

    /// Put a cancelled or failed job back in the queue without making the user
    /// reselect its clip and export settings.
    func retry(_ job: ExportJob) {
        guard job.state.canRetry else { return }
        job.cancelFlag = false
        job.progress = 0
        job.state = .waiting
    }

    /// Move a waiting export relative to the other waiting jobs. Completed and
    /// failed entries stay in place so their status remains easy to inspect.
    func moveWaiting(_ job: ExportJob, by offset: Int) {
        let waitingIndices = jobs.indices.filter { jobs[$0].state == .waiting }
        guard let current = waitingIndices.firstIndex(where: { jobs[$0].id == job.id }) else { return }
        let destination = current + offset
        guard waitingIndices.indices.contains(destination) else { return }
        jobs.swapAt(waitingIndices[current], waitingIndices[destination])
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await runLoop() }
    }

    private func runLoop() async {
        while let job = jobs.first(where: { $0.state == .waiting }) {
            job.state = .running
            currentMessage = "Exporting \(job.displayName)…"
            do {
                try await runJob(job)
                job.state = job.cancelFlag ? .cancelled : .done
                job.progress = 1
            } catch is CancellationError {
                job.state = .cancelled
                // Never leave a broken file behind: a cancelled encode is deleted.
                try? FileManager.default.removeItem(at: job.outputURL)
            } catch {
                job.state = .failed(error.localizedDescription)
                try? FileManager.default.removeItem(at: job.outputURL)
            }
        }
        isRunning = false
        currentMessage = ""
    }

    private func runJob(_ job: ExportJob) async throws {
        if job.isStitch {
            try await runStitchJob(job)
            return
        }
        guard let info = job.clip.info else {
            throw FFmpeg.ProcessError(command: "", stderr: "Clip was never probed — rescan and try again.")
        }
        let plan = job.clip.edit
        let settings = job.settings
        if let error = plan.validationError(duration: info.duration) {
            throw FFmpeg.ProcessError(command: "export", stderr: error)
        }
        let outDur = max(plan.outputDuration(duration: info.duration), 0.01)

        // Overwrite protection: exports never silently replace an existing file.
        if FileManager.default.fileExists(atPath: job.outputURL.path) {
            let replaced = job.outputURL
            let alert = NSAlert()
            alert.messageText = "\(replaced.lastPathComponent) already exists"
            alert.informativeText = "Overwrite it, or skip this clip?"
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Skip")
            if alert.runModal() != .alertFirstButtonReturn {
                throw CancellationError()
            }
        }

        let commands = ExportCommandBuilder.build(
            plan: plan, settings: settings, info: info,
            source: job.clip.url, output: job.outputURL, jobID: job.id)
        let passes = Double(commands.count)
        for (index, args) in commands.enumerated() {
            let passBase = Double(index) / passes
            _ = try await Task.detached(priority: .userInitiated) { [cancel = job] () throws in
                try FFmpeg.run(args, onProgressSeconds: { seconds in
                    let p = passBase + min(seconds / outDur, 1) / passes
                    Task { @MainActor in cancel.progress = p }
                }, isCancelled: { cancel.cancelFlag })
            }.value
        }
    }

    private func runStitchJob(_ job: ExportJob) async throws {
        let inputs = try job.clips.map { clip -> (URL, ClipInfo) in
            guard let info = clip.info else {
                throw FFmpeg.ProcessError(command: "", stderr: "\(clip.name) was never probed — rescan and try again.")
            }
            return (clip.url, info)
        }
        let totalDuration = max(inputs.reduce(0) { $0 + $1.1.duration }, 0.01)
        let args = try StitchCommandBuilder.build(inputs: inputs, settings: job.settings, output: job.outputURL)
        _ = try await Task.detached(priority: .userInitiated) { [cancel = job] () throws in
            try FFmpeg.run(args, onProgressSeconds: { seconds in
                Task { @MainActor in cancel.progress = min(seconds / totalDuration, 1) }
            }, isCancelled: { cancel.cancelFlag })
        }.value
    }

}

/// Turns a clip + edit plan + settings into complete ffmpeg invocations.
/// Pure and headless, so the GUI queue and --selftest share the same path.
enum ExportCommandBuilder {
    /// One or two (two-pass social) complete ffmpeg invocations for a job.
    static func build(plan: EditPlan, settings: ExportSettings, info: ClipInfo,
                      source src: URL, output out: URL, jobID: UUID) -> [[String]] {

        // Remux is the special case: pure stream copy, keyframe-accurate only.
        if settings.preset == .remux {
            var args: [String] = ["-y"]
            if plan.inPoint > 0 { args += ["-ss", String(format: "%.3f", plan.inPoint)] }
            if let outP = plan.outPoint { args += ["-to", String(format: "%.3f", outP)] }
            args += ["-i", src.path, "-map", "0:v:0"]
            args += settings.keepAudio ? ["-map", "0:a?"] : ["-an"]
            args += ["-c", "copy", "-movflags", "+faststart"]
            if info.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
            args.append(out.path)
            return [args]
        }

        let fixRange = settings.colorMode == .fixRange
        var effectivePlan = plan
        if !settings.keepAudio { effectivePlan.music = nil }
        let wantAudio = settings.keepAudio && (info.hasAudio || plan.music != nil)
        let graph = FilterGraphBuilder.build(plan: effectivePlan, duration: info.duration,
                                             sourceHasAudio: settings.keepAudio && info.hasAudio,
                                             fixColorRange: fixRange,
                                             outputVideoFilter: settings.preset == .social
                                                ? settings.socialProfile.videoFilter(framing: settings.socialFraming) : nil)

        var inputs: [String] = ["-i", src.path]
        if graph.needsMusicInput, let music = effectivePlan.music {
            inputs += ["-stream_loop", "-1", "-i", music.url.path]
        }

        var common: [String] = ["-y"] + inputs + ["-filter_complex", graph.filterComplex,
                                                  "-map", "[\(graph.videoLabel)]"]
        if wantAudio, let a = graph.audioLabel {
            common += ["-map", "[\(a)]", "-c:a", "aac", "-b:a", "192k"]
        } else {
            common += ["-an"]
        }
        if fixRange { common += ["-color_range", "tv"] }

        switch settings.preset {
        case .edit:
            var args = common
            args += ["-c:v", "prores_ks", "-profile:v", settings.proResProfile.ffmpegProfile,
                     "-vendor", "apl0", "-pix_fmt", "yuv422p10le", out.path]
            return [args]

        case .master:
            var args = common
            if settings.useHardware {
                args += ["-c:v", "h264_videotoolbox", "-q:v", "65"]
            } else {
                args += ["-c:v", "libx264", "-preset", "slow",
                         "-crf", String(settings.masterQuality.crf)]
            }
            args += ["-pix_fmt", "yuv420p", "-movflags", "+faststart", out.path]
            return [args]

        case .social:
            let outDur = max(effectivePlan.outputDuration(duration: info.duration), 0.01)
            let audioKbps = wantAudio ? 128.0 : 0
            let totalKbits = settings.socialTargetMB * 8_000
            let videoKbps = max(totalKbits / outDur - audioKbps, 100)
            let passLog = ClipStore.cacheRoot.appendingPathComponent("2pass-\(jobID.uuidString)").path
            // Two passes, audio kept in both: stripping it on pass one shifts the
            // video framing and x264 then rejects the stats file.
            var pass1 = common
            pass1 += ["-c:v", "libx264", "-preset", "slow", "-b:v", "\(Int(videoKbps))k",
                      "-pass", "1", "-passlogfile", passLog,
                      "-pix_fmt", "yuv420p", "-f", "mp4", "/dev/null"]
            var pass2 = common
            pass2 += ["-c:v", "libx264", "-preset", "slow", "-b:v", "\(Int(videoKbps))k",
                      "-pass", "2", "-passlogfile", passLog,
                      "-pix_fmt", "yuv420p", "-movflags", "+faststart", out.path]
            return [pass1, pass2]

        case .remux:
            fatalError("handled above")
        }
    }
}

/// Builds a finished, shareable sequence from multiple DVR clips. This uses
/// ffmpeg's concat filter rather than the concat demuxer, so input containers
/// and codecs may differ; frame dimensions must match.
enum StitchCommandBuilder {
    static func build(inputs: [(URL, ClipInfo)], settings: ExportSettings, output: URL) throws -> [String] {
        guard inputs.count > 1 else {
            throw FFmpeg.ProcessError(command: "stitch", stderr: "Select at least two clips to stitch.")
        }
        guard let reference = inputs.first?.1 else { fatalError("checked above") }
        guard inputs.allSatisfy({ $0.1.width == reference.width && $0.1.height == reference.height }) else {
            throw FFmpeg.ProcessError(command: "stitch",
                                      stderr: "All stitched clips must have the same resolution. Export them individually first if they differ.")
        }

        var args: [String] = ["-y"]
        for (url, _) in inputs { args += ["-i", url.path] }
        let videoInputs = inputs.indices.map { "[\($0):v]" }.joined()
        let allHaveAudio = settings.keepAudio && inputs.allSatisfy { $0.1.hasAudio }
        var graph = "\(videoInputs)concat=n=\(inputs.count):v=1:a=0[vcat]"
        let videoOut: String
        if settings.colorMode == .fixRange {
            graph += ";[vcat]scale=in_range=pc:out_range=tv[vout]"
            videoOut = "vout"
        } else {
            videoOut = "vcat"
        }
        if allHaveAudio {
            let audioInputs = inputs.indices.map { "[\($0):a]" }.joined()
            graph += ";\(audioInputs)concat=n=\(inputs.count):v=0:a=1[aout]"
        }
        args += ["-filter_complex", graph, "-map", "[\(videoOut)]"]
        if allHaveAudio {
            args += ["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"]
        } else {
            args += ["-an"]
        }
        if settings.colorMode == .fixRange { args += ["-color_range", "tv"] }
        switch settings.preset {
        case .edit:
            args += ["-c:v", "prores_ks", "-profile:v", settings.proResProfile.ffmpegProfile,
                     "-vendor", "apl0", "-pix_fmt", "yuv422p10le"]
        case .master, .social, .remux:
            if settings.useHardware {
                args += ["-c:v", "h264_videotoolbox", "-q:v", "65"]
            } else {
                args += ["-c:v", "libx264", "-preset", "slow",
                         "-crf", String(settings.masterQuality.crf)]
            }
            args += ["-pix_fmt", "yuv420p", "-movflags", "+faststart"]
        }
        args.append(output.path)
        return args
    }
}

// MARK: - Hardware encoder detection

enum HardwareDetect {
    /// Availability is decided by *running* a test encode, not by asking ffmpeg
    /// what it supports — a build can advertise encoders the machine lacks.
    static func videoToolboxWorks() -> Bool {
        let args = ["-y", "-f", "lavfi", "-i", "color=black:s=320x240:r=30:d=0.2",
                    "-c:v", "h264_videotoolbox", "-f", "null", "-"]
        return (try? FFmpeg.run(args)) != nil
    }
}
