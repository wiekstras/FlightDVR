import SwiftUI
import Combine

enum ColorMode: String, CaseIterable, Identifiable, Codable {
    case fixRange = "Fix levels"
    case leaveAlone = "Leave colour alone"
    var id: String { rawValue }
}

enum Preset: String, CaseIterable, Identifiable, Codable {
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

enum ProResProfile: String, CaseIterable, Identifiable, Codable {
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

enum MasterQuality: String, CaseIterable, Identifiable, Codable {
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

enum SocialProfile: String, CaseIterable, Identifiable, Codable {
    case tiktok = "TikTok"
    case instagramReel = "Instagram Reel"
    case instagramSquare = "Instagram Square Post"
    case instagramPortrait = "Instagram Portrait Post"
    case youtubeShort = "YouTube Short"
    case youtube = "YouTube"
    var id: String { rawValue }

    var canvasSize: (width: Int, height: Int) {
        switch self {
        case .tiktok, .instagramReel, .youtubeShort: (1080, 1920)
        case .instagramSquare: (1080, 1080)
        case .instagramPortrait: (1080, 1350)
        case .youtube: (1920, 1080)
        }
    }
    var aspectLabel: String {
        switch self {
        case .tiktok, .instagramReel, .youtubeShort: "9:16"
        case .instagramSquare: "1:1"
        case .instagramPortrait: "4:5"
        case .youtube: "16:9"
        }
    }
    var canvasLabel: String {
        "\(canvasSize.width) × \(canvasSize.height) · \(aspectLabel)"
    }
    var isVertical: Bool { canvasSize.height > canvasSize.width }
    var isShortVertical: Bool { canvasSize.width == 1080 && canvasSize.height == 1920 }
    func videoFilter(framing: SocialFraming, positionX: Double = 0.5,
                     positionY: Double = 0.5) -> String {
        let size = "\(canvasSize.width):\(canvasSize.height)"
        if framing == .fill {
            let x = positionX.isFinite ? min(max(positionX, 0), 1) : 0.5
            let y = positionY.isFinite ? min(max(positionY, 0), 1) : 0.5
            return String(format: "scale=%@:force_original_aspect_ratio=increase,crop=%@:(iw-ow)*%.4f:(ih-oh)*%.4f",
                          size, size, x, y)
        }
        if framing == .blurredBackground {
            return "split=2[background][foreground];" +
                "[background]scale=\(size):force_original_aspect_ratio=increase," +
                "crop=\(size),boxblur=20:2[blurred];" +
                "[foreground]scale=\(size):force_original_aspect_ratio=decrease[front];" +
                "[blurred][front]overlay=(W-w)/2:(H-h)/2"
        }
        return "scale=\(size):force_original_aspect_ratio=decrease,pad=\(size):(ow-iw)/2:(oh-ih)/2:black"
    }
}

enum SocialFraming: String, CaseIterable, Identifiable, Codable {
    case fit = "Fit entire frame"
    case blurredBackground = "Fit with blurred background"
    case fill = "Fill canvas"
    var id: String { rawValue }
}

struct ExportSettings: Codable, Equatable {
    var preset: Preset = .master
    var colorMode: ColorMode = .fixRange
    var proResProfile: ProResProfile = .standard
    var masterQuality: MasterQuality = .high
    var socialTargetMB: Double = 25
    var socialProfile: SocialProfile = .tiktok
    var socialFraming: SocialFraming = .fit
    var cropPositionX: Double = 0.5
    var cropPositionY: Double = 0.5
    var keepAudio = true
    var useHardware = false
    var outputFolder: URL?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case preset, colorMode, proResProfile, masterQuality, socialTargetMB
        case socialProfile, socialFraming, cropPositionX, cropPositionY
        case keepAudio, useHardware, outputFolder
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preset = try values.decodeIfPresent(Preset.self, forKey: .preset) ?? .master
        colorMode = try values.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .fixRange
        proResProfile = try values.decodeIfPresent(ProResProfile.self, forKey: .proResProfile) ?? .standard
        masterQuality = try values.decodeIfPresent(MasterQuality.self, forKey: .masterQuality) ?? .high
        socialTargetMB = try values.decodeIfPresent(Double.self, forKey: .socialTargetMB) ?? 25
        socialProfile = try values.decodeIfPresent(SocialProfile.self, forKey: .socialProfile) ?? .tiktok
        socialFraming = try values.decodeIfPresent(SocialFraming.self, forKey: .socialFraming) ?? .fit
        let decodedX = try values.decodeIfPresent(Double.self, forKey: .cropPositionX) ?? 0.5
        let decodedY = try values.decodeIfPresent(Double.self, forKey: .cropPositionY) ?? 0.5
        cropPositionX = decodedX.isFinite ? min(max(decodedX, 0), 1) : 0.5
        cropPositionY = decodedY.isFinite ? min(max(decodedY, 0), 1) : 0.5
        keepAudio = try values.decodeIfPresent(Bool.self, forKey: .keepAudio) ?? true
        useHardware = try values.decodeIfPresent(Bool.self, forKey: .useHardware) ?? false
        outputFolder = try values.decodeIfPresent(URL.self, forKey: .outputFolder)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preset, forKey: .preset)
        try values.encode(colorMode, forKey: .colorMode)
        try values.encode(proResProfile, forKey: .proResProfile)
        try values.encode(masterQuality, forKey: .masterQuality)
        try values.encode(socialTargetMB, forKey: .socialTargetMB)
        try values.encode(socialProfile, forKey: .socialProfile)
        try values.encode(socialFraming, forKey: .socialFraming)
        try values.encode(cropPositionX, forKey: .cropPositionX)
        try values.encode(cropPositionY, forKey: .cropPositionY)
        try values.encode(keepAudio, forKey: .keepAudio)
        try values.encode(useHardware, forKey: .useHardware)
        try values.encodeIfPresent(outputFolder, forKey: .outputFolder)
    }

