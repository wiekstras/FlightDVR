import SwiftUI
import UniformTypeIdentifiers

struct TimelinePane: View {
    @EnvironmentObject var store: ClipStore
    @ObservedObject var player: PlayerController
    @State private var pendingCutStart: Double?
    @State private var pendingSpeedStart: Double?
    @State private var newZoneSpeed: Double = 2.0

    var body: some View {
        if let clip = store.selectedClip {
            TimelineEditor(clip: clip, player: player,
                           pendingCutStart: $pendingCutStart,
                           pendingSpeedStart: $pendingSpeedStart,
                           newZoneSpeed: $newZoneSpeed)
                .id(clip.id)
                .task(id: clip.info?.duration) {
                    store.prepareTimelineFilmstrip(for: clip)
                }
        }
    }
}

private struct TimelineEditor: View {
    @ObservedObject var clip: Clip
    @ObservedObject var player: PlayerController
    @Binding var pendingCutStart: Double?
    @Binding var pendingSpeedStart: Double?
    @Binding var newZoneSpeed: Double
    @State private var projectError: String?
    @State private var highlightLength: Double = 30
    @State private var timelineZoom: Double = 1

    var duration: Double { clip.info?.duration ?? player.duration }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Eyebrow("Timeline")
                Spacer()
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $timelineZoom, in: 1...20, step: 1)
                    .frame(width: 110)
                    .help("Zoom the timeline for precise work on long recordings")
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("\(Int(timelineZoom))×")
                    .font(.caption.monospacedDigit())
                    .frame(width: 28, alignment: .trailing)
                Button("Fit") { timelineZoom = 1 }
                    .controlSize(.mini)
                    .disabled(timelineZoom == 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            GeometryReader { viewport in
                ScrollView(.horizontal) {
                    TimelineBar(clip: clip, player: player, duration: duration,
                                pendingCutStart: pendingCutStart,
                                pendingSpeedStart: pendingSpeedStart)
                        .frame(width: max(viewport.size.width * timelineZoom, viewport.size.width),
                               height: 74)
                }
                .scrollIndicators(.visible)
            }
            .frame(height: 74)
            .padding(.horizontal, 16)

            if !clip.edit.cuts.isEmpty || !clip.edit.speedZones.isEmpty || !clip.edit.markers.isEmpty {
                EditChips(clip: clip, player: player)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.top, 10)

            HStack(spacing: 8) {
                Label("Quick Highlight", systemImage: "sparkles.rectangle.stack")
                    .font(.callout.weight(.medium))
                Picker("Length", selection: $highlightLength) {
                    Text("15 sec").tag(15.0)
                    Text("30 sec").tag(30.0)
                    Text("60 sec").tag(60.0)
                }
                .labelsHidden()
                .frame(width: 82)
                Button("Around Playhead") {
                    clip.edit.setHighlight(around: player.currentSourceTime,
                                           length: highlightLength,
                                           duration: duration)
                }
                .keyboardShortcut("h", modifiers: [])
                .disabled(duration <= 0)
                .help("Create a highlight centered on the current moment (H)")
                Text("Sets In/Out without changing the source")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // The bench: one flat row of tools, grouped by tracked labels.
            HStack(alignment: .top, spacing: 0) {
                tool("Trim") {
                    Button("In") { clip.edit.inPoint = player.currentSourceTime }
                        .keyboardShortcut("i", modifiers: [])
                        .help("Set In point (I)")
                    Button("Out") { clip.edit.outPoint = player.currentSourceTime }
                        .keyboardShortcut("o", modifiers: [])
                        .help("Set Out point (O)")
                    Button("Reset") { clip.edit = EditPlan() }
                }
                benchDivider
                tool("Cut") {
                    if let start = pendingCutStart {
                        Button("End cut") {
                            let end = player.currentSourceTime
                            if end > start + 0.05 {
                                clip.edit.cuts.append(CutRange(start: start, end: end))
                            }
                            pendingCutStart = nil
                        }
                        .tint(.red)
                        Button("Cancel") { pendingCutStart = nil }
                    } else {
                        Button("Start cut") { pendingCutStart = player.currentSourceTime }
                    }
                }
                benchDivider
                tool("Speed") {
                    if let start = pendingSpeedStart {
                        Picker("", selection: $newZoneSpeed) {
                            Text("0.25×").tag(0.25)
                            Text("0.5×").tag(0.5)
                            Text("1.5×").tag(1.5)
                            Text("2×").tag(2.0)
                            Text("3×").tag(3.0)
                            Text("4×").tag(4.0)
                        }
                        .labelsHidden()
                        .frame(width: 68)
                        Button("End zone") {
                            let end = player.currentSourceTime
                            if end > start + 0.2 {
                                clip.edit.speedZones.append(
                                    SpeedZone(start: start, end: end, speed: newZoneSpeed))
                            }
                            pendingSpeedStart = nil
                        }
                        .tint(.orange)
                        Button("Cancel") { pendingSpeedStart = nil }
                    } else {
                        Button("Start zone") { pendingSpeedStart = player.currentSourceTime }
                    }
                }
                benchDivider
                tool("Marker") {
                    Button("Add marker") {
                        let number = clip.edit.markers.count + 1
                        clip.edit.markers.append(TimelineMarker(
                            time: player.currentSourceTime, name: "Marker \(number)"))
                    }
                    .keyboardShortcut("m", modifiers: [])
                    .help("Add marker (M)")
                }
                benchDivider
                tool("Audio") {
                    AudioControls(clip: clip)
                }
                benchDivider
                tool("Project") {
                    Button("Save…") { saveProject() }
                    Button("Open…") { openProject() }
                }
                benchDivider
                tool("History") {
                    Button {
                        clip.undoEdit()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!clip.canUndoEdit)
                    .help("Undo edit (⌘Z)")
                    Button {
                        clip.redoEdit()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!clip.canRedoEdit)
                    .help("Redo edit (⇧⌘Z)")
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onChange(of: clip.edit) { _, _ in
            player.editChanged()
        }
        .alert("Couldn’t use edit project", isPresented: Binding(
            get: { projectError != nil },
            set: { if !$0 { projectError = nil } }
        )) {
            Button("OK", role: .cancel) { projectError = nil }
        } message: {
            Text(projectError ?? "")
        }
    }

    private var benchDivider: some View {
        Divider().frame(height: 40).padding(.horizontal, 14)
    }

    @ViewBuilder
    private func tool(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(label)
            HStack(spacing: 6) { content() }
                .benchButton()
        }
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = clip.url.deletingPathExtension().lastPathComponent + ".flightedit.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try EditProjectFile.encode(clip: clip).write(to: url, options: .atomic)
        } catch {
            projectError = error.localizedDescription
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            clip.edit = try EditProjectFile.decode(Data(contentsOf: url), for: clip)
        } catch {
            projectError = error.localizedDescription
        }
    }
}

