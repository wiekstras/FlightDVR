import SwiftUI
import UniformTypeIdentifiers

private enum PublishSourceMode: String, CaseIterable, Identifiable {
    case currentEdit = "Current Edit"
    case completedExport = "Completed Export"
    var id: String { rawValue }
}

/// A compact publishing composer that can hand the current non-destructive
/// edit through the durable export and upload queues in one action.
struct PublishPane: View {
    @EnvironmentObject var exportQueue: ExportQueue
    @EnvironmentObject var publishQueue: PublishQueue
    @EnvironmentObject var store: ClipStore
    @State private var draft: PublishDraft
    @State private var selectedExportID: UUID?
    @State private var issues: [PublishIssue] = []
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var isGeneratingThumbnail = false
    @State private var thumbnailError: String?
    @State private var sourceMode: PublishSourceMode = .currentEdit
    @State private var deliverySettings: ExportSettings = {
        var settings = ExportSettings()
        settings.preset = .social
        settings.socialTargetMB = 50
        return settings
    }()

    init() {
        _draft = State(initialValue: PublishDraftStore.load())
    }

    private var completedExports: [ExportJob] {
        exportQueue.jobs.filter { $0.state == .done }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Publish") {
                    Picker("Source", selection: $sourceMode) {
                        Text("Current Edit").tag(PublishSourceMode.currentEdit)
                        Text("Completed Export").tag(PublishSourceMode.completedExport)
                    }
                    .pickerStyle(.segmented)
                    if sourceMode == .currentEdit {
                        currentEditSource
                    } else if completedExports.isEmpty {
                        Text("No verified exports are available yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Export", selection: $selectedExportID) {
                            Text("Choose an export").tag(Optional<UUID>.none)
                            ForEach(completedExports) { job in
                                Text(job.outputURL.lastPathComponent).tag(Optional(job.id))
                            }
                        }
                    }
                    if activeSourceAvailable {
                        TextField("Title", text: $draft.title)
                        TextField("Caption", text: $draft.caption, axis: .vertical)
                            .lineLimit(2...5)
                        TextField("Hashtags", text: $draft.hashtags)
                        Picker("Visibility", selection: $draft.visibility) {
                            ForEach(PublishVisibility.allCases) { visibility in
                                Text(visibility.rawValue).tag(visibility)
                            }
                        }
                        platformToggles
                        if draft.platforms.contains(.youtube) {
                            thumbnailEditor
                        }
                        validationMessages
                        Button(sourceMode == .currentEdit ? "Export & Publish" : "Publish") {
                            publish()
                        }
                            .buttonStyle(.borderedProminent)
                            .disabled(!activeSourceAvailable || issues.contains(where: {
                                $0.severity == .error
                            }))
                    }
                }