    var resolvedOutputFolder: URL {
        outputFolder ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flight Studio", isDirectory: true)
    }
}

/// Produces a non-destructive export name.  A card can contain clips with the
/// same filename in different folders, and existing exports are never replaced
/// just because they were queued together.
enum OutputNamer {
    static func safeBaseName(_ name: String, fallback: String = "Untitled clip") -> String {
        let illegal = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        var normalized = ""
        for scalar in name.unicodeScalars {
            if illegal.contains(scalar) {
                if !normalized.isEmpty, normalized.last != "-" { normalized.append("-") }
            } else {
                normalized.unicodeScalars.append(scalar)
            }
        }
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-."))
        let cleaned = normalized.trimmingCharacters(in: edges)
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(180))
    }

    static func uniqueURL(in folder: URL, baseName: String, fileExtension: String,
                          reserved: Set<URL> = [],
                          fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let safeBase = safeBaseName(baseName)
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " \(index)"
            let candidate = folder.appendingPathComponent("\(safeBase)\(suffix).\(fileExtension)")
            if !reserved.contains(candidate) && !fileExists(candidate) { return candidate }
            index += 1
        }
    }
}

enum ExportOutput {
    static func stagingURL(for outputURL: URL, jobID: UUID) -> URL {
        let ext = outputURL.pathExtension
        let base = outputURL.deletingPathExtension().lastPathComponent
        return outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(base).\(jobID.uuidString).partial.\(ext)")
    }

    static func promote(stagingURL: URL, to outputURL: URL) throws {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else {
            throw FFmpeg.ProcessError(command: "export", stderr: "Encoder produced no output file.")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: outputURL)
        }
    }
}

enum CompletedExportActions {
    static func isAvailable(state: ExportState, outputInfo: ClipInfo?,
                            fileExists: Bool) -> Bool {
        guard state == .done, fileExists, let outputInfo else { return false }
        return outputInfo.duration > 0.05 && outputInfo.width > 0
            && outputInfo.height > 0 && outputInfo.fileSize > 0
    }
}

enum ExportTemporaryFiles {
    static func belongsToJob(_ url: URL, jobID: UUID) -> Bool {
        let id = jobID.uuidString
        let name = url.lastPathComponent
        return name.hasPrefix("title-\(id)-") || name.hasPrefix("2pass-\(id)-")
    }

    static func cleanup(jobID: UUID, in folder: URL = ClipStore.cacheRoot,
                        fileManager: FileManager = .default) {
        cleanup(jobIDs: [jobID], in: folder, fileManager: fileManager)
    }