private struct AudioControls: View {
    @ObservedObject var clip: Clip
    @State private var showingInspector = false

    var body: some View {
        Button {
            showingInspector.toggle()
        } label: {
            Label("Mix…", systemImage: clip.edit.sourceAudio?.isMuted == true
                  ? "speaker.slash" : "slider.horizontal.3")
        }
        .popover(isPresented: $showingInspector, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Clip Audio")
                if clip.info?.hasAudio == false {
                    Text("This recording has no audio track.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Volume") {
                        Slider(value: audioBinding(\.volume), in: 0...1)
                            .frame(width: 150)
                    }
                    Toggle("Mute recording", isOn: audioBinding(\.isMuted))
                    LabeledContent("Fade in") {
                        Slider(value: audioBinding(\.fadeIn), in: 0...10, step: 0.25)
                            .frame(width: 150)
                    }
                    LabeledContent("Fade out") {
                        Slider(value: audioBinding(\.fadeOut), in: 0...10, step: 0.25)
                            .frame(width: 150)
                    }
                    Button("Reset clip audio") { clip.edit.sourceAudio = nil }
                        .disabled(clip.edit.sourceAudio == nil)
                }

                Divider()
                Eyebrow("Music")
                musicEditor
            }
            .controlSize(.small)
            .padding(14)
            .frame(width: 290)
        }
    }

    private func audioBinding(_ keyPath: WritableKeyPath<SourceAudioSettings, Double>) -> Binding<Double> {
        Binding(
            get: { (clip.edit.sourceAudio ?? SourceAudioSettings())[keyPath: keyPath] },
            set: { value in updateAudio { $0[keyPath: keyPath] = value } }
        )
    }

    private func audioBinding(_ keyPath: WritableKeyPath<SourceAudioSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { (clip.edit.sourceAudio ?? SourceAudioSettings())[keyPath: keyPath] },
            set: { value in updateAudio { $0[keyPath: keyPath] = value } }
        )
    }

    private func updateAudio(_ change: (inout SourceAudioSettings) -> Void) {
        var audio = clip.edit.sourceAudio ?? SourceAudioSettings()
        change(&audio)
        clip.edit.sourceAudio = audio.isDefault ? nil : audio
    }

    @ViewBuilder private var musicEditor: some View {
        if let music = clip.edit.music {
            Text(music.url.deletingPathExtension().lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            LabeledContent("Volume") {
                Slider(value: Binding(
                    get: { clip.edit.music?.volume ?? 0.8 },
                    set: { clip.edit.music?.volume = $0 }
                ), in: 0...1)
                .frame(width: 150)
            }
            LabeledContent("Fade in") {
                Slider(value: Binding(
                    get: { clip.edit.music?.fadeIn ?? 1 },
                    set: { clip.edit.music?.fadeIn = $0 }
                ), in: 0...10, step: 0.25)
                .frame(width: 150)
            }
            LabeledContent("Fade out") {
                Slider(value: Binding(
                    get: { clip.edit.music?.fadeOut ?? 2 },
                    set: { clip.edit.music?.fadeOut = $0 }
                ), in: 0...10, step: 0.25)
                .frame(width: 150)
            }
            Toggle("Replace recording audio", isOn: Binding(
                get: { clip.edit.music?.muteOriginal ?? false },
                set: { clip.edit.music?.muteOriginal = $0 }
            ))
            Button("Remove music", role: .destructive) { clip.edit.music = nil }
        } else {
            Button("Add music…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                if panel.runModal() == .OK, let url = panel.url {
                    clip.edit.music = MusicTrack(url: url)
                }
            }
        }
    }
}

