import SwiftUI
import UniformTypeIdentifiers

struct ExportPane: View {
    @EnvironmentObject var store: ClipStore
    @EnvironmentObject var queue: ExportQueue
    @State private var settings = ExportSettings()
    @State private var hardwareAvailable: Bool?
    @State private var sequenceClips: [SequenceEntry] = []
    @State private var sequenceTitle = "Build Sequence"
    @State private var showingSequenceComposer = false

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
                        Text(framingDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SocialFramingPreview(
                            image: store.selectedClip?.thumbnail,
                            profile: settings.socialProfile,
                            framing: settings.socialFraming,
                            positionX: $settings.cropPositionX,
                            positionY: $settings.cropPositionY)
                            .frame(maxWidth: .infinity)
                        if settings.socialFraming == .fill {
                            Text("Drag the preview to reposition · Double-click to center")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                        Text("Trim cuts land on keyframes; cuts, titles, audio mixing and speed ramps are ignored.")
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
                        Button("Add saved highlights") {
                            if let clip = store.selectedClip {
                                queue.enqueueHighlights(from: clip, settings: settings)
                            }
                        }
                        .disabled(store.selectedClip?.highlights.isEmpty != false)
                    }
                    .controlSize(.small)
                    Button("Build sequence…") {
                        sequenceTitle = "Build Sequence"
                        sequenceClips = store.sortedClips.filter(\.ticked).map {
                            SequenceEntry(clip: $0, name: $0.name)
                        }
                        showingSequenceComposer = true
                    }
                    .controlSize(.small)
                    .disabled(store.tickedClips.count < 2)
                    Button("Build highlight reel…") {
                        guard let clip = store.selectedClip else { return }
                        sequenceTitle = "Build Highlight Reel"
                        sequenceClips = clip.highlights.map { highlight in
                            SequenceEntry(clip: Clip.exportVariant(from: clip, edit: highlight.edit),
                                          name: highlight.name)
                        }
                        showingSequenceComposer = true
                    }
                    .controlSize(.small)
                    .disabled((store.selectedClip?.highlights.count ?? 0) < 2)
                    Text("Arrange selected recordings before creating one continuous video.")
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
        .sheet(isPresented: $showingSequenceComposer) {
            SequenceComposer(clips: $sequenceClips, title: sequenceTitle,
                             settings: settings) { ordered in
                queue.enqueueStitch(clips: ordered.map(\.clip), settings: settings)
            }
        }
    }