    static func cleanup(jobIDs: Set<UUID>, in folder: URL = ClipStore.cacheRoot,
                        fileManager: FileManager = .default) {
        guard !jobIDs.isEmpty else { return }
        let files = (try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where jobIDs.contains(where: { belongsToJob(url, jobID: $0) }) {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum SequenceOrder {
    static func moved<T>(_ values: [T], from source: Int, to destination: Int) -> [T] {
        guard values.indices.contains(source), values.indices.contains(destination),
              source != destination else { return values }
        var copy = values
        let item = copy.remove(at: source)
        copy.insert(item, at: destination)
        return copy
    }
}

enum ExportDiskSpace {
    /// Estimate the private staging file before encoding. The margin covers
    /// container overhead and bitrate variability without blocking reasonable jobs.
    static func requiredBytes(clips: [ExportClipSnapshot], settings: ExportSettings) -> Int64 {
        let sourceBytes = clips.reduce(Int64(0)) { $0 + max($1.info?.fileSize ?? 0, 0) }
        let encodedBytes: Double
        switch settings.preset {
        case .remux:
            encodedBytes = Double(sourceBytes)
        case .social:
            encodedBytes = settings.socialTargetMB * 1_000_000
        case .edit, .master:
            encodedBytes = clips.reduce(0) { total, clip in
                guard let info = clip.info else { return total }
                let duration = max(clip.edit.outputDuration(duration: info.duration), 0)
                let pixelRateScale = Double(info.width) * Double(info.height) * max(info.fps, 1)
                    / Double(1920 * 1080 * 30)
                let mbps: Double
                if settings.preset == .edit {
                    switch settings.proResProfile {
                    case .lt: mbps = 102
                    case .standard: mbps = 147
                    case .hq: mbps = 220
                    }
                } else {
                    switch settings.masterQuality {
                    case .archive: mbps = 50
                    case .high: mbps = 35
                    case .good: mbps = 25
                    case .compact: mbps = 15
                    }
                }
                return total + duration * mbps * max(pixelRateScale, 0.25) * 1_000_000 / 8
            }
        }
        return Int64(max(encodedBytes * 1.15, 0).rounded(.up)) + 64_000_000
    }

    static func availableBytes(at destination: URL) -> Int64? {
        let folder = destination.deletingLastPathComponent()
        return try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func validationError(required: Int64, available: Int64?) -> String? {
        guard let available, available < required else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "Not enough free space to export. DVR Studio needs about \(formatter.string(fromByteCount: required)), but this volume has \(formatter.string(fromByteCount: available)) available."
    }
}

// MARK: - Jobs

enum ExportState: Equatable, Codable {
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

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable { case waiting, running, done, cancelled, failed }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .waiting: self = .waiting
        case .running: self = .running
        case .done: self = .done
        case .cancelled: self = .cancelled
        case .failed: self = .failed(try values.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .waiting: try values.encode(Kind.waiting, forKey: .kind)
        case .running: try values.encode(Kind.running, forKey: .kind)
        case .done: try values.encode(Kind.done, forKey: .kind)
        case .cancelled: try values.encode(Kind.cancelled, forKey: .kind)
        case .failed(let message):
            try values.encode(Kind.failed, forKey: .kind)
            try values.encode(message, forKey: .message)
        }
    }
}

@MainActor
final class ExportJob: ObservableObject, Identifiable {
    typealias State = ExportState
    let id: UUID
    @Published private(set) var clips: [Clip]
    let settings: ExportSettings
    let outputURL: URL
    @Published var state: State = .waiting
    @Published var progress: Double = 0      // 0…1
    @Published var outputInfo: ClipInfo?
    @Published var pendingPublishDraft: PublishDraft?
    nonisolated(unsafe) var cancelFlag = false

    var clip: Clip { clips[0] }
    var isStitch: Bool { clips.count > 1 }
    var displayName: String { isStitch ? "Sequence (\(clips.count) clips)" : clip.name }
    var outputActionsAvailable: Bool {
        CompletedExportActions.isAvailable(
            state: state, outputInfo: outputInfo,
            fileExists: FileManager.default.fileExists(atPath: outputURL.path))
    }

    var stagingURL: URL {
        ExportOutput.stagingURL(for: outputURL, jobID: id)
    }

    init(id: UUID = UUID(), clips: [Clip], settings: ExportSettings, outputURL: URL,
         state: State = .waiting, progress: Double = 0, outputInfo: ClipInfo? = nil,
         pendingPublishDraft: PublishDraft? = nil) {
        precondition(!clips.isEmpty, "an export needs at least one clip")
        self.id = id
        self.clips = clips
        self.settings = settings
        self.outputURL = outputURL
        self.state = state
        self.progress = progress
        self.outputInfo = outputInfo
        self.pendingPublishDraft = pendingPublishDraft
    }

    @discardableResult
    func replaceSource(_ source: Clip, with replacement: Clip) -> Bool {
        guard let index = clips.firstIndex(where: { $0 === source }) else { return false }
        clips[index] = replacement
        return true
    }

    var missingSources: [Clip] {
        clips.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
    }
}

enum ExportSourceRelinker {
    static func replacement(for source: Clip, url: URL, info: ClipInfo) throws -> Clip {
        let replacementURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: replacementURL.path) else {
            throw FFmpeg.ProcessError(command: "relink export", stderr: "The selected recording is unavailable.")
        }
        guard ClipStore.videoExtensions.contains(replacementURL.pathExtension.lowercased()) else {
            throw FFmpeg.ProcessError(command: "relink export", stderr: "Choose a supported video recording.")
        }
        if let expected = source.info {
            let durationTolerance = max(expected.duration * 0.01, 0.5)
            guard info.width == expected.width, info.height == expected.height,
                  abs(info.duration - expected.duration) <= durationTolerance else {
                throw FFmpeg.ProcessError(
                    command: "relink export",
                    stderr: "The selected video does not match the original recording's duration and resolution.")
            }
        }
        var editBoundaryTimes = [source.edit.inPoint]
        if let outPoint = source.edit.outPoint { editBoundaryTimes.append(outPoint) }
        for cut in source.edit.cuts { editBoundaryTimes.append(contentsOf: [cut.start, cut.end]) }
        for zone in source.edit.speedZones { editBoundaryTimes.append(contentsOf: [zone.start, zone.end]) }
        for title in source.edit.titleOverlays { editBoundaryTimes.append(contentsOf: [title.start, title.end]) }
        guard editBoundaryTimes.allSatisfy({ $0.isFinite && $0 <= info.duration + 0.05 }) else {
            throw FFmpeg.ProcessError(
                command: "relink export",
                stderr: "The replacement is shorter than the frozen queued edit.")
        }
        if let error = source.edit.validationError(duration: info.duration) {
            throw FFmpeg.ProcessError(
                command: "relink export",
                stderr: "The replacement does not contain the frozen edit: \(error)")
        }
        let replacement = Clip(
            url: replacementURL, fileDate: Clip.readFileDate(for: replacementURL),
            isLibraryBacked: false, editOverride: source.edit)
        replacement.info = info
        replacement.relativeName = replacementURL.lastPathComponent
        return replacement
    }
}

struct ExportClipSnapshot: Codable, Equatable {
    var url: URL
    var info: ClipInfo?
    var edit: EditPlan
}

struct ExportJobSnapshot: Codable, Equatable {
    var id: UUID
    var clips: [ExportClipSnapshot]
    var settings: ExportSettings
    var outputURL: URL
    var state: ExportState
    var progress: Double
    var outputInfo: ClipInfo?
    var pendingPublishDraft: PublishDraft?

    @MainActor init(job: ExportJob) {
        id = job.id
        clips = job.clips.map { ExportClipSnapshot(url: $0.url, info: $0.info, edit: $0.edit) }
        settings = job.settings
        outputURL = job.outputURL
        state = job.state
        progress = job.progress
        outputInfo = job.outputInfo
        pendingPublishDraft = job.pendingPublishDraft
    }

    init(id: UUID, clips: [ExportClipSnapshot], settings: ExportSettings, outputURL: URL,
         state: ExportState, progress: Double, outputInfo: ClipInfo? = nil,
         pendingPublishDraft: PublishDraft? = nil) {
        self.id = id
        self.clips = clips
        self.settings = settings
        self.outputURL = outputURL
        self.state = state
        self.progress = progress
        self.outputInfo = outputInfo
        self.pendingPublishDraft = pendingPublishDraft
    }

    func recoveringInterruptedEncode() -> ExportJobSnapshot {
        guard state == .running else { return self }
        var copy = self
        copy.state = .failed("Export was interrupted. The incomplete staging file was removed; retry when ready.")
        copy.progress = 0
        return copy
    }
}

private struct ExportQueueJournal: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var jobs: [ExportJobSnapshot]
}

enum DurableQueueJournal {
    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }

    static func load<Value>(from url: URL,
                            decode: (Data) throws -> Value) throws -> Value? {
        let fileManager = FileManager.default
        let backup = backupURL(for: url)
        guard fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: backup.path) else { return nil }
        if fileManager.fileExists(atPath: url.path) {
            do {
                return try decode(Data(contentsOf: url))
            } catch {
                guard fileManager.fileExists(atPath: backup.path) else { throw error }
            }
        }
        let backupData = try Data(contentsOf: backup)
        let recovered = try decode(backupData)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try backupData.write(to: url, options: .atomic)
        return recovered
    }

