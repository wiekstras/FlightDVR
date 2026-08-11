import SwiftUI

struct ExportPane: View {
    @EnvironmentObject var store: ClipStore
    @EnvironmentObject var queue: ExportQueue
    @State private var settings = ExportSettings()
    @State private var hardwareAvailable: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Preset") {
                    Picker("", selection: $settings.preset) {
                        ForEach(Preset.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(settings.preset.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                section("Options") {
                    switch settings.preset {
                    case .edit:
                        Picker("Codec", selection: $settings.proResProfile) {
                            ForEach(ProResProfile.allCases) { p in Text(p.rawValue).tag(p) }
                        }
                    case .master:
                        Picker("Quality", selection: $settings.masterQuality) {
                            ForEach(MasterQuality.allCases) { q in
                                Text("\(q.rawValue)  ·  CRF \(q.crf)").tag(q)
                            }
                        }
                        if hardwareAvailable == true {
                            Toggle("Hardware encoder (VideoToolbox)", isOn: $settings.useHardware)
                        }
                    case .social:
                        Picker("Platform", selection: $settings.socialProfile) {
                            ForEach(SocialProfile.allCases) { profile in
                                Text("\(profile.rawValue) · \(profile.canvasLabel)").tag(profile)
                            }
                        }
                        Picker("Framing", selection: $settings.socialFraming) {
                            ForEach(SocialFraming.allCases) { framing in
                                Text(framing.rawValue).tag(framing)
                            }
                        }
                        Text(settings.socialFraming == .fit
                             ? "Keeps the full recording and adds padding where needed."
                             : "Fills the canvas edge to edge by cropping the sides.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SocialFramingPreview(
                            image: store.selectedClip?.thumbnail,
                            profile: settings.socialProfile,
                            framing: settings.socialFraming,
                            positionX: settings.cropPositionX,
                            positionY: settings.cropPositionY)
                            .frame(maxWidth: .infinity)
                        if settings.socialFraming == .fill {
                            LabeledContent("Horizontal") {
                                Slider(value: $settings.cropPositionX, in: 0...1)
                            }
                            LabeledContent("Vertical") {
                                Slider(value: $settings.cropPositionY, in: 0...1)
                            }
                            HStack {
                                Spacer()
                                Button("Center") {
                                    settings.cropPositionX = 0.5
                                    settings.cropPositionY = 0.5
                                }
                                .disabled(settings.cropPositionX == 0.5 && settings.cropPositionY == 0.5)
                            }
                        }
                        HStack {
                            Slider(value: $settings.socialTargetMB, in: 5...200, step: 5)
                            Text("\(Int(settings.socialTargetMB)) MB")
                                .font(.callout.monospacedDigit())
                                .frame(width: 52, alignment: .trailing)
                        }
                    case .remux:
                        Text("Trim cuts land on keyframes; edits, music and speed ramps are ignored.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settings.preset != .remux {
                        Picker("Colour", selection: $settings.colorMode) {
                            ForEach(ColorMode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                    }
                    Toggle("Keep the audio track", isOn: $settings.keepAudio)
                }
                .controlSize(.small)

                Divider()

                section("Output") {
                    HStack {
                        Text(settings.outputFolder?.lastPathComponent ?? "Movies/Flight Studio")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Change…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK { settings.outputFolder = panel.url }
                        }
                        .controlSize(.small)
                        Button {
                            let folder = settings.resolvedOutputFolder
                            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(folder)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal output folder")
                    }
                    HStack(spacing: 6) {
                        Button("Add ticked") {
                            queue.enqueue(clips: store.tickedClips, settings: settings)
                        }
                        .disabled(store.tickedClips.isEmpty)
                        Button("Add current") {
                            if let clip = store.selectedClip {
                                queue.enqueue(clips: [clip], settings: settings)
                            }
                        }
                        .disabled(store.selectedClip == nil)
                    }
                    .controlSize(.small)
                    Button("Stitch ticked into one video") {
                        let ordered = store.sortedClips.filter(\.ticked)
                        queue.enqueueStitch(clips: ordered, settings: settings)
                    }
                    .controlSize(.small)
                    .disabled(store.tickedClips.count < 2)
                    Text("Stitches in the current list order. Matching resolutions are required.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                section(queue.jobs.isEmpty ? "Queue" : "Queue · \(queue.jobs.count)") {
                    QueueList()
                    HStack {
                        Button(queue.isRunning ? "Exporting…" : "Start export") {
                            queue.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(queue.isRunning || queue.jobs.allSatisfy { $0.state != .waiting })
                        Button("Clear finished") { queue.clearFinished() }
                            .controlSize(.small)
                            .disabled(queue.jobs.isEmpty)
                        if queue.jobs.contains(where: { $0.state.isFailure }) {
                            Button("Clear failed") { queue.clearFailed() }
                                .controlSize(.small)
                        }
                        if queue.isRunning || queue.jobs.contains(where: { $0.state == .waiting }) {
                            Button("Cancel all") { queue.cancelAll() }
                                .controlSize(.small)
                        }
                    }
                    if let persistenceError = queue.persistenceError {
                        Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(14)
        }
        .task {
            hardwareAvailable = await Task.detached { HardwareDetect.videoToolboxWorks() }.value
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

private struct SocialFramingPreview: View {
    let image: NSImage?
    let profile: SocialProfile
    let framing: SocialFraming
    let positionX: Double
    let positionY: Double

    private var canvasSize: CGSize {
        profile.isVertical ? CGSize(width: 108, height: 192) : CGSize(width: 224, height: 126)
    }

    var body: some View {
        let canvas = canvasSize
        ZStack {
            Color.black
            if let image, image.size.width > 0, image.size.height > 0 {
                let imageAspect = image.size.width / image.size.height
                let canvasAspect = canvas.width / canvas.height
                let fill = framing == .fill
                let renderedWidth = (fill ? imageAspect > canvasAspect : imageAspect < canvasAspect)
                    ? canvas.height * imageAspect : canvas.width
                let renderedHeight = renderedWidth / imageAspect
                let overflowX = max(renderedWidth - canvas.width, 0)
                let overflowY = max(renderedHeight - canvas.height, 0)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: renderedWidth, height: renderedHeight)
                    .offset(x: overflowX * (0.5 - positionX),
                            y: overflowY * (0.5 - positionY))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .overlay(Rectangle().strokeBorder(.separator))
        .overlay(alignment: .bottomTrailing) {
            Text(profile.isVertical ? "9:16" : "16:9")
                .font(.caption2.monospacedDigit())
                .padding(4)
                .background(.black.opacity(0.65))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Social framing preview")
    }
}

struct QueueList: View {
    @EnvironmentObject var queue: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(queue.jobs.enumerated()), id: \.element.id) { index, job in
                QueueRow(job: job, position: index + 1)
            }
            if queue.jobs.isEmpty {
                Text("Tick clips, then add them here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct QueueRow: View {
    @ObservedObject var job: ExportJob
    @EnvironmentObject var queue: ExportQueue
    let position: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                stateIcon
                Text(job.outputURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                if job.state == .waiting {
                    Text("#\(position)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                switch job.state {
                case .running:
                    Button {
                        queue.cancel(job)
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.plain)
                case .waiting:
                    Button {
                        queue.moveWaiting(job, by: -1)
                    } label: {
                        Image(systemName: "arrow.up.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Move earlier")
                    Button {
                        queue.moveWaiting(job, by: 1)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Move later")
                    Button {
                        queue.remove(job)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                case .done:
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .buttonStyle(.plain)
                case .cancelled, .failed:
                    Button {
                        queue.retry(job)
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Retry export")
                }
            }
            if job.state == .running {
                ProgressView(value: job.progress)
                    .controlSize(.small)
            }
            if case .failed(let message) = job.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    @ViewBuilder private var stateIcon: some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
