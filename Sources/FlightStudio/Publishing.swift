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

struct PublishIssue: Identifiable, Equatable {
    enum Severity: Equatable { case error, warning }
    let id = UUID()
    let severity: Severity
    let message: String
}

/// Validates the planned output before anything is encoded or uploaded. The
/// checks are conservative so providers can add requirements independently.
enum PublishValidator {
    static func validate(draft: PublishDraft, settings: ExportSettings) -> [PublishIssue] {
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

@MainActor
final class PublishJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued, waitingForConnection, uploading, uploaded, cancelled
        case failed(String)
    }

    let id = UUID()
    let exportURL: URL
    let settings: ExportSettings
    let draft: PublishDraft
    @Published var states: [PublishingPlatform: State]
    @Published var progress: [PublishingPlatform: Double] = [:]

    init(exportURL: URL, settings: ExportSettings, draft: PublishDraft) {
        self.exportURL = exportURL
        self.settings = settings
        self.draft = draft
        self.states = Dictionary(uniqueKeysWithValues: draft.platforms.map { ($0, .queued) })
    }
}

@MainActor
final class PublishQueue: ObservableObject {
    @Published var jobs: [PublishJob] = []

    private let providers: [PublishingPlatform: any PublishingProvider] = Dictionary(
        uniqueKeysWithValues: PublishingPlatform.allCases.map {
            ($0, UnconfiguredPublishingProvider(platform: $0) as any PublishingProvider)
        }
    )

    func enqueue(export: ExportJob, draft: PublishDraft) -> [PublishIssue] {
        let issues = PublishValidator.validate(draft: draft, settings: export.settings)
        guard !issues.contains(where: { $0.severity == .error }) else { return issues }
        jobs.append(PublishJob(exportURL: export.outputURL, settings: export.settings, draft: draft))
        return issues
    }

    func start(_ job: PublishJob) {
        for platform in job.draft.platforms {
            guard let provider = providers[platform] else { continue }
            Task {
                switch await provider.connectionStatus() {
                case .connected:
                    job.states[platform] = .uploading
                    do {
                        try await provider.upload(file: job.exportURL, draft: job.draft) { progress in
                            Task { @MainActor in job.progress[platform] = progress }
                        }
                        job.progress[platform] = 1
                        job.states[platform] = .uploaded
                    } catch is CancellationError {
                        job.states[platform] = .cancelled
                    } catch {
                        job.states[platform] = .failed(error.localizedDescription)
                    }
                case .disconnected, .unavailable:
                    job.states[platform] = .waitingForConnection
                }
            }
        }
    }

    func remove(_ job: PublishJob) {
        jobs.removeAll { $0.id == job.id }
    }
}