    static func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try data.write(to: backupURL(for: url), options: .atomic)
    }
}

enum ExportQueueStore {
    static let defaultURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlightStudio", isDirectory: true)
            .appendingPathComponent("export-queue.json")
    }()

    static func load(from url: URL) throws -> [ExportJobSnapshot] {
        let journal = try DurableQueueJournal.load(from: url) { data in
            let decoded = try JSONDecoder().decode(ExportQueueJournal.self, from: data)
            guard decoded.version == ExportQueueJournal.currentVersion else {
                throw FFmpeg.ProcessError(
                    command: "export queue",
                    stderr: "Unsupported export queue version \(decoded.version).")
            }
            return decoded
        }
        return (journal?.jobs ?? []).map { $0.recoveringInterruptedEncode() }
    }

    static func save(_ snapshots: [ExportJobSnapshot], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableQueueJournal.save(
            encoder.encode(ExportQueueJournal(jobs: snapshots)), to: url)
    }
}

@MainActor
final class ExportQueue: ObservableObject {
    @Published var jobs: [ExportJob] = []
    @Published var isRunning = false
    @Published var currentMessage = ""
    @Published private(set) var persistenceError: String?
    var publishHandoff: ((ExportJob, PublishDraft) -> Bool)?
    private let persistenceURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init(persistenceURL: URL = ExportQueueStore.defaultURL) {
        self.persistenceURL = persistenceURL
        do {
            let snapshots = try ExportQueueStore.load(from: persistenceURL)
            ExportTemporaryFiles.cleanup(jobIDs: Set(snapshots.map(\.id)))
            jobs = snapshots.compactMap { snapshot in
                guard !snapshot.clips.isEmpty else { return nil }
                let clips = snapshot.clips.map { saved -> Clip in
                    let clip = Clip(url: saved.url, fileDate: Clip.readFileDate(for: saved.url),
                                    isLibraryBacked: false, editOverride: saved.edit)
                    clip.info = saved.info
                    return clip
                }
                var state = snapshot.state
                if state == .done && !FileManager.default.fileExists(atPath: snapshot.outputURL.path) {
                    state = .failed("The completed export file is missing.")
                } else if state != .done,
                          clips.contains(where: { !FileManager.default.fileExists(atPath: $0.url.path) }) {
                    state = .failed("One or more source recordings are missing or disconnected.")
                }
                let job = ExportJob(id: snapshot.id, clips: clips, settings: snapshot.settings,
                                    outputURL: snapshot.outputURL, state: state,
                                    progress: snapshot.progress, outputInfo: snapshot.outputInfo,
                                    pendingPublishDraft: snapshot.pendingPublishDraft)
                try? FileManager.default.removeItem(at: job.stagingURL)
                return job
            }
        } catch {
            jobs = []
            persistenceError = "Export queue could not be restored: \(error.localizedDescription)"
        }
        if persistenceError == nil, !jobs.isEmpty {
            do {
                try ExportQueueStore.save(jobs.map { ExportJobSnapshot(job: $0) },
                                          to: persistenceURL)
            } catch {
                persistenceError = "Recovered export queue could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func enqueue(clips: [Clip], settings: ExportSettings) {
        let folder = settings.resolvedOutputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for clip in clips {
            let base = clip.url.deletingPathExtension().lastPathComponent
            let out = OutputNamer.uniqueURL(in: folder, baseName: base,
                                             fileExtension: settings.preset.fileExtension,
                                             reserved: Set(jobs.map(\.outputURL)))
            let variant = Clip.exportVariant(from: clip, edit: clip.edit)
            jobs.append(ExportJob(clips: [variant], settings: settings, outputURL: out))
        }
        persist()
    }

    func enqueueForPublishing(clip: Clip, settings: ExportSettings,
                              draft: PublishDraft) -> [PublishIssue] {
        let issues = PublishValidator.validate(draft: draft, settings: settings)
        guard !issues.contains(where: { $0.severity == .error }) else { return issues }
        let folder = settings.resolvedOutputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = clip.url.deletingPathExtension().lastPathComponent
        let out = OutputNamer.uniqueURL(in: folder, baseName: base,
                                        fileExtension: settings.preset.fileExtension,
                                        reserved: Set(jobs.map(\.outputURL)))
        // Freeze the non-destructive edit now. The creator can keep working
        // without changing an export that is already queued for publishing.
        let variant = Clip.exportVariant(from: clip, edit: clip.edit)
        jobs.append(ExportJob(clips: [variant], settings: settings, outputURL: out,
                              pendingPublishDraft: draft))
        persist()
        start()
        return issues
    }

    /// Called after the app wires both durable queues together. Completed
    /// exports may still have a handoff after a crash between encode and upload.
    func resumePublishHandoffs() {
        for job in jobs where job.state == .done && job.pendingPublishDraft != nil {
            attemptPublishHandoff(job)
        }
    }

    func enqueueHighlights(from clip: Clip, settings: ExportSettings) {
        guard !clip.highlights.isEmpty else { return }
        let folder = settings.resolvedOutputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceName = clip.url.deletingPathExtension().lastPathComponent
        var reserved = Set(jobs.map(\.outputURL))
        for highlight in clip.highlights {
            let variant = Clip.exportVariant(from: clip, edit: highlight.edit)
            let base = OutputNamer.safeBaseName("\(sourceName) – \(highlight.name)")
            let out = OutputNamer.uniqueURL(in: folder, baseName: base,
                                             fileExtension: settings.preset.fileExtension,
                                             reserved: reserved)
            reserved.insert(out)
            jobs.append(ExportJob(clips: [variant], settings: settings, outputURL: out))
        }
        persist()
    }

    /// Join selected edits in their current order. Stitching deliberately
    /// re-encodes, so differing source codecs are fine; matching dimensions are
    /// required for a clean timeline and Remux falls back to Master H.264.
    func enqueueStitch(clips: [Clip], settings: ExportSettings) {
        guard clips.count > 1 else { return }
        let folder = settings.resolvedOutputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stitchSettings = settings
        if stitchSettings.preset == .remux {
            stitchSettings.preset = .master
        }
        let out = OutputNamer.uniqueURL(in: folder, baseName: "Flight sequence",
                                        fileExtension: stitchSettings.preset.fileExtension,
                                        reserved: Set(jobs.map(\.outputURL)))
        let variants = clips.map { Clip.exportVariant(from: $0, edit: $0.edit) }
        jobs.append(ExportJob(clips: variants, settings: stitchSettings, outputURL: out))
        persist()
    }

    func remove(_ job: ExportJob) {
        if job.state == .running { job.cancelFlag = true }
        try? FileManager.default.removeItem(at: job.stagingURL)
        jobs.removeAll { $0.id == job.id }
        persist()
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled }
        persist()
    }

    func clearFailed() {
        jobs.removeAll { $0.state.isFailure }
        persist()
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
        objectWillChange.send()
        persist()
    }

    /// Put a cancelled or failed job back in the queue without making the user
    /// reselect its clip and export settings.
    func retry(_ job: ExportJob) {
        guard job.state.canRetry, job.missingSources.isEmpty else { return }
        job.cancelFlag = false
        job.progress = 0
        job.outputInfo = nil
        job.state = .waiting
        try? FileManager.default.removeItem(at: job.stagingURL)
        objectWillChange.send()
        persist()
    }

    /// Replace a missing queued source without losing the edit frozen when the
    /// job was created. Probe first so an unrelated or truncated recording can
    /// never silently enter the export pipeline.
    func relinkSource(_ source: Clip, in job: ExportJob, to replacementURL: URL) async {
        guard job.state.canRetry, job.missingSources.contains(where: { $0 === source }) else { return }
        do {
            let info = try await Task.detached(priority: .userInitiated) {
                try Probe.probe(replacementURL)
            }.value
            let replacement = try ExportSourceRelinker.replacement(
                for: source, url: replacementURL, info: info)
            guard job.replaceSource(source, with: replacement) else { return }
            job.outputInfo = nil
            job.progress = 0
            if job.missingSources.isEmpty {
                job.state = .waiting
                persist()
                start()
            } else {
                job.state = .failed("Relinked \(source.name). \(job.missingSources.count) source recording(s) still missing.")
                persist()
            }
        } catch {
            job.state = .failed("Could not relink \(source.name): \(error.localizedDescription)")
            persist()
        }
    }

    /// Move a waiting export relative to the other waiting jobs. Completed and
    /// failed entries stay in place so their status remains easy to inspect.
    func moveWaiting(_ job: ExportJob, by offset: Int) {
        let waitingIndices = jobs.indices.filter { jobs[$0].state == .waiting }
        guard let current = waitingIndices.firstIndex(where: { jobs[$0].id == job.id }) else { return }
        let destination = current + offset
        guard waitingIndices.indices.contains(destination) else { return }
        jobs.swapAt(waitingIndices[current], waitingIndices[destination])
        persist()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await runLoop() }
    }

