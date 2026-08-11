import Foundation
import Combine

enum PublishingPlatform: String, CaseIterable, Identifiable, Codable, Hashable {
    case youtube = "YouTube"
    case tiktok = "TikTok"
    case instagram = "Instagram"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .youtube: "play.rectangle.fill"
        case .tiktok: "music.note"
        case .instagram: "camera"
        }
    }
}

enum PublishVisibility: String, CaseIterable, Identifiable, Codable {
    case publicVideo = "Public"
    case unlisted = "Unlisted"
    case privateOnly = "Private"
    var id: String { rawValue }
}

struct PublishDraft: Codable, Equatable {
    var title = ""
    var caption = ""
    var hashtags = ""
    var visibility: PublishVisibility = .privateOnly
    var platforms: Set<PublishingPlatform> = []

    var fullCaption: String {
        [caption.trimmingCharacters(in: .whitespacesAndNewlines),
         hashtags.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

enum PublishDraftStore {
    static let defaultKey = "publishComposerDraft-v1"

    static func load(defaults: UserDefaults = .standard,
                     key: String = defaultKey) -> PublishDraft {
        guard let data = defaults.data(forKey: key),
              let draft = try? JSONDecoder().decode(PublishDraft.self, from: data)
        else { return PublishDraft() }
        return draft
    }

    static func save(_ draft: PublishDraft, defaults: UserDefaults = .standard,
                     key: String = defaultKey) {
        if let data = try? JSONEncoder().encode(draft) {
            defaults.set(data, forKey: key)
        }
    }
}

struct PublishIssue: Identifiable, Equatable {
    enum Severity: Equatable { case error, warning }
    let id = UUID()
    let severity: Severity
    let message: String
}

/// Validates the planned output before anything is encoded or uploaded. The
/// checks are conservative so providers can add requirements independently.
enum PublishValidator {
    static func validate(draft: PublishDraft, settings: ExportSettings,
                         media: ClipInfo? = nil, fileExists: Bool? = nil) -> [PublishIssue] {
        var issues: [PublishIssue] = []
        if draft.platforms.isEmpty {
            issues.append(PublishIssue(severity: .error, message: "Choose at least one platform."))
        }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PublishIssue(severity: .error, message: "Add a title before publishing."))
        }
        if settings.preset == .remux {
            issues.append(PublishIssue(severity: .error,
                                       message: "Remux exports are not delivery-safe; choose Master or Social."))
        }
        if fileExists == false {
            issues.append(PublishIssue(severity: .error,
                                       message: "The exported video is missing."))
        }
        if fileExists == true, media == nil {
            issues.append(PublishIssue(severity: .error,
                                       message: "The exported video has not been verified yet."))
        }
        if let media {
            if media.duration <= 0.05 || media.width <= 0 || media.height <= 0 || media.fileSize <= 0 {
                issues.append(PublishIssue(severity: .error,
                                           message: "The exported video could not be verified as playable."))
            }
            if settings.preset == .social {
                let expected = settings.socialProfile.isVertical ? (1080, 1920) : (1920, 1080)
                if media.width != expected.0 || media.height != expected.1 {
                    issues.append(PublishIssue(
                        severity: .error,
                        message: "The export is \(media.width)×\(media.height), expected \(expected.0)×\(expected.1)."))
                }
                if media.videoCodec != "h264" {
                    issues.append(PublishIssue(severity: .error,
                                               message: "Social delivery requires an H.264 export."))
                }
            }
        }
        let vertical = settings.preset == .social && settings.socialProfile.isVertical
        if (draft.platforms.contains(.tiktok) || draft.platforms.contains(.instagram)) && !vertical {
            issues.append(PublishIssue(severity: .error,
                                       message: "TikTok and Instagram require a 9:16 Social export."))
        }
        if draft.platforms.contains(.youtube), settings.preset == .social, settings.socialProfile.isVertical {
            issues.append(PublishIssue(severity: .warning,
                                       message: "This will publish as a vertical YouTube Short."))
        }
        if draft.fullCaption.count > 2_200, draft.platforms.contains(.instagram) {
            issues.append(PublishIssue(severity: .warning,
                                       message: "Instagram captions may be truncated above 2,200 characters."))
        }
        return issues
    }
}

protocol PublishingProvider {
    var platform: PublishingPlatform { get }
    func connectionStatus() async -> ProviderConnectionStatus
    func upload(file: URL, draft: PublishDraft,
                progress: @escaping @Sendable (Double) -> Void) async throws
}

enum ProviderConnectionStatus: Equatable {
    case disconnected
    case connected(accountName: String)
    case unavailable(reason: String)
}

/// Provider implementations intentionally start unavailable. Official OAuth
/// client IDs, redirect URLs and Keychain-backed tokens belong in replaceable
/// implementations once each platform integration is provisioned.
struct UnconfiguredPublishingProvider: PublishingProvider {
    let platform: PublishingPlatform
    func connectionStatus() async -> ProviderConnectionStatus {
        .unavailable(reason: "\(platform.rawValue) publishing has not been configured yet.")
    }
    func upload(file: URL, draft: PublishDraft,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        throw FFmpeg.ProcessError(command: "publish",
                                  stderr: "\(platform.rawValue) publishing is not configured.")
    }
}

enum PublishState: Equatable, Codable {
    case queued, waitingForConnection, uploading, uploaded, cancelled
    case failed(String)

