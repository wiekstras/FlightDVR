import SwiftUI
import AVKit
import Combine

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var currentTime: Double = 0       // time in whatever item is playing
    @Published var duration: Double = 0          // duration of that item
    @Published var isReady = false
    @Published var previewingEdit = false        // playing the composition, not the raw clip
    private var timeObserver: Any?
    private(set) weak var clip: Clip?
    private weak var store: ClipStore?
    private var buildTask: Task<Void, Never>?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let controller = self else { return }
            Task { @MainActor in
                controller.currentTime = time.seconds
            }
        }
    }

    private var sourceDuration: Double { clip?.info?.duration ?? 0 }

    /// The source-time moment on screen — what the timeline bar shows. When the
    /// edit is being previewed, output time is mapped back through the plan.
    var currentSourceTime: Double {
        guard let clip, previewingEdit, !clip.edit.isDefault else { return currentTime }
        return clip.edit.sourceTime(forOutput: currentTime, duration: sourceDuration)
    }

    func load(clip: Clip?, store: ClipStore) {
        self.clip = clip
        self.store = store
        reloadItem(seekToSource: 0)
    }

    func setEditPreview(_ on: Bool) {
        guard previewingEdit != on else { return }
        let keep = currentSourceTime
        previewingEdit = on
        reloadItem(seekToSource: keep)
    }

    /// Call when the edit plan changed while it is being previewed.
    func editChanged() {
        guard previewingEdit else { return }
        reloadItem(seekToSource: currentSourceTime)
    }

    private func reloadItem(seekToSource: Double) {
        buildTask?.cancel()
        isReady = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        guard let clip, let store else { return }
        duration = clip.info?.duration ?? 0
        let wantEdit = previewingEdit && !clip.edit.isDefault
        store.preparePreview(for: clip) { [weak self] url in
            guard let self, let url, self.clip === clip else { return }
            if wantEdit {
                self.buildTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let (comp, mix) = try await Self.buildEditComposition(
                            plan: clip.edit, sourceDuration: clip.info?.duration ?? 0, previewURL: url)
                        guard !Task.isCancelled, self.clip === clip else { return }
                        let item = AVPlayerItem(asset: comp)
                        item.audioMix = mix
                        self.player.replaceCurrentItem(with: item)
                        self.duration = clip.edit.outputDuration(duration: self.sourceDuration)
                        self.isReady = true
                        self.seekSource(to: seekToSource)
                    } catch {
                        // Fall back to the raw clip rather than a black player.
                        self.previewingEdit = false
                        self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                        self.duration = clip.info?.duration ?? 0
                        self.isReady = true
                    }
                }
            } else {
                self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                self.duration = clip.info?.duration ?? 0
                self.isReady = true
                if seekToSource > 0 { self.seekSource(to: seekToSource) }
            }
        }
    }

    /// Seek expressed in source time; mapped when previewing the edit.
    func seekSource(to sourceSeconds: Double) {
        var target = sourceSeconds
        if let clip, previewingEdit, !clip.edit.isDefault {
            target = clip.edit.outputTime(forSource: sourceSeconds, duration: sourceDuration)
        }
        player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    /// Review controls operate in source time, so they stay intuitive whether
    /// the live edit preview is currently enabled or not.
    func jump(by seconds: Double) {
        seekSource(to: currentSourceTime + seconds)
    }

    func stepFrame(by frames: Int) {
        let fps = max(clip?.info?.fps ?? 30, 1)
        jump(by: Double(frames) / fps)
    }

    // MARK: Composition

    /// The edit plan realised as an AVMutableComposition over the remuxed
    /// preview: cuts skipped, speed zones scaled segment by segment (the eased
    /// ramps come through as the same stepped sub-segments the export uses),
    /// music laid under it with fades via an AVAudioMix.
    nonisolated static func buildEditComposition(plan: EditPlan, sourceDuration: Double,
                                                 previewURL: URL) async throws
        -> (AVMutableComposition, AVMutableAudioMix?) {
        let asset = AVURLAsset(url: previewURL)
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first else {
            throw FFmpeg.ProcessError(command: "", stderr: "no video track in preview")
        }
        let aSrc = try await asset.loadTracks(withMediaType: .audio).first
        let duration = sourceDuration > 0 ? sourceDuration : (try await asset.load(.duration)).seconds

        let comp = AVMutableComposition()
        let ts: CMTimeScale = 600
        guard let vDst = comp.addMutableTrack(withMediaType: .video,
                                              preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw FFmpeg.ProcessError(command: "", stderr: "could not build composition")
        }
        let wantOriginalAudio = aSrc != nil && !(plan.music?.muteOriginal ?? false)
        let aDst = wantOriginalAudio
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var cursor = CMTime.zero
        for seg in plan.resolvedSegments(duration: duration) {
            let range = CMTimeRange(start: CMTime(seconds: seg.start, preferredTimescale: ts),
                                    duration: CMTime(seconds: seg.end - seg.start, preferredTimescale: ts))
            try vDst.insertTimeRange(range, of: vSrc, at: cursor)
            if let aDst, let aSrc { try aDst.insertTimeRange(range, of: aSrc, at: cursor) }
            var placed = range.duration
            if abs(seg.speed - 1) > 0.001 {
                let scaled = CMTime(seconds: (seg.end - seg.start) / seg.speed, preferredTimescale: ts)
                let insertedRange = CMTimeRange(start: cursor, duration: range.duration)
                vDst.scaleTimeRange(insertedRange, toDuration: scaled)
                aDst?.scaleTimeRange(insertedRange, toDuration: scaled)
                placed = scaled
            }
            cursor = CMTimeAdd(cursor, placed)
        }
        vDst.preferredTransform = try await vSrc.load(.preferredTransform)

        var mixParams: [AVMutableAudioMixInputParameters] = []
        if let music = plan.music {
            let mAsset = AVURLAsset(url: music.url)
            if let mSrc = try await mAsset.loadTracks(withMediaType: .audio).first,
               let mDst = comp.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) {
                let mDur = try await mAsset.load(.duration)
                let useDur = CMTimeMinimum(mDur, cursor)
                try mDst.insertTimeRange(CMTimeRange(start: .zero, duration: useDur), of: mSrc, at: .zero)
                let p = AVMutableAudioMixInputParameters(track: mDst)
                let vol = Float(music.volume)
                p.setVolume(vol, at: .zero)
                if music.fadeIn > 0.05 {
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol,
                                    timeRange: CMTimeRange(start: .zero,
                                                           duration: CMTime(seconds: music.fadeIn, preferredTimescale: ts)))
                }
                if music.fadeOut > 0.05 {
                    let start = max(0, useDur.seconds - music.fadeOut)
                    p.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: ts),
                                                           duration: CMTime(seconds: music.fadeOut, preferredTimescale: ts)))
                }
                mixParams.append(p)
            }
        }
        var mix: AVMutableAudioMix?
        if !mixParams.isEmpty {
            let m = AVMutableAudioMix()
            m.inputParameters = mixParams
            mix = m
        }
        return (comp, mix)
    }
}