private struct EditChips: View {
    @ObservedObject var clip: Clip
    @ObservedObject var player: PlayerController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(clip.edit.cuts) { cut in
                    chip(icon: "scissors", color: .red,
                         text: "\(timecode(cut.start))–\(timecode(cut.end))") {
                        clip.edit.cuts.removeAll { $0.id == cut.id }
                    }
                }
                ForEach(clip.edit.speedZones) { zone in
                    chip(icon: "hare", color: .orange,
                         text: "\(zone.speed.formatted())× \(timecode(zone.start))–\(timecode(zone.end))") {
                        clip.edit.speedZones.removeAll { $0.id == zone.id }
                    }
                }
                ForEach(clip.edit.markers) { marker in
                    markerChip(marker)
                }
            }
        }
    }

    private func markerChip(_ marker: TimelineMarker) -> some View {
        HStack(spacing: 5) {
            Button {
                player.seekSource(to: marker.time)
            } label: {
                Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.purple)
            }
            .buttonStyle(.plain)
            TextField("Marker", text: Binding(
                get: { clip.edit.markers.first(where: { $0.id == marker.id })?.name ?? marker.name },
                set: { name in
                    guard let index = clip.edit.markers.firstIndex(where: { $0.id == marker.id }) else { return }
                    clip.edit.markers[index].name = name
                }
            ))
            .textFieldStyle(.plain)
            .font(.caption2)
            .frame(width: 72)
            Text(timecode(marker.time)).font(.caption2.monospacedDigit())
            Button {
                clip.edit.markers.removeAll { $0.id == marker.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(.separator))
    }

    private func chip(icon: String, color: Color, text: String,
                      remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
            Text(text).font(.caption2.monospacedDigit())
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(.separator))
    }
}

// MARK: - The timeline instrument

private struct TimelineBar: View {
    @ObservedObject var clip: Clip
    @ObservedObject var player: PlayerController
    var duration: Double
    var pendingCutStart: Double?
    var pendingSpeedStart: Double?