    private enum CodingKeys: String, CodingKey { case kind, message }
    private enum Kind: String, Codable {
        case queued, waitingForConnection, uploading, uploaded, cancelled, failed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .queued: self = .queued
        case .waitingForConnection: self = .waitingForConnection
        case .uploading: self = .uploading
        case .uploaded: self = .uploaded
        case .cancelled: self = .cancelled
        case .failed: self = .failed(try values.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try values.encode(Kind.queued, forKey: .kind)
        case .waitingForConnection: try values.encode(Kind.waitingForConnection, forKey: .kind)
        case .uploading: try values.encode(Kind.uploading, forKey: .kind)
        case .uploaded: try values.encode(Kind.uploaded, forKey: .kind)
        case .cancelled: try values.encode(Kind.cancelled, forKey: .kind)
        case .failed(let message):
            try values.encode(Kind.failed, forKey: .kind)
            try values.encode(message, forKey: .message)
        }
    }
}

@MainActor
final class PublishJob: ObservableObject, Identifiable {
    typealias State = PublishState

    let id: UUID
    let exportURL: URL
    let settings: ExportSettings
    let draft: PublishDraft
    @Published var states: [PublishingPlatform: State]
    @Published var progress: [PublishingPlatform: Double] = [:]

    init(id: UUID = UUID(), exportURL: URL, settings: ExportSettings, draft: PublishDraft,
         states: [PublishingPlatform: State]? = nil,
         progress: [PublishingPlatform: Double] = [:]) {
        self.id = id
        self.exportURL = exportURL
        self.settings = settings
        self.draft = draft
        self.states = states ?? Dictionary(uniqueKeysWithValues: draft.platforms.map { ($0, .queued) })
        self.progress = progress
    }
}

struct PublishJobSnapshot: Codable, Equatable {
    var id: UUID
    var exportURL: URL
    var settings: ExportSettings
    var draft: PublishDraft
    var states: [PublishingPlatform: PublishState]
    var progress: [PublishingPlatform: Double]

    init(id: UUID, exportURL: URL, settings: ExportSettings, draft: PublishDraft,
         states: [PublishingPlatform: PublishState],
         progress: [PublishingPlatform: Double]) {
        self.id = id
        self.exportURL = exportURL
        self.settings = settings
        self.draft = draft
        self.states = states
        self.progress = progress
    }

    @MainActor init(job: PublishJob) {
        id = job.id
        exportURL = job.exportURL
        settings = job.settings
        draft = job.draft
        states = job.states
        progress = job.progress
    }

    /// A process cannot resume an arbitrary provider request. Preserve completed
    /// destinations, but make an interrupted destination explicitly retryable.
    func recoveringInterruptedUploads() -> PublishJobSnapshot {
        var copy = self
        for (platform, state) in copy.states where state == .uploading {
            copy.states[platform] = .failed("Upload was interrupted. Retry when connected.")
        }
        return copy
    }
}

enum PublishQueueStore {
    static let defaultURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlightStudio", isDirectory: true)
            .appendingPathComponent("publish-queue.json")
    }()

    static func load(from url: URL) throws -> [PublishJobSnapshot] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let snapshots = try JSONDecoder().decode([PublishJobSnapshot].self, from: data)
        return snapshots.map { $0.recoveringInterruptedUploads() }
    }

    static func save(_ snapshots: [PublishJobSnapshot], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshots).write(to: url, options: .atomic)
    }
}