/// AVKit's SwiftUI VideoPlayer crashes at metadata-instantiation time in
/// SPM-built apps, so wrap AVPlayerView ourselves — sturdier and more capable.
struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct PlayerPane: View {
    @ObservedObject var player: PlayerController
    @EnvironmentObject var store: ClipStore

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PlayerViewRepresentable(player: player.player)
                if !player.isReady {
                    ProgressView("Preparing preview…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .background(Color.black)
            HStack(spacing: 12) {
                Button {
                    player.jump(by: -5)
                } label: {
                    Image(systemName: "gobackward.5")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("j", modifiers: [])
                .help("Back 5 seconds (J)")
                Button {
                    player.stepFrame(by: -1)
                } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous frame (←)")
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: "playpause.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("k", modifiers: [])
                .help("Play or pause (K)")
                Button {
                    player.stepFrame(by: 1)
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next frame (→)")
                Button {
                    player.jump(by: 5)
                } label: {
                    Image(systemName: "goforward.5")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("l", modifiers: [])
                .help("Forward 5 seconds (L)")
                Text(timecode(player.currentTime))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                Text("/ \(timecode(player.duration))")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                if let clip = store.selectedClip, !clip.edit.isDefault, let info = clip.info {
                    HStack(spacing: 4) {
                        Eyebrow("Out")
                        Text(timecode(clip.edit.outputDuration(duration: info.duration)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(
                        get: { player.previewingEdit },
                        set: { player.setEditPreview($0) }
                    )) {
                        Text("Preview edit")
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Play the clip with cuts, speed ramps and music applied")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
    let total = seconds
    let m = Int(total) / 60
    let s = total - Double(m * 60)
    return String(format: "%d:%04.1f", m, s)
}
