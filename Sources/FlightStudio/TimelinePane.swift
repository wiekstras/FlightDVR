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

    var duration: Double { clip.info?.duration ?? player.duration }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineBar(clip: clip, player: player, duration: duration,
                        pendingCutStart: pendingCutStart, pendingSpeedStart: pendingSpeedStart)
                .frame(height: 74)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if !clip.edit.cuts.isEmpty || !clip.edit.speedZones.isEmpty {
                EditChips(clip: clip)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.top, 10)

            // The bench: one flat row of tools, grouped by tracked labels.
            HStack(alignment: .top, spacing: 0) {
                tool("Trim") {
                    Button("In") { clip.edit.inPoint = player.currentSourceTime }
                    Button("Out") { clip.edit.outPoint = player.currentSourceTime }
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
                tool("Music") {
                    MusicControls(clip: clip)
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

private struct MusicControls: View {
    @ObservedObject var clip: Clip

    var body: some View {
        if let music = clip.edit.music {
            Text(music.url.deletingPathExtension().lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 120)
            Slider(value: Binding(
                get: { clip.edit.music?.volume ?? 0.8 },
                set: { clip.edit.music?.volume = $0 }
            ), in: 0...1)
            .frame(width: 76)
            HStack(spacing: 3) {
                Text("In")
                Slider(value: Binding(
                    get: { clip.edit.music?.fadeIn ?? 1 },
                    set: { clip.edit.music?.fadeIn = $0 }
                ), in: 0...10, step: 0.25)
                .frame(width: 54)
                Text("Out")
                Slider(value: Binding(
                    get: { clip.edit.music?.fadeOut ?? 2 },
                    set: { clip.edit.music?.fadeOut = $0 }
                ), in: 0...10, step: 0.25)
                .frame(width: 54)
            }
            .font(.caption2)
            Toggle("Mute clip", isOn: Binding(
                get: { clip.edit.music?.muteOriginal ?? true },
                set: { clip.edit.music?.muteOriginal = $0 }
            ))
            .font(.caption)
            Button {
                clip.edit.music = nil
            } label: {
                Image(systemName: "xmark")
            }
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
            }
        }
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
                            let t = Double(min(max(value.location.x / w, 0), 1)) * duration
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
                        let t = Double(min(max((xPos + value.translation.width) / width, 0), 1)) * duration
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