    private func runLoop() async {
        while let job = jobs.first(where: { $0.state == .waiting }) {
            job.state = .running
            job.progress = 0
            job.outputInfo = nil
            objectWillChange.send()
            try? FileManager.default.removeItem(at: job.stagingURL)
            persist()
            currentMessage = "Exporting \(job.displayName)…"
            do {
                try await runJob(job)
                if job.cancelFlag { throw CancellationError() }
                job.outputInfo = try await verifyStagingOutput(for: job)
                try promoteStagingOutput(for: job)
                job.state = .done
                job.progress = 1
                attemptPublishHandoff(job)
            } catch is CancellationError {
                job.state = .cancelled
                try? FileManager.default.removeItem(at: job.stagingURL)
            } catch {
                job.state = .failed(error.localizedDescription)
                try? FileManager.default.removeItem(at: job.stagingURL)
            }
            objectWillChange.send()
            persist()
        }
        isRunning = false
        currentMessage = ""
    }

    private func attemptPublishHandoff(_ job: ExportJob) {
        guard let draft = job.pendingPublishDraft, let publishHandoff,
              publishHandoff(job, draft) else { return }
        job.pendingPublishDraft = nil
        persist()
    }

    /// The final filename is never exposed until ffmpeg has completed. Existing
    /// exports remain intact if a replacement encode fails or the app crashes.
    private func promoteStagingOutput(for job: ExportJob) throws {
        try ExportOutput.promote(stagingURL: job.stagingURL, to: job.outputURL)
    }