@MainActor
final class PublishQueue: ObservableObject {
    @Published var jobs: [PublishJob] = []
    @Published private(set) var persistenceError: String?

    private let providers: [PublishingPlatform: any PublishingProvider]
    private let persistenceURL: URL
    private var saveWorkItem: DispatchWorkItem?
    private struct UploadKey: Hashable {
        let jobID: UUID
        let platform: PublishingPlatform
    }
    private var uploadTasks: [UploadKey: Task<Void, Never>] = [:]

    init(persistenceURL: URL = PublishQueueStore.defaultURL,
         providers: [PublishingPlatform: any PublishingProvider]? = nil) {
        self.persistenceURL = persistenceURL
        self.providers = providers ?? Dictionary(
            uniqueKeysWithValues: PublishingPlatform.allCases.map {
                ($0, UnconfiguredPublishingProvider(platform: $0) as any PublishingProvider)
            }
        )
        do {
            jobs = try PublishQueueStore.load(from: persistenceURL).map {
                PublishJob(id: $0.id, exportURL: $0.exportURL, settings: $0.settings,
                           draft: $0.draft, states: $0.states, progress: $0.progress)
            }
        } catch {
            jobs = []
            persistenceError = "Publishing queue could not be restored: \(error.localizedDescription)"
        }
    }

    func enqueue(export: ExportJob, draft: PublishDraft) -> [PublishIssue] {
        let issues = PublishValidator.validate(
            draft: draft, settings: export.settings, media: export.outputInfo,
            fileExists: FileManager.default.fileExists(atPath: export.outputURL.path))
        guard !issues.contains(where: { $0.severity == .error }) else { return issues }
        jobs.append(PublishJob(exportURL: export.outputURL, settings: export.settings, draft: draft))
        persist()
        return issues
    }

    func start(_ job: PublishJob) {
        guard FileManager.default.fileExists(atPath: job.exportURL.path) else {
            for platform in job.draft.platforms where job.states[platform] != .uploaded {
                job.states[platform] = .failed("Export file is missing.")
            }
            persist()
            return
        }
        for platform in job.draft.platforms {
            guard job.states[platform] != .uploaded, job.states[platform] != .uploading else { continue }
            guard let provider = providers[platform] else { continue }
            let key = UploadKey(jobID: job.id, platform: platform)
            uploadTasks[key] = Task { [weak self, weak job] in
                guard let self, let job else { return }
                defer { uploadTasks[key] = nil }
                switch await provider.connectionStatus() {
                case .connected:
                    job.states[platform] = .uploading
                    persist()
                    do {
                        try await provider.upload(file: job.exportURL, draft: job.draft) { progress in
                            Task { @MainActor in
                                job.progress[platform] = min(max(progress, 0), 1)
                                self.schedulePersistence()
                            }
                        }
                        try Task.checkCancellation()
                        job.progress[platform] = 1
                        job.states[platform] = .uploaded
                    } catch is CancellationError {
                        job.states[platform] = .cancelled
                    } catch {
                        job.states[platform] = .failed(error.localizedDescription)
                    }
                case .disconnected:
                    job.states[platform] = .waitingForConnection
                case .unavailable(let reason):
                    job.states[platform] = .failed(reason)
                }
                persist()
            }
        }
    }

    func cancel(_ job: PublishJob, platform: PublishingPlatform) {
        let key = UploadKey(jobID: job.id, platform: platform)
        uploadTasks[key]?.cancel()
        uploadTasks[key] = nil
        guard job.states[platform] != .uploaded else { return }
        job.states[platform] = .cancelled
        persist()
    }

    func remove(_ job: PublishJob) {
        for platform in job.draft.platforms {
            uploadTasks[UploadKey(jobID: job.id, platform: platform)]?.cancel()
            uploadTasks[UploadKey(jobID: job.id, platform: platform)] = nil
        }
        jobs.removeAll { $0.id == job.id }
        persist()
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
            try PublishQueueStore.save(jobs.map { PublishJobSnapshot(job: $0) }, to: persistenceURL)
            persistenceError = nil
        } catch {
            persistenceError = "Publishing queue could not be saved: \(error.localizedDescription)"
        }
    }
}
