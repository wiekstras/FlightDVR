import SwiftUI

/// A compact publishing composer. It deliberately works against completed
/// exports only, keeping encoding and upload work separate and recoverable.
struct PublishPane: View {
    @EnvironmentObject var exportQueue: ExportQueue
    @EnvironmentObject var publishQueue: PublishQueue
    @State private var draft: PublishDraft
    @State private var selectedExportID: UUID?
    @State private var issues: [PublishIssue] = []
    @State private var draftSaveTask: Task<Void, Never>?

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
                    if completedExports.isEmpty {
                        Text("Finish an export to prepare a publish job.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Export", selection: $selectedExportID) {
                            Text("Choose an export").tag(Optional<UUID>.none)
                            ForEach(completedExports) { job in
                                Text(job.outputURL.lastPathComponent).tag(Optional(job.id))
                            }
                        }
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
                        validationMessages
                        Button("Publish") { publish() }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedExport == nil || issues.contains(where: {
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
        guard let selectedExport else { return }
        issues = publishQueue.enqueue(export: selectedExport, draft: draft)
        guard !issues.contains(where: { $0.severity == .error }),
              let job = publishQueue.jobs.last else { return }
        publishQueue.start(job)
    }

    private func refreshIssues() {
        guard let selectedExport else {
            issues = []
            return
        }
        issues = PublishValidator.validate(
            draft: draft, settings: selectedExport.settings,
            media: selectedExport.outputInfo,
            fileExists: FileManager.default.fileExists(atPath: selectedExport.outputURL.path))
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