    private func verifyStagingOutput(for job: ExportJob) async throws -> ClipInfo {
        let stagingURL = job.stagingURL
        let info = try await Task.detached(priority: .userInitiated) {
            try Probe.probe(stagingURL)
        }.value
        guard info.duration > 0.05, info.width > 0, info.height > 0,
              info.fileSize > 0, info.videoCodec != "?" else {
            throw FFmpeg.ProcessError(command: "verify export",
                                      stderr: "The encoded file could not be verified as playable video.")
        }
        return info
    }

    private func runJob(_ job: ExportJob) async throws {
        defer { ExportTemporaryFiles.cleanup(jobID: job.id) }
        let snapshots = job.clips.map {
            ExportClipSnapshot(url: $0.url, info: $0.info, edit: $0.edit)
        }
        let required = ExportDiskSpace.requiredBytes(clips: snapshots, settings: job.settings)
        if let error = ExportDiskSpace.validationError(
            required: required,
            available: ExportDiskSpace.availableBytes(at: job.outputURL)) {
            throw FFmpeg.ProcessError(command: "export preflight", stderr: error)
        }
        // Overwrite protection applies equally to single clips and stitches.
        if FileManager.default.fileExists(atPath: job.outputURL.path) {
            let replaced = job.outputURL
            let alert = NSAlert()
            alert.messageText = "\(replaced.lastPathComponent) already exists"
            alert.informativeText = "Replace it after the new export finishes, or skip this job?"
            alert.addButton(withTitle: "Replace After Export")
            alert.addButton(withTitle: "Skip")
            if alert.runModal() != .alertFirstButtonReturn {
                throw CancellationError()
            }
        }
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

        let commands = ExportCommandBuilder.build(
            plan: plan, settings: settings, info: info,
            source: job.clip.url, output: job.stagingURL, jobID: job.id)
        let passes = Double(commands.count)
        for (index, args) in commands.enumerated() {
            let passBase = Double(index) / passes
            _ = try await Task.detached(priority: .userInitiated) { [cancel = job] () throws in
                try FFmpeg.run(args, onProgressSeconds: { seconds in
                    let p = passBase + min(seconds / outDur, 1) / passes
                    Task { @MainActor in
                        cancel.progress = p
                        self.schedulePersistence()
                    }
                }, isCancelled: { cancel.cancelFlag })
            }.value
        }
    }

    private func runStitchJob(_ job: ExportJob) async throws {
        let clips = try job.clips.map { clip -> ExportClipSnapshot in
            guard let info = clip.info else {
                throw FFmpeg.ProcessError(command: "", stderr: "\(clip.name) was never probed — rescan and try again.")
            }
            if let error = clip.edit.validationError(duration: info.duration) {
                throw FFmpeg.ProcessError(command: "stitch", stderr: "\(clip.name): \(error)")
            }
            return ExportClipSnapshot(url: clip.url, info: info, edit: clip.edit)
        }
        let totalDuration = max(clips.reduce(0) {
            $0 + $1.edit.outputDuration(duration: $1.info?.duration ?? 0)
        }, 0.01)
        let commands = try StitchCommandBuilder.build(clips: clips, settings: job.settings,
                                                       output: job.stagingURL, jobID: job.id)
        let passes = Double(commands.count)
        for (index, args) in commands.enumerated() {
            let passBase = Double(index) / passes
            _ = try await Task.detached(priority: .userInitiated) { [cancel = job] () throws in
                try FFmpeg.run(args, onProgressSeconds: { seconds in
                    Task { @MainActor in
                        cancel.progress = passBase + min(seconds / totalDuration, 1) / passes
                        self.schedulePersistence()
                    }
                }, isCancelled: { cancel.cancelFlag })
            }.value
        }
    }

