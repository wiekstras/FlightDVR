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

    var duration: Double { clip.info?.duration ?? player.duration }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineBar(clip: clip, player: player, duration: duration,
                        pendingCutStart: pendingCutStart, pendingSpeedStart: pendingSpeedStart)
                .frame(height: 56)

            HStack(spacing: 18) {
                // Trim
                GroupBox("Trim") {
                    HStack {
                        Button("Set In") { clip.edit.inPoint = player.currentSourceTime }
                        Button("Set Out") { clip.edit.outPoint = player.currentSourceTime }
                        Button("Reset") { clip.edit = EditPlan() }
                    }
                    .controlSize(.small)
                }

                // Cut out a middle section
                GroupBox("Cut out") {
                    HStack {
                        if let start = pendingCutStart {
                            Button("End cut at playhead") {
                                let end = player.currentSourceTime
                                if end > start + 0.05 {
                                    clip.edit.cuts.append(CutRange(start: start, end: end))
                                }
                                pendingCutStart = nil
                            }
                            .tint(.red)
                            Button("Cancel") { pendingCutStart = nil }
                        } else {
                            Button("Start cut at playhead") { pendingCutStart = player.currentSourceTime }
                        }
                    }
                    .controlSize(.small)
                }

                // Speed ramp zone
                GroupBox("Speed ramp") {
                    HStack {
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
                            .frame(width: 70)
                            Button("End zone at playhead") {
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
                            Button("Start zone at playhead") { pendingSpeedStart = player.currentSourceTime }
                        }
                    }
                    .controlSize(.small)
                }

                MusicBox(clip: clip)
                Spacer()
            }

            if !clip.edit.cuts.isEmpty || !clip.edit.speedZones.isEmpty {
                EditListRow(clip: clip)
            }
        }
        .padding(12)
        .onChange(of: clip.edit) { _, _ in
            // Live edit preview follows every change.
            player.editChanged()
        }
    }
}

private struct MusicBox: View {
    @ObservedObject var clip: Clip

    var body: some View {
        GroupBox("Music") {
            HStack {
                if let music = clip.edit.music {
                    Text(music.url.lastPathComponent)
                        .lineLimit(1)
                        .frame(maxWidth: 140)
                    Slider(value: Binding(
                        get: { clip.edit.music?.volume ?? 0.8 },
                        set: { clip.edit.music?.volume = $0 }
                    ), in: 0...1)
                    .frame(width: 80)
                    Toggle("Mute clip audio", isOn: Binding(
                        get: { clip.edit.music?.muteOriginal ?? true },
                        set: { clip.edit.music?.muteOriginal = $0 }
                    ))
                    Button {
                        clip.edit.music = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
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
            .controlSize(.small)
        }
    }
}

private struct EditListRow: View {
    @ObservedObject var clip: Clip

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(clip.edit.cuts) { cut in
                    HStack(spacing: 4) {
                        Image(systemName: "scissors").font(.caption2)
                        Text("\(timecode(cut.start))–\(timecode(cut.end))")
                            .font(.caption.monospacedDigit())
                        Button {
                            clip.edit.cuts.removeAll { $0.id == cut.id }
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.red.opacity(0.15), in: Capsule())
                }
                ForEach(clip.edit.speedZones) { zone in
                    HStack(spacing: 4) {
                        Image(systemName: "hare").font(.caption2)
                        Text("\(zone.speed, specifier: "%g")× \(timecode(zone.start))–\(timecode(zone.end))")
                            .font(.caption.monospacedDigit())
                        Button {
                            clip.edit.speedZones.removeAll { $0.id == zone.id }
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.orange.opacity(0.15), in: Capsule())
                }
            }
        }
    }
}

// MARK: - The timeline bar itself

private struct TimelineBar: View {
    @ObservedObject var clip: Clip
    @ObservedObject var player: PlayerController
    var duration: Double
    var pendingCutStart: Double?
    var pendingSpeedStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (t: Double) -> CGFloat in
                duration > 0 ? CGFloat(t / duration) * w : 0
            }
            ZStack(alignment: .leading) {
                // Base track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor))

                // Kept region between in/out
                let inX = x(clip.edit.inPoint)
                let outX = x(clip.edit.effectiveOut(duration: duration))
                RoundedRectangle(cornerRadius: 6)
                    .fill(.blue.opacity(0.35))
                    .frame(width: max(outX - inX, 0))
                    .offset(x: inX)

                // Cuts
                ForEach(clip.edit.cuts) { cut in
                    Rectangle()
                        .fill(.red.opacity(0.55))
                        .frame(width: max(x(cut.end) - x(cut.start), 2))
                        .offset(x: x(cut.start))
                }

                // Speed zones
                ForEach(clip.edit.speedZones) { zone in
                    ZStack {
                        Rectangle().fill(.orange.opacity(0.45))
                        Text("\(zone.speed, specifier: "%g")×")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(width: max(x(zone.end) - x(zone.start), 2))
                    .offset(x: x(zone.start))
                }

                // Pending markers
                if let p = pendingCutStart {
                    marker(at: x(p), color: .red)
                }
                if let p = pendingSpeedStart {
                    marker(at: x(p), color: .orange)
                }

                // Playhead
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: x(player.currentSourceTime) - 1)
                    .shadow(radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, w > 0 else { return }
                        let t = Double(min(max(value.location.x / w, 0), 1)) * duration
                        player.seekSource(to: t)
                    }
            )
        }
    }

    private func marker(at xPos: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 2)
            .offset(x: xPos - 1)
    }
}