    private var framingDescription: String {
        switch settings.socialFraming {
        case .fit: "Keeps the full recording and adds black padding where needed."
        case .blurredBackground: "Keeps the full recording over a softly blurred edge-to-edge background."
        case .fill: "Fills the canvas edge to edge by cropping the sides."
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

private struct SequenceEntry: Identifiable {
    let id = UUID()
    let clip: Clip
    let name: String
}

private struct SequenceComposer: View {
    @Binding var clips: [SequenceEntry]
    let title: String
    let settings: ExportSettings
    let onQueue: ([SequenceEntry]) -> Void
    @Environment(\.dismiss) private var dismiss

    private var incompatible: Bool {
        guard let reference = clips.first?.clip.info else { return true }
        return clips.contains {
            guard let info = $0.clip.info else { return true }
            return info.width != reference.width || info.height != reference.height
        }
    }

    private var totalDuration: Double {
        clips.reduce(0) { total, entry in
            guard let info = entry.clip.info else { return total }
            return total + entry.clip.edit.outputDuration(duration: info.duration)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text("Drag clips or use the arrows to set playback order.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(clips.count) clips · \(EditorTimecode.string(seconds: totalDuration, fps: 0))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(clips.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, alignment: .trailing)
                        if let thumbnail = entry.clip.thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 36).clipped()
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1)
                            if let info = entry.clip.info {
                                let editedDuration = entry.clip.edit.outputDuration(duration: info.duration)
                                Text("\(info.width)×\(info.height) · \(EditorTimecode.string(seconds: editedDuration, fps: 0))")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            } else {
                                Text("Reading metadata…").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.plain).disabled(index == 0).help("Move earlier")
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.plain).disabled(index == clips.count - 1).help("Move later")
                        Button { clips.remove(at: index) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Remove from sequence")
                    }
                    .padding(.vertical, 3)
                }
                .onMove { offsets, destination in
                    clips.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .frame(minHeight: 240)
            if incompatible {
                Label("All clips need matching dimensions and completed metadata before stitching.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if settings.preset == .remux {
                Text("Sequences use the Master H.264 preset because stitching requires a full encode.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.preset == .social {
                Text("The complete sequence will use the selected social canvas, framing and target size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Add Sequence to Queue") {
                    onQueue(clips)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(clips.count < 2 || incompatible)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 430)
    }

    private func move(_ index: Int, by offset: Int) {
        clips = SequenceOrder.moved(clips, from: index, to: index + offset)
    }
}

private struct SocialFramingPreview: View {
    let image: NSImage?
    let profile: SocialProfile
    let framing: SocialFraming
    @Binding var positionX: Double
    @Binding var positionY: Double
    @State private var dragOrigin: DragOrigin?

    private struct DragOrigin {
        let x: Double
        let y: Double
    }

    private var canvasSize: CGSize {
        let aspect = CGFloat(profile.canvasSize.width) / CGFloat(profile.canvasSize.height)
        let maxWidth: CGFloat = profile.isVertical || aspect == 1 ? 150 : 224
        let maxHeight: CGFloat = 192
        if maxWidth / aspect <= maxHeight {
            return CGSize(width: maxWidth, height: maxWidth / aspect)
        }
        return CGSize(width: maxHeight * aspect, height: maxHeight)
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
                if framing == .blurredBackground {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: canvas.width, height: canvas.height)
                        .blur(radius: 12)
                        .scaleEffect(1.08)
                }
                Image(nsImage: image)
                    .resizable()
                    .frame(width: renderedWidth, height: renderedHeight)
                    .offset(x: overflowX * (0.5 - positionX),
                            y: overflowY * (0.5 - positionY))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                guard framing == .fill else { return }
                                let origin = dragOrigin ?? DragOrigin(x: positionX, y: positionY)
                                if dragOrigin == nil { dragOrigin = origin }
                                positionX = SocialFramingMath.draggedPosition(
                                    start: origin.x,
                                    translation: Double(value.translation.width),
                                    overflow: Double(overflowX))
                                positionY = SocialFramingMath.draggedPosition(
                                    start: origin.y,
                                    translation: Double(value.translation.height),
                                    overflow: Double(overflowY))
                            }
                            .onEnded { _ in dragOrigin = nil })
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .overlay(Rectangle().strokeBorder(.separator))
        .overlay(alignment: .bottomTrailing) {
            Text(profile.aspectLabel)
                .font(.caption2.monospacedDigit())
                .padding(4)
                .background(.black.opacity(0.65))
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard framing == .fill else { return }
            positionX = 0.5
            positionY = 0.5
        }
        .accessibilityLabel("Social framing preview")
        .accessibilityHint(framing == .fill
            ? "Drag to reposition the video. Double-click to center it."
            : "Shows how the video fits the selected social canvas.")
    }
}

enum SocialFramingMath {
    static func draggedPosition(start: Double, translation: Double, overflow: Double) -> Double {
        let safeStart = start.isFinite ? min(max(start, 0), 1) : 0.5
        guard translation.isFinite, overflow.isFinite, overflow > 0.001 else { return safeStart }
        return min(max(safeStart - translation / overflow, 0), 1)
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
                    if job.outputActionsAvailable {
                        Button {
                            NSWorkspace.shared.open(job.outputURL)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Open export")
                        ShareLink(item: job.outputURL) {
                            Image(systemName: "square.and.arrow.up.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Share export")
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                        } label: {
                            Image(systemName: "magnifyingglass.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    } else {
                        Image(systemName: "questionmark.folder")
                            .foregroundStyle(.red)
                            .help("The completed export is missing or no longer verified")
                    }
                case .cancelled, .failed:
                    if !job.missingSources.isEmpty {
                        Button {
                            relinkFirstMissingSource()
                        } label: {
                            Image(systemName: "link.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Locate missing source recording")
                    }
                    Button {
                        queue.retry(job)
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(!job.missingSources.isEmpty)
                    .help(job.missingSources.isEmpty
                          ? "Retry export" : "Relink missing source recordings before retrying")
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
            if job.state == .done, !job.outputActionsAvailable {
                Text("Export file is missing or no longer verified.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func relinkFirstMissingSource() {
        guard let source = job.missingSources.first else { return }
        let panel = NSOpenPanel()
        panel.message = "Locate \(source.name) for this queued export. The frozen edit will be preserved."
        panel.prompt = "Relink Recording"
        panel.allowedContentTypes = ClipStore.videoExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let replacementURL = panel.url else { return }
        Task { await queue.relinkSource(source, in: job, to: replacementURL) }
    }

    @ViewBuilder private var stateIcon: some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: job.outputActionsAvailable
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(job.outputActionsAvailable ? .green : .red)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