    private func schedulePersistence() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persist() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func persist() {
        saveWorkItem?.cancel()
        do {
            try ExportQueueStore.save(jobs.map { ExportJobSnapshot(job: $0) }, to: persistenceURL)
            persistenceError = nil
        } catch {
            persistenceError = "Export queue could not be saved: \(error.localizedDescription)"
        }
    }

}

/// Turns a clip + edit plan + settings into complete ffmpeg invocations.
/// Pure and headless, so the GUI queue and --selftest share the same path.
enum ExportCommandBuilder {
    static func titleAssetURL(jobID: UUID, index: Int = 0) -> URL {
        ClipStore.cacheRoot.appendingPathComponent("title-\(jobID.uuidString)-\(index).png")
    }

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
        let safePlan = effectivePlan.sanitized(duration: info.duration)
        let wantAudio = settings.keepAudio && (info.hasAudio || plan.music != nil)
        var inputs: [String] = ["-i", src.path]
        if let music = safePlan.music {
            inputs += ["-stream_loop", "-1", "-i", music.url.path]
        }
        var titleInputIndices: [Int] = []
        var nextInputIndex = safePlan.music == nil ? 1 : 2
        for (titleIndex, title) in safePlan.titleOverlays.enumerated() {
            let url = titleAssetURL(jobID: jobID, index: titleIndex)
            let canvas = settings.preset == .social
                ? settings.socialProfile.canvasSize : (info.width, info.height)
            _ = TitleImageRenderer.write(title.text, canvasWidth: canvas.0,
                                         canvasHeight: canvas.1, to: url)
            // Always include the expected asset. A filesystem/rendering failure
            // then produces an explicit failed job instead of silently omitting text.
            titleInputIndices.append(nextInputIndex)
            nextInputIndex += 1
            inputs += ["-loop", "1", "-i", url.path]
        }
        let graph = FilterGraphBuilder.build(plan: effectivePlan, duration: info.duration,
                                             sourceHasAudio: settings.keepAudio && info.hasAudio,
                                             fixColorRange: fixRange,
                                             outputVideoFilter: settings.preset == .social
                                                ? settings.socialProfile.videoFilter(
                                                    framing: settings.socialFraming,
                                                    positionX: settings.cropPositionX,
                                                    positionY: settings.cropPositionY) : nil,
                                             titleInputIndices: titleInputIndices)

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
            let audioKbps = wantAudio ? 192.0 : 0
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

private enum TitleImageRenderer {
    static func write(_ text: String, canvasWidth: Int, canvasHeight: Int,
                      to url: URL) -> Bool {
        let safeWidth = max(canvasWidth, 320)
        let safeHeight = max(canvasHeight, 240)
        let fontSize = min(max(CGFloat(safeHeight) * 0.06, 24), 144)
        let horizontalPadding = max(fontSize * 0.4, 12)
        let verticalPadding = max(fontSize * 0.25, 8)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let measured = string.boundingRect(with: NSSize(width: CGFloat(safeWidth) * 0.85,
                                                        height: CGFloat(safeHeight) * 0.25),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: ceil(measured.width) + horizontalPadding * 2,
                          height: ceil(measured.height) + verticalPadding * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: max(Int(size.width), 1),
                                             pixelsHigh: max(Int(size.height), 1),
                                             bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.withAlphaComponent(0.58).setFill()
        let radius = max(fontSize * 0.14, 6)
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                     xRadius: radius, yRadius: radius).fill()
        string.draw(in: NSRect(x: horizontalPadding, y: verticalPadding,
                               width: size.width - horizontalPadding * 2,
                               height: size.height - verticalPadding * 2))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Builds a finished, shareable sequence from multiple DVR clips. This uses
/// ffmpeg's concat filter rather than the concat demuxer, so input containers
/// and codecs may differ; frame dimensions must match.
enum StitchCommandBuilder {
    static func build(clips: [ExportClipSnapshot], settings: ExportSettings,
                      output: URL, jobID: UUID) throws -> [[String]] {
        guard clips.count > 1 else {
            throw FFmpeg.ProcessError(command: "stitch", stderr: "Select at least two clips to stitch.")
        }
        guard let reference = clips.first?.info else {
            throw FFmpeg.ProcessError(command: "stitch", stderr: "Clip metadata is not ready.")
        }
        guard clips.allSatisfy({ $0.info?.width == reference.width && $0.info?.height == reference.height }) else {
            throw FFmpeg.ProcessError(command: "stitch",
                                      stderr: "All stitched clips must have the same resolution. Export them individually first if they differ.")
        }

        var args: [String] = ["-y"]
        var graphs: [FilterGraphBuilder.Graph] = []
        var nextInputIndex = 0
        var titleAssetIndex = 0
        for (clipIndex, clip) in clips.enumerated() {
            guard let info = clip.info else {
                throw FFmpeg.ProcessError(command: "stitch", stderr: "Clip metadata is not ready.")
            }
            let plan = clip.edit.sanitized(duration: info.duration)
            let sourceInputIndex = nextInputIndex
            args += ["-i", clip.url.path]
            nextInputIndex += 1
            var musicInputIndex = nextInputIndex
            if let music = plan.music, settings.keepAudio {
                args += ["-stream_loop", "-1", "-i", music.url.path]
                musicInputIndex = nextInputIndex
                nextInputIndex += 1
            }
            var titleInputIndices: [Int] = []
            for title in plan.titleOverlays {
                let url = ExportCommandBuilder.titleAssetURL(jobID: jobID, index: titleAssetIndex)
                titleAssetIndex += 1
                _ = TitleImageRenderer.write(title.text, canvasWidth: info.width,
                                             canvasHeight: info.height, to: url)
                titleInputIndices.append(nextInputIndex)
                args += ["-loop", "1", "-i", url.path]
                nextInputIndex += 1
            }
            var effectivePlan = plan
            if !settings.keepAudio { effectivePlan.music = nil }
            graphs.append(FilterGraphBuilder.build(
                plan: effectivePlan, duration: info.duration,
                sourceHasAudio: settings.keepAudio && info.hasAudio,
                fixColorRange: false, titleInputIndices: titleInputIndices,
                sourceInputIndex: sourceInputIndex, musicInputIndex: musicInputIndex,
                labelPrefix: "s\(clipIndex)_"))
        }
        var graphLines = graphs.map(\.filterComplex)
        var videoInputs: [String] = []
        for (index, graph) in graphs.enumerated() {
            let normalized = "s\(index)_vnorm"
            graphLines.append("[\(graph.videoLabel)]settb=AVTB,setpts=PTS-STARTPTS,setsar=1[\(normalized)]")
            videoInputs.append("[\(normalized)]")
        }
        graphLines.append("\(videoInputs.joined())concat=n=\(clips.count):v=1:a=0[vcat]")
        let videoOut: String
        if settings.colorMode == .fixRange {
            graphLines.append("[vcat]scale=in_range=pc:out_range=tv[vout]")
            videoOut = "vout"
        } else {
            videoOut = "vcat"
        }
        var deliveryVideoOut = videoOut
        if settings.preset == .social {
            let deliveryFilter = settings.socialProfile.videoFilter(
                framing: settings.socialFraming, positionX: settings.cropPositionX,
                positionY: settings.cropPositionY)
            graphLines.append("[\(videoOut)]\(deliveryFilter)[vdelivery]")
            deliveryVideoOut = "vdelivery"
        }
        let wantsAudio = settings.keepAudio && graphs.contains { $0.audioLabel != nil }
        if wantsAudio {
            var audioInputs: [String] = []
            for (index, graph) in graphs.enumerated() {
                if let audio = graph.audioLabel {
                    let normalized = "s\(index)_anorm"
                    graphLines.append("[\(audio)]aformat=sample_rates=48000:channel_layouts=stereo,asetpts=PTS-STARTPTS[\(normalized)]")
                    audioInputs.append("[\(normalized)]")
                } else {
                    let duration = clips[index].edit.outputDuration(
                        duration: clips[index].info?.duration ?? 0)
                    let silence = "s\(index)_silence"
                    graphLines.append(String(format:
                        "anullsrc=r=48000:cl=stereo,atrim=0:%.4f,asetpts=PTS-STARTPTS[%@]",
                        duration, silence))
                    audioInputs.append("[\(silence)]")
                }
            }
            graphLines.append("\(audioInputs.joined())concat=n=\(clips.count):v=0:a=1[aout]")
        }
        args += ["-filter_complex", graphLines.filter { !$0.isEmpty }.joined(separator: ";"),
                 "-map", "[\(deliveryVideoOut)]"]
        if wantsAudio {
            args += ["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"]
        } else {
            args += ["-an"]
        }
        if settings.colorMode == .fixRange { args += ["-color_range", "tv"] }
        let common = args
        switch settings.preset {
        case .edit:
            var command = common
            command += ["-c:v", "prores_ks", "-profile:v", settings.proResProfile.ffmpegProfile,
                        "-vendor", "apl0", "-pix_fmt", "yuv422p10le", output.path]
            return [command]
        case .master, .remux:
            var command = common
            if settings.useHardware {
                command += ["-c:v", "h264_videotoolbox", "-q:v", "65"]
            } else {
                command += ["-c:v", "libx264", "-preset", "slow",
                            "-crf", String(settings.masterQuality.crf)]
            }
            command += ["-pix_fmt", "yuv420p", "-movflags", "+faststart", output.path]
            return [command]
        case .social:
            let duration = max(clips.reduce(0) {
                $0 + $1.edit.outputDuration(duration: $1.info?.duration ?? 0)
            }, 0.01)
            let audioKbps = wantsAudio ? 192.0 : 0
            let videoKbps = max(settings.socialTargetMB * 8_000 / duration - audioKbps, 100)
            let passLog = ClipStore.cacheRoot
                .appendingPathComponent("2pass-\(jobID.uuidString)").path
            var pass1 = common
            pass1 += ["-c:v", "libx264", "-preset", "slow", "-b:v", "\(Int(videoKbps))k",
                      "-pass", "1", "-passlogfile", passLog,
                      "-pix_fmt", "yuv420p", "-f", "mp4", "/dev/null"]
            var pass2 = common
            pass2 += ["-c:v", "libx264", "-preset", "slow", "-b:v", "\(Int(videoKbps))k",
                      "-pass", "2", "-passlogfile", passLog,
                      "-pix_fmt", "yuv420p", "-movflags", "+faststart", output.path]
            return [pass1, pass2]
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