                if !publishQueue.jobs.isEmpty {
                    Divider()
                    section("Publishing queue") {
                        HStack {
                            Button("Resume all") { publishQueue.startAll() }
                                .disabled(!publishQueue.jobs.contains(where: \.canStart))
                            Spacer()
                            Text("Uploads continue in the background")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(publishQueue.jobs) { job in
                            PublishJobRow(job: job)
                        }
                    }
                }
                if let persistenceError = publishQueue.persistenceError {
                    Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(14)
        }
        .onChange(of: completedExports.map(\.id)) { _, ids in
            if let selected = selectedExportID {
                if !ids.contains(selected) { selectedExportID = ids.last }
            } else {
                selectedExportID = ids.last
            }
            refreshIssues()
        }
        .onChange(of: selectedExportID) { _, _ in
            refreshIssues()
        }
        .onChange(of: sourceMode) { _, _ in refreshIssues() }
        .onChange(of: deliverySettings) { _, _ in refreshIssues() }
        .onChange(of: draft) { _, newDraft in
            refreshIssues()
            draftSaveTask?.cancel()
            draftSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                PublishDraftStore.save(newDraft)
            }
        }
        .onAppear {
            if selectedExportID == nil { selectedExportID = completedExports.last?.id }
            refreshIssues()
        }
        .onDisappear {
            draftSaveTask?.cancel()
            PublishDraftStore.save(draft)
        }
    }

    private var selectedExport: ExportJob? {
        completedExports.first { $0.id == selectedExportID }
    }

    private var activeSourceAvailable: Bool {
        sourceMode == .currentEdit ? store.selectedClip?.info != nil : selectedExport != nil
    }

    private var currentEditSource: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let clip = store.selectedClip {
                LabeledContent("Recording") { Text(clip.name).lineLimit(1) }
                Picker("Delivery", selection: $deliverySettings.socialProfile) {
                    ForEach(SocialProfile.allCases) { profile in
                        Text("\(profile.rawValue) · \(profile.aspectLabel)").tag(profile)
                    }
                }
                Picker("Framing", selection: $deliverySettings.socialFraming) {
                    ForEach(SocialFraming.allCases) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    Slider(value: $deliverySettings.socialTargetMB, in: 10...200, step: 5)
                    Text("\(Int(deliverySettings.socialTargetMB)) MB")
                        .font(.caption.monospacedDigit()).frame(width: 48)
                }
                Text("The edit is encoded, verified, then handed to every selected platform automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Select a recording to export and publish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private var platformToggles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Platforms")
            HStack(spacing: 8) {
                ForEach(PublishingPlatform.allCases) { platform in
                    Toggle(isOn: Binding(
                        get: { draft.platforms.contains(platform) },
                        set: { selected in
                            if selected { draft.platforms.insert(platform) }
                            else { draft.platforms.remove(platform) }
                        }
                    )) {
                        Label(platform.rawValue, systemImage: platform.icon)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var thumbnailEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("YouTube Thumbnail")
            if let url = draft.thumbnailURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 180, maxHeight: 102)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            }
            HStack {
                Button("Choose…") { chooseThumbnail() }
                Button(isGeneratingThumbnail ? "Generating…" : "Use Middle Frame") {
                    generateThumbnail()
                }
                .disabled(isGeneratingThumbnail || selectedExport == nil)
                if draft.thumbnailURL != nil {
                    Button("Clear") { draft.thumbnailURL = nil }
                }
            }
            .controlSize(.small)
            if let thumbnailError {
                Text(thumbnailError).font(.caption2).foregroundStyle(.red)
            }
            Text("JPEG or PNG · maximum 2 MB")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func chooseThumbnail() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.thumbnailURL = url
        thumbnailError = nil
    }

    private func generateThumbnail() {
        guard let export = selectedExport else { return }
        let output = ClipStore.cacheRoot.appendingPathComponent(
            "publish-thumbnail-\(export.id.uuidString).jpg")
        let time = (export.outputInfo?.duration ?? 0) / 2
        let command = PublishThumbnailBuilder.command(source: export.outputURL,
                                                       time: time, output: output)
        isGeneratingThumbnail = true
        thumbnailError = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FFmpeg.run(command)
                }.value
                draft.thumbnailURL = output
            } catch {
                thumbnailError = error.localizedDescription
            }
            isGeneratingThumbnail = false
            refreshIssues()
        }
    }

    @ViewBuilder private var validationMessages: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { issue in
                    Label(issue.message,
                          systemImage: issue.severity == .error
                            ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                }
            }
        }
    }

    private func publish() {
        if sourceMode == .currentEdit {
            guard let clip = store.selectedClip else { return }
            issues = exportQueue.enqueueForPublishing(
                clip: clip, settings: deliverySettings, draft: draft)
        } else {
            guard let selectedExport else { return }
            let result = publishQueue.enqueueJob(export: selectedExport, draft: draft)
            issues = result.issues
            guard let job = result.job,
                  !issues.contains(where: { $0.severity == .error }) else { return }
            publishQueue.start(job)
        }
    }

    private func refreshIssues() {
        if sourceMode == .currentEdit {
            guard store.selectedClip?.info != nil else { issues = []; return }
            issues = PublishValidator.validate(draft: draft, settings: deliverySettings)
        } else {
            guard let selectedExport else { issues = []; return }
            issues = PublishValidator.validate(
                draft: draft, settings: selectedExport.settings,
                media: selectedExport.outputInfo,
                fileExists: FileManager.default.fileExists(atPath: selectedExport.outputURL.path))
        }
    }

    @ViewBuilder
    private func section(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(label)
            content()
        }
    }
}

private struct PublishJobRow: View {
    @ObservedObject var job: PublishJob
    @EnvironmentObject var queue: PublishQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.exportURL.lastPathComponent).lineLimit(1)
                Spacer()
                Button {
                    queue.start(job)
                } label: {
                    Image(systemName: "arrow.up.circle")
                }
                .buttonStyle(.plain)
                .help("Start publishing")
                .disabled(!job.canStart)
                Button {
                    queue.remove(job)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
            ForEach(job.draft.platforms.sorted(by: { $0.rawValue < $1.rawValue })) { platform in
                HStack(spacing: 6) {
                    Image(systemName: platform.icon).frame(width: 14)
                    Text(platform.rawValue).font(.caption)
                    Spacer()
                    let state = job.states[platform] ?? .queued
                    publishState(state, progress: job.progress[platform])
                    if state == .uploading {
                        Button {
                            queue.cancel(job, platform: platform)
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Cancel \(platform.rawValue) upload")
                    } else if state.canStart {
                        Button {
                            queue.retry(job, platform: platform)
                        } label: {
                            Image(systemName: "arrow.counterclockwise.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Retry \(platform.rawValue)")
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    @ViewBuilder
    private func publishState(_ state: PublishJob.State, progress: Double?) -> some View {
        switch state {
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .waitingForConnection:
            Text("Connect account").foregroundStyle(.orange)
        case .uploading:
            ProgressView(value: progress ?? 0).frame(width: 76)
        case .uploaded:
            Label("Uploaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            Text("Cancelled").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).lineLimit(1).foregroundStyle(.red)
        }
    }
}