    private let rulerHeight: CGFloat = 16
    private let handleHeight: CGFloat = 12
    private var fps: Double { clip.info?.fps ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let trackHeight = geo.size.height - rulerHeight - handleHeight
            let x = { (t: Double) -> CGFloat in
                duration > 0 ? CGFloat(t / duration) * w : 0
            }

            VStack(spacing: 0) {
                Ruler(duration: duration)
                    .frame(height: rulerHeight)

                // The track: seekable, with the edit painted onto it.
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(TL.track)
                    if let filmstrip = clip.timelineFilmstrip {
                        Image(nsImage: filmstrip)
                            .resizable()
                            .frame(width: w, height: trackHeight)
                            .saturation(0.72)
                            .opacity(0.62)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    let inX = x(clip.edit.inPoint)
                    let outX = x(clip.edit.effectiveOut(duration: duration))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(TL.kept)
                        .frame(width: max(outX - inX, 0))
                        .offset(x: inX)

                    ForEach(clip.edit.cuts) { cut in
                        Rectangle()
                            .fill(TL.cut)
                            .frame(width: max(x(cut.end) - x(cut.start), 2))
                            .offset(x: x(cut.start))
                    }
                    ForEach(clip.edit.speedZones) { zone in
                        ZStack {
                            Rectangle().fill(TL.speed)
                            Text("\(zone.speed.formatted())×")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                        }
                        .frame(width: max(x(zone.end) - x(zone.start), 2))
                        .offset(x: x(zone.start))
                    }
                    ForEach(clip.edit.markers) { marker in
                        VStack(spacing: 0) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 8))
                            Rectangle().frame(width: 1.5)
                        }
                        .foregroundStyle(.purple)
                        .frame(height: trackHeight, alignment: .top)
                        .offset(x: x(marker.time) - 0.75)
                    }

                    if let p = pendingCutStart { pendingMark(at: x(p), .red) }
                    if let p = pendingSpeedStart { pendingMark(at: x(p), .orange) }

                    // Playhead
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 1.5)
                        .offset(x: x(player.currentSourceTime) - 0.75)
                }
                .frame(height: trackHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0, w > 0 else { return }
                            let raw = Double(min(max(value.location.x / w, 0), 1)) * duration
                            let t = TimelineMath.snappedTime(raw, fps: fps, duration: duration)
                            player.seekSource(to: t)
                        }
                )

                // Handle strip: draggable in/out, kept out of the seek gesture's way.
                ZStack(alignment: .leading) {
                    handle(at: x(clip.edit.inPoint), width: w) { t in
                        clip.edit.inPoint = min(t, clip.edit.effectiveOut(duration: duration) - 0.2)
                    }
                    handle(at: x(clip.edit.effectiveOut(duration: duration)), width: w) { t in
                        clip.edit.outPoint = max(t, clip.edit.inPoint + 0.2)
                    }
                }
                .frame(height: handleHeight)
            }
        }
    }

    private func pendingMark(at xPos: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: 1.5).offset(x: xPos - 0.75)
    }

    private func handle(at xPos: CGFloat, width: CGFloat,
                        update: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(width: 5, height: handleHeight - 2)
            .offset(x: xPos - 2.5)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        let raw = Double(min(max((xPos + value.translation.width) / width, 0), 1)) * duration
                        let t = TimelineMath.snappedTime(raw, fps: fps, duration: duration)
                        update(t)
                    }
            )
            .help("Drag to trim")
    }
}

/// Time ruler: ticks at a sensible interval for the clip's length.
private struct Ruler: View {
    var duration: Double

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0.5 else { return }
            let intervals: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = intervals.first { duration / $0 <= 12 } ?? 600
            var t = 0.0
            while t <= duration {
                let xPos = CGFloat(t / duration) * size.width
                let isMajor = true
                let tick = Path { p in
                    p.move(to: CGPoint(x: xPos, y: size.height))
                    p.addLine(to: CGPoint(x: xPos, y: size.height - (isMajor ? 5 : 3)))
                }
                ctx.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                if t + step <= duration {   // no label crowding the right edge
                    let label = Text(format(seconds: t))
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    ctx.draw(ctx.resolve(label), at: CGPoint(x: xPos + 3, y: size.height - 9),
                             anchor: .leading)
                }
                t += step
            }
        }
    }
}
