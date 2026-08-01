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

struct ExportSettings {
    var preset: Preset = .master
    var colorMode: ColorMode = .fixRange
    var proResProfile: ProResProfile = .standard
    var masterQuality: MasterQuality = .high
    var socialTargetMB: Double = 25
    var keepAudio = true
    var useHardware = false
    var outputFolder: URL?
}

// MARK: - Jobs

@MainActor
final class ExportJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting, running, done, cancelled
        case failed(String)
    }
    let id = UUID()
    let clip: Clip
    let settings: ExportSettings
    let outputURL: URL
    @Published var state: State = .waiting
    @Published var progress: Double = 0      // 0…1
    nonisolated(unsafe) var cancelFlag = false

    init(clip: Clip, settings: ExportSettings, outputURL: URL) {
        self.clip = clip
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
        let folder = settings.outputFolder
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Flight Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for clip in clips {
            let base = clip.url.deletingPathExtension().lastPathComponent
            let out = folder.appendingPathComponent("\(base).\(settings.preset.fileExtension)")
            // Never queue the same output twice.
            if jobs.contains(where: { $0.outputURL == out && $0.state != .failed("") }) { continue }
            jobs.append(ExportJob(clip: clip, settings: settings, outputURL: out))
        }
    }

    func remove(_ job: ExportJob) {
        if job.state == .running { job.cancelFlag = true }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled }
    }

    func cancel(_ job: ExportJob) { job.cancelFlag = true }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await runLoop() }
    }

    private func runLoop() async {
        while let job = jobs.first(where: { $0.state == .waiting }) {
            job.state = .running
            currentMessage = "Exporting \(job.clip.name)…"
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
        guard let info = job.clip.info else {
            throw FFmpeg.ProcessError(command: "", stderr: "Clip was never probed — rescan and try again.")
        }
        let plan = job.clip.edit
        let settings = job.settings
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
            try await Task.detached(priority: .userInitiated) { [cancel = job] () throws in
                try FFmpeg.run(args, onProgressSeconds: { seconds in
                    let p = passBase + min(seconds / outDur, 1) / passes
                    Task { @MainActor in cancel.progress = p }
                }, isCancelled: { cancel.cancelFlag })
            }.value
        }
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
                                             fixColorRange: fixRange)

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
