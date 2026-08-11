import Foundation

/// `FlightStudio --selftest [work-dir]` — exercises the real pipeline headlessly:
/// synthesises an HDZero-style clip (H.265, full range, bt470bg tags, MPEG-TS),
/// applies a trim + middle cut + 2× speed ramp + music mix, exports with the same
/// command builder the GUI uses, and verifies the result with ffprobe.
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        do {
            try run()
            print("SELFTEST PASS")
            exit(0)
        } catch {
            print("SELFTEST FAIL: \(error)")
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func run() throws {
        let idx = CommandLine.arguments.firstIndex(of: "--selftest")!
        let workDir: URL
        if let dirArg = CommandLine.arguments.dropFirst(idx + 1).first {
            workDir = URL(fileURLWithPath: dirArg, isDirectory: true)
        } else {
            workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("flightstudio-selftest", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        print("selftest work dir: \(workDir.path)")

        // 1. Synthesise a clip shaped like HDZero output.
        let src = workDir.appendingPathComponent("hdz_001.ts")
        try FFmpeg.run([
            "-y",
            "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=60:duration=10",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
            "-vf", "scale=in_range=tv:out_range=full",
            "-c:v", "libx265", "-preset", "ultrafast", "-crf", "30",
            "-color_range", "pc", "-colorspace", "bt470bg",
            "-color_primaries", "bt470bg", "-color_trc", "smpte170m",
            "-c:a", "aac", "-b:a", "96k",
            "-f", "mpegts", src.path,
        ])
        let music = workDir.appendingPathComponent("music.wav")
        try FFmpeg.run([
            "-y", "-f", "lavfi", "-i", "sine=frequency=220:duration=30", music.path,
        ])

        // 1b. Recursive scanning finds clips nested in subfolders.
        let nested = workDir.appendingPathComponent("card/DCIM/100MEDIA", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedClip = nested.appendingPathComponent("hdz_002.ts")
        if !FileManager.default.fileExists(atPath: nestedClip.path) {
            try FileManager.default.copyItem(at: src, to: nestedClip)
        }
        let scanned = ClipStore.findVideoFiles(in: workDir.appendingPathComponent("card"))
        guard scanned.contains(where: {
            $0.standardizedFileURL.path == nestedClip.standardizedFileURL.path
        }) else {
            throw Failure("recursive scan missed \(nestedClip.path)")
        }
        guard !ClipStore.findVideoFiles(in: workDir, onlyTS: true, stopAtFirst: true).isEmpty else {
            throw Failure("stop-at-first .ts search found nothing")
        }
        let scannedFiles = ClipStore.scanVideoFiles(in: workDir.appendingPathComponent("card"))
        guard let scannedNested = scannedFiles.first(where: { $0.url == nestedClip.standardizedFileURL }),
              scannedNested.fileDate != .distantPast else {
            throw Failure("background scan descriptor missed filesystem metadata")
        }
        let injectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        guard Clip(url: nestedClip, fileDate: injectedDate).flightDate == injectedDate else {
            throw Failure("clip ignored preloaded scan metadata")
        }
        let filmstripOut = workDir.appendingPathComponent("filmstrip.jpg")
        let filmstripCommand = TimelineFilmstripBuilder.command(
            source: nestedClip, duration: 10, output: filmstripOut, frameCount: 6)
        guard filmstripCommand.filter({ $0 == "-i" }).count == 6,
              filmstripCommand.contains(where: { $0.contains("hstack=inputs=6") }),
              filmstripCommand.contains(where: { $0.contains("select=gte(n\\,12)") }),
              filmstripCommand.last == filmstripOut.path else {
            throw Failure("timeline filmstrip command did not sample the full recording")
        }
        let waveformOut = workDir.appendingPathComponent("waveform.png")
        let waveformCommand = TimelineWaveformBuilder.command(
            source: nestedClip, output: waveformOut, width: 10, height: 10)
        guard waveformCommand.contains(where: { $0.contains("showwavespic=s=320x40") }) else {
            throw Failure("timeline waveform command did not clamp its render size")
        }
        try FFmpeg.run(waveformCommand)
        let waveformBytes = (try FileManager.default.attributesOfItem(
            atPath: waveformOut.path)[.size]) as? Int64 ?? 0
        guard waveformBytes > 0 else {
            throw Failure("timeline waveform generation produced no image")
        }
        print("recursive scan ok: found nested clip at DCIM/100MEDIA")

        // 2. Probe it.
        let info = try Probe.probe(src)
        guard info.videoCodec == "hevc", info.width == 1280, abs(info.duration - 10) < 0.5 else {
            throw Failure("probe returned unexpected info: \(info)")
        }
        guard info.hasAudio else { throw Failure("probe missed the audio stream") }
        print("probe ok: \(info.width)x\(info.height) \(info.videoCodec) \(info.duration)s range=\(info.colorRange ?? "?")")

        guard Probe.frameRate(from: "60000/1001").map({ abs($0 - 59.94) < 0.01 }) == true,
              Probe.frameRate(from: "0/0") == nil, Probe.frameRate(from: "bogus") == nil else {
            throw Failure("frame-rate parsing mishandled ffprobe values")
        }
        print("frame-rate parsing ok")

        guard EditorTimecode.string(seconds: 3_661.5, fps: 60) == "01:01:01:30",
              EditorTimecode.string(seconds: 59.999, fps: 30) == "00:00:59:29",
              EditorTimecode.string(seconds: 1.25, fps: 0) == "00:00:01.250",
              EditorTimecode.string(seconds: .nan, fps: 60) == "00:00:00:00" else {
            throw Failure("editor timecode formatting mishandled hours, frames, or fallback precision")
        }
        print("editor timecode formatting ok")

        let snapped = TimelineMath.snappedTime(1.011, fps: 60, duration: 10)
        guard abs(snapped - (61.0 / 60.0)) < 0.000_001,
              TimelineMath.snappedTime(-2, fps: 60, duration: 10) == 0,
              TimelineMath.snappedTime(12, fps: 60, duration: 10) == 10 else {
            throw Failure("timeline frame snapping produced invalid source times")
        }
        print("timeline frame snapping ok")

        // 3. An edit that uses everything: trim 1–9, cut out 3–4, 2× ramp over 5–8, music under it.
        var plan = EditPlan()
        plan.inPoint = 1
        plan.outPoint = 9
        plan.cuts = [CutRange(start: 3, end: 4)]
        plan.speedZones = [SpeedZone(start: 5, end: 8, speed: 2.0)]
        plan.music = MusicTrack(url: music, volume: 0.5, fadeIn: 0.5, fadeOut: 1.0, muteOriginal: false)
        plan.sourceAudio = SourceAudioSettings(volume: 0.55, fadeIn: 0.25, fadeOut: 0.5)
        plan.title = TitleOverlay(text: "Lap: 100% 'fast'", start: 1.5, end: 2.5,
                                  position: .top)

        // 3a. Filename date parsing.
        let cal = Calendar.current
        guard let d1 = Clip.parseDate(from: "hdz_20250712_143005.ts"),
              cal.dateComponents([.year, .month, .day, .hour], from: d1)
                == DateComponents(year: 2025, month: 7, day: 12, hour: 14) else {
            throw Failure("date parse failed for hdz_20250712_143005.ts")
        }
        guard let d2 = Clip.parseDate(from: "2024-03-08 flight.ts"),
              cal.component(.month, from: d2) == 3 else {
            throw Failure("date parse failed for 2024-03-08 flight.ts")
        }
        guard Clip.parseDate(from: "hdz_047.ts") == nil else {
            throw Failure("parsed a date out of hdz_047.ts, which has none")
        }
        guard Clip.parseDate(from: "hdz_20250231_120000.ts") == nil else {
            throw Failure("accepted an impossible filename date")
        }
        print("date parsing ok")

        // 3b. Favorites survive a rescan/relaunch through library metadata.
        let favoriteClip = Clip(url: src)
        favoriteClip.favorite = false
        favoriteClip.favorite = true
        favoriteClip.addTag("race")
        favoriteClip.addTag("Race")
        guard Clip(url: src).favorite else {
            throw Failure("favorite metadata was not persisted")
        }
        guard Clip(url: src).tags == ["race"] else {
            throw Failure("tag metadata was not persisted or deduplicated")
        }
        favoriteClip.edit = EditPlan(inPoint: 1.5,
                                     markers: [TimelineMarker(time: 2, name: "Recovered")])
        favoriteClip.favorite = false // also flushes the coalesced edit draft
        let recoveredClip = Clip(url: src)
        guard recoveredClip.edit.inPoint == 1.5,
              recoveredClip.edit.markers.first?.name == "Recovered" else {
            throw Failure("automatic edit draft was not recovered")
        }
        print("library metadata and edit recovery ok")

        // The large-library index loads its payload once and serves keyed
        // records without reparsing the complete dictionary for every clip.
        let suiteName = "FlightStudio.SelfTest.\(UUID().uuidString)"
        guard let isolatedDefaults = UserDefaults(suiteName: suiteName) else {
            throw Failure("could not create isolated metadata defaults")
        }
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        let metadataKey = "metadata-index-test"
        let metadataIndex = ClipLibraryMetadataIndex(defaults: isolatedDefaults, key: metadataKey)
        let indexedURL = workDir.appendingPathComponent("indexed.ts")
        let indexedRecord = ClipLibraryRecord(favorite: true, tags: ["freestyle"], edit: plan)
        metadataIndex.save(indexedRecord, for: indexedURL)
        let reloadedIndex = ClipLibraryMetadataIndex(defaults: isolatedDefaults, key: metadataKey)
        guard metadataIndex.recordCount == 1, reloadedIndex.recordCount == 1,
              reloadedIndex.record(for: indexedURL) == indexedRecord else {
            throw Failure("library metadata index did not persist or reload records")
        }
        print("library metadata index ok")

        // 3c. Invalid timeline data is normalised before it can reach ffmpeg.
        var messy = EditPlan(inPoint: -2, outPoint: 99,
                             cuts: [CutRange(start: 2, end: 4), CutRange(start: 3, end: 6),
                                    CutRange(start: 8, end: 7)],
                             speedZones: [SpeedZone(start: -1, end: 2, speed: 99, rampDuration: 9)],
                             sourceAudio: SourceAudioSettings(volume: .infinity,
                                                              fadeIn: -.infinity,
                                                              fadeOut: .nan),
                             title: TitleOverlay(text: "   ", start: -.infinity, end: .nan))
        messy = messy.sanitized(duration: info.duration)
        guard messy.inPoint == 0, messy.effectiveOut(duration: info.duration) == info.duration,
              messy.cuts.count == 1, messy.cuts[0].start == 2, messy.cuts[0].end == 6,
              messy.speedZones[0].speed == 4, messy.speedZones[0].rampDuration <= 1,
              messy.sourceAudio == nil, messy.title == nil else {
            throw Failure("edit sanitisation did not clamp and merge malformed ranges")
        }
        var empty = EditPlan(inPoint: 5, outPoint: 5)
        guard empty.validationError(duration: info.duration) != nil else {
            throw Failure("an empty trim was accepted for export")
        }
        empty = EditPlan(cuts: [CutRange(start: 0, end: info.duration)])
        guard empty.validationError(duration: info.duration) != nil else {
            throw Failure("an all-cut edit was accepted for export")
        }
        print("edit validation ok")

        // Quick Highlight preserves its full window where possible and clamps
        // cleanly at both source edges and on short recordings.
        var highlight = EditPlan()
        highlight.setHighlight(around: 2, length: 6, duration: 10)
        guard highlight.inPoint == 0, highlight.outPoint == 6 else {
            throw Failure("early quick highlight did not slide to the source start")
        }
        highlight.setHighlight(around: 9, length: 6, duration: 10)
        guard highlight.inPoint == 4, highlight.outPoint == 10 else {
            throw Failure("late quick highlight did not slide to the source end")
        }
        highlight.setHighlight(around: 2, length: 30, duration: 10)
        guard highlight.inPoint == 0, highlight.outPoint == 10 else {
            throw Failure("quick highlight mishandled a short recording")
        }
        print("quick highlight boundaries ok")

        // 3d. Project sidecars preserve a full edit, including music settings.
        let projectClip = Clip(url: src)
        projectClip.edit = plan
        let projectData = try EditProjectFile.encode(clip: projectClip)
        let loadedPlan = try EditProjectFile.decode(projectData, for: projectClip)
        guard loadedPlan == plan else {
            throw Failure("edit project did not round-trip")
        }
        print("edit project ok")

        // 3e. Every non-destructive edit can be undone and redone.
        let historyClip = Clip(url: src)
        historyClip.clearEditHistory()
        historyClip.edit.inPoint = 2
        guard historyClip.canUndoEdit else { throw Failure("edit history did not record a trim") }
        historyClip.undoEdit()
        guard historyClip.edit.inPoint == 0, historyClip.canRedoEdit else {
            throw Failure("undo did not restore the previous edit")
        }
        historyClip.redoEdit()
        guard historyClip.edit.inPoint == 2 else {
            throw Failure("redo did not restore the edited trim")
        }
        print("edit history ok")

        // 3f. Markers persist and are clamped to the editable source range.
        let marked = EditPlan(inPoint: 1, outPoint: 9,
                              markers: [TimelineMarker(time: -1, name: " Start "),
                                        TimelineMarker(time: 12, name: "Finish")])
            .sanitized(duration: info.duration)
        guard marked.markers.map(\.time) == [1, 9], marked.markers[0].name == "Start" else {
            throw Failure("timeline markers were not sanitised")
        }
        print("timeline markers ok")

        // 3g. Queued and on-disk name collisions receive predictable suffixes.
        let exportFolder = workDir.appendingPathComponent("exports", isDirectory: true)
        let first = OutputNamer.uniqueURL(in: exportFolder, baseName: "flight", fileExtension: "mp4",
                                          fileExists: { _ in false })
        let second = OutputNamer.uniqueURL(in: exportFolder, baseName: "flight", fileExtension: "mp4",
                                           reserved: Set([first]), fileExists: { _ in false })
        let third = OutputNamer.uniqueURL(in: exportFolder, baseName: "flight", fileExtension: "mp4",
                                          fileExists: { $0 == first || $0 == second })
        guard first.lastPathComponent == "flight.mp4", second.lastPathComponent == "flight 2.mp4",
              third.lastPathComponent == "flight 3.mp4" else {
            throw Failure("output-name collision handling is not deterministic")
        }
        print("output naming ok")

        // Export jobs survive relaunches with their exact edit and probe data.
        // A running job recovers as retryable, never as a completed output.
        let exportJobID = UUID()
        let exportSnapshot = ExportJobSnapshot(
            id: exportJobID,
            clips: [ExportClipSnapshot(url: src, info: info, edit: plan)],
            settings: ExportSettings(), outputURL: first, state: .running, progress: 0.6)
        let exportJournalURL = workDir.appendingPathComponent("export-queue.json")
        try ExportQueueStore.save([exportSnapshot], to: exportJournalURL)
        let recoveredExports = try ExportQueueStore.load(from: exportJournalURL)
        guard recoveredExports.count == 1,
              recoveredExports[0].id == exportJobID,
              recoveredExports[0].clips[0].edit == plan,
              recoveredExports[0].clips[0].info == info,
              recoveredExports[0].state == .failed(
                "Export was interrupted. The incomplete staging file was removed; retry when ready."),
              recoveredExports[0].progress == 0 else {
            throw Failure("export queue journal did not recover an interrupted encode")
        }
        let corruptExportJournal = workDir.appendingPathComponent("corrupt-export-queue.json")
        try Data(#"{"version":99,"jobs":[]}"#.utf8).write(to: corruptExportJournal)
        var rejectedUnknownJournal = false
        do {
            _ = try ExportQueueStore.load(from: corruptExportJournal)
        } catch {
            rejectedUnknownJournal = true
        }
        guard rejectedUnknownJournal else {
            throw Failure("unsupported export queue journal version was accepted")
        }

        // Final outputs are promoted only after a complete staging file exists,
        // and replacing an export never exposes half-written bytes.
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let promoted = exportFolder.appendingPathComponent("atomic.mp4")
        let staging = ExportOutput.stagingURL(for: promoted, jobID: exportJobID)
        try Data("old".utf8).write(to: promoted)
        try Data("new".utf8).write(to: staging)
        try ExportOutput.promote(stagingURL: staging, to: promoted)
        guard try Data(contentsOf: promoted) == Data("new".utf8),
              !FileManager.default.fileExists(atPath: staging.path) else {
            throw Failure("staged export was not promoted atomically")
        }
        print("export queue recovery and atomic output promotion ok")

        // 3h. Source↔output time mapping must round-trip through cuts and ramps.
        for t in stride(from: plan.inPoint, to: 9.0, by: 0.25) {
            // Cut interiors and their boundaries legitimately collapse to one output time.
            let inCut = plan.cuts.contains { t >= $0.start && t <= $0.end }
            if inCut { continue }
            let o = plan.outputTime(forSource: t, duration: info.duration)
            let back = plan.sourceTime(forOutput: o, duration: info.duration)
            guard abs(back - t) < 0.05 else {
                throw Failure("time mapping round-trip drifted at t=\(t): back=\(back)")
            }
        }
        print("time mapping ok")

        let expected = plan.outputDuration(duration: info.duration)
        // 7 s of kept source; the 3 s zone at ~2× (eased edges) squeezes to ~1.7 s → about 5.7 s out.
        guard expected > 4.5 && expected < 7.0 else {
            throw Failure("outputDuration \(expected) is outside the plausible range")
        }
        print("planned output duration: \(String(format: "%.2f", expected))s")

        var settings = ExportSettings()
        settings.preset = .master
        settings.masterQuality = .compact
        settings.colorMode = .fixRange
        settings.keepAudio = true

        let out = workDir.appendingPathComponent("edited.mp4")
        let commandsJobID = UUID()
        defer { try? FileManager.default.removeItem(
            at: ExportCommandBuilder.titleAssetURL(jobID: commandsJobID)) }
        let commands = ExportCommandBuilder.build(
            plan: plan, settings: settings, info: info,
            source: src, output: out, jobID: commandsJobID)
        guard commands.count == 1 else { throw Failure("master preset should be one pass") }
        guard commands[0].contains(where: {
            $0.contains("volume=0.550,afade=t=in:d=0.250")
                && $0.contains("afade=t=out")
        }) else {
            throw Failure("source audio volume and fades were missing from the export graph")
        }
        guard commands[0].contains(where: {
            $0.contains("overlay=x=(W-w)/2:y=H*0.08")
                && $0.contains("enable='between(t,")
        }), FileManager.default.fileExists(atPath: ExportCommandBuilder.titleAssetURL(
            jobID: commandsJobID).path) else {
            throw Failure("timed title image, placement or visibility was missing from the export graph")
        }
        print("running export…")
        try FFmpeg.run(commands[0])

        // 4. Verify the export.
        let outInfo = try Probe.probe(out)
        guard abs(outInfo.duration - expected) < 0.35 else {
            throw Failure("export duration \(outInfo.duration) vs planned \(expected)")
        }
        guard outInfo.hasAudio else { throw Failure("export lost its audio") }
        guard outInfo.colorRange == "tv" else {
            throw Failure("colour range fix missing: got \(outInfo.colorRange ?? "untagged")")
        }
        guard outInfo.videoCodec == "h264" else { throw Failure("wrong codec \(outInfo.videoCodec)") }
        print("edited export ok: \(String(format: "%.2f", outInfo.duration))s h264 range=tv audio=yes")

        // 4b. The edit-preview AVComposition builds from a remuxed preview and
        // comes out the same length as the export will.
        let previewMP4 = workDir.appendingPathComponent("preview.mp4")
        try FFmpeg.run(["-y", "-i", src.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c", "copy", "-movflags", "+faststart", "-tag:v", "hvc1",
                        previewMP4.path])
        let compSem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var compSeconds: Double = -1
        nonisolated(unsafe) var compMixInputs = 0
        nonisolated(unsafe) var compError: (any Error)?
        let compPlan = plan
        let compDuration = info.duration
        Task.detached {
            do {
                let (comp, mix) = try await PlayerController.buildEditComposition(
                    plan: compPlan, sourceDuration: compDuration, previewURL: previewMP4)
                compSeconds = comp.duration.seconds
                if mix == nil { compError = Failure("audio mix missing despite music track") }
                compMixInputs = mix?.inputParameters.count ?? 0
            } catch {
                compError = error
            }
            compSem.signal()
        }
        guard compSem.wait(timeout: .now() + 30) == .success else {
            throw Failure("composition build timed out")
        }
        if let compError { throw compError }
        guard abs(compSeconds - expected) < 0.35, compMixInputs == 2 else {
            throw Failure("composition duration \(compSeconds) vs planned \(expected)")
        }
        print("edit-preview composition ok: \(String(format: "%.2f", compSeconds))s with audio mix")

        // 5. Remux preset: instant rewrap, hvc1 tag, playable container.
        var remuxSettings = ExportSettings()
        remuxSettings.preset = .remux
        let remuxOut = workDir.appendingPathComponent("remux.mp4")
        let remuxCommands = ExportCommandBuilder.build(
            plan: EditPlan(), settings: remuxSettings, info: info,
            source: src, output: remuxOut, jobID: UUID())
        try FFmpeg.run(remuxCommands[0])
        let remuxInfo = try Probe.probe(remuxOut)
        guard remuxInfo.videoCodec == "hevc", abs(remuxInfo.duration - 10) < 0.5 else {
            throw Failure("remux came out wrong: \(remuxInfo)")
        }
        print("remux ok: \(String(format: "%.2f", remuxInfo.duration))s hevc, no re-encode")

        // 5b. Stitching builds one concat-filter export and keeps compatible audio.
        let stitchOut = workDir.appendingPathComponent("stitched.mp4")
        let stitchArgs = try StitchCommandBuilder.build(inputs: [(src, info), (src, info)],
                                                         settings: settings, output: stitchOut)
        guard stitchArgs.contains(where: { $0.contains("concat=n=2:v=1:a=0") }),
              stitchArgs.contains("[aout]"), stitchArgs.contains(stitchOut.path) else {
            throw Failure("stitch command did not build a concatenated A/V export")
        }
        print("stitch command ok")

        // Publishing journals preserve completed destinations and turn a
        // process-interrupted upload into an explicit retryable failure.
        var publishSettings = ExportSettings()
        publishSettings.preset = .social
        var recoveryDraft = PublishDraft()
        recoveryDraft.title = "Recovery test"
        recoveryDraft.platforms = [.youtube, .tiktok]
        let publishSnapshot = PublishJobSnapshot(
            id: UUID(), exportURL: stitchOut, settings: publishSettings, draft: recoveryDraft,
            states: [.youtube: .uploaded, .tiktok: .uploading], progress: [.youtube: 1, .tiktok: 0.4])
        let journalURL = workDir.appendingPathComponent("publish-queue.json")
        try PublishQueueStore.save([publishSnapshot], to: journalURL)
        let recoveredPublish = try PublishQueueStore.load(from: journalURL)
        guard recoveredPublish.count == 1,
              recoveredPublish[0].id == publishSnapshot.id,
              recoveredPublish[0].states[.youtube] == .uploaded,
              recoveredPublish[0].states[.tiktok] == .failed("Upload was interrupted. Retry when connected."),
              recoveredPublish[0].progress[.tiktok] == 0.4 else {
            throw Failure("publishing queue journal did not recover platform state")
        }
        print("publishing queue recovery ok")

        let publishSuiteName = "FlightStudio.PublishDraft.SelfTest.\(UUID().uuidString)"
        guard let publishDefaults = UserDefaults(suiteName: publishSuiteName) else {
            throw Failure("could not create isolated publish draft defaults")
        }
        defer { publishDefaults.removePersistentDomain(forName: publishSuiteName) }
        let draftKey = "draft-test"
        var savedDraft = PublishDraft()
        savedDraft.title = "Final lap"
        savedDraft.caption = "Fast DVR highlight"
        savedDraft.hashtags = "#fpv"
        savedDraft.visibility = .unlisted
        savedDraft.platforms = [.youtube, .instagram]
        PublishDraftStore.save(savedDraft, defaults: publishDefaults, key: draftKey)
        guard PublishDraftStore.load(defaults: publishDefaults, key: draftKey) == savedDraft else {
            throw Failure("publish composer draft did not survive persistence")
        }
        publishDefaults.set(Data("invalid".utf8), forKey: draftKey)
        guard PublishDraftStore.load(defaults: publishDefaults, key: draftKey) == PublishDraft() else {
            throw Failure("corrupt publish composer draft did not recover safely")
        }
        print("publish composer draft recovery ok")

        // 6. Social preset: two passes, lands near the target size.
        var socialSettings = ExportSettings()
        socialSettings.preset = .social
        socialSettings.socialTargetMB = 4
        let socialOut = workDir.appendingPathComponent("social.mp4")
        let socialCommands = ExportCommandBuilder.build(
            plan: plan, settings: socialSettings, info: info,
            source: src, output: socialOut, jobID: UUID())
        guard socialCommands.count == 2 else { throw Failure("social preset should be two passes") }
        guard socialCommands[0].contains(where: { $0.contains("pad=1080:1920") }) else {
            throw Failure("social export did not apply the vertical delivery canvas")
        }
        socialSettings.socialFraming = .fill
        socialSettings.cropPositionX = 0.25
        socialSettings.cropPositionY = 0.75
        let fillCommands = ExportCommandBuilder.build(
            plan: plan, settings: socialSettings, info: info,
            source: src, output: socialOut, jobID: UUID())
        guard fillCommands[0].contains(where: {
            $0.contains("force_original_aspect_ratio=increase,crop=1080:1920")
                && $0.contains("(iw-ow)*0.2500:(ih-oh)*0.7500")
        }) else {
            throw Failure("positioned fill framing did not crop to the requested canvas")
        }
        socialSettings.socialFraming = .blurredBackground
        let blurCommands = ExportCommandBuilder.build(
            plan: plan, settings: socialSettings, info: info,
            source: src, output: socialOut, jobID: UUID())
        guard blurCommands[0].contains(where: {
            $0.contains("split=2[background][foreground]")
                && $0.contains("crop=1080:1920,boxblur=20:2")
                && $0.contains("[blurred][front]overlay=(W-w)/2:(H-h)/2")
        }) else {
            throw Failure("blurred social framing did not build a full-canvas background")
        }
        let encodedSettings = try JSONEncoder().encode(socialSettings)
        guard var legacySettingsJSON = try JSONSerialization.jsonObject(with: encodedSettings) as? [String: Any] else {
            throw Failure("could not construct legacy export settings fixture")
        }
        legacySettingsJSON.removeValue(forKey: "cropPositionX")
        legacySettingsJSON.removeValue(forKey: "cropPositionY")
        let decodedLegacySettings = try JSONDecoder().decode(
            ExportSettings.self, from: JSONSerialization.data(withJSONObject: legacySettingsJSON))
        guard decodedLegacySettings.cropPositionX == 0.5,
              decodedLegacySettings.cropPositionY == 0.5 else {
            throw Failure("legacy export settings did not default to a centered crop")
        }
        var squareSettings = socialSettings
        squareSettings.socialProfile = .instagramSquare
        squareSettings.socialFraming = .fit
        let squareCommands = ExportCommandBuilder.build(
            plan: plan, settings: squareSettings, info: info,
            source: src, output: socialOut, jobID: UUID())
        guard squareCommands[0].contains(where: {
            $0.contains("scale=1080:1080") && $0.contains("pad=1080:1080")
        }) else {
            throw Failure("Instagram square preset did not build a 1:1 canvas")
        }
        var portraitSettings = squareSettings
        portraitSettings.socialProfile = .instagramPortrait
        let portraitCommands = ExportCommandBuilder.build(
            plan: plan, settings: portraitSettings, info: info,
            source: src, output: socialOut, jobID: UUID())
        guard portraitCommands[0].contains(where: {
            $0.contains("scale=1080:1350") && $0.contains("pad=1080:1350")
        }) else {
            throw Failure("Instagram portrait preset did not build a 4:5 canvas")
        }
        var publishDraft = PublishDraft()
        publishDraft.title = "Clean gap"
        publishDraft.platforms = [.tiktok, .youtube]
        guard !PublishValidator.validate(draft: publishDraft, settings: socialSettings)
            .contains(where: { $0.severity == .error }) else {
            throw Failure("valid social publishing draft was rejected")
        }
        let wrongCanvas = ClipInfo(duration: 12, width: 1920, height: 1080, fps: 60,
                                   videoCodec: "h264", hasAudio: true,
                                   colorRange: "tv", fileSize: 2_000_000)
        guard PublishValidator.validate(draft: publishDraft, settings: socialSettings,
                                        media: wrongCanvas, fileExists: true)
            .contains(where: { $0.severity == .error && $0.message.contains("expected 1080×1920") }) else {
            throw Failure("wrong social delivery canvas passed publishing preflight")
        }
        var instagramDraft = PublishDraft()
        instagramDraft.title = "Square post"
        instagramDraft.platforms = [.instagram]
        let squareMedia = ClipInfo(duration: 12, width: 1080, height: 1080, fps: 60,
                                   videoCodec: "h264", hasAudio: true,
                                   colorRange: "tv", fileSize: 2_000_000)
        guard !PublishValidator.validate(draft: instagramDraft, settings: squareSettings,
                                         media: squareMedia, fileExists: true)
            .contains(where: { $0.severity == .error }) else {
            throw Failure("valid Instagram square post failed publishing preflight")
        }
        var invalidPublishSettings = ExportSettings()
        invalidPublishSettings.preset = .master
        guard PublishValidator.validate(draft: publishDraft, settings: invalidPublishSettings)
            .contains(where: { $0.severity == .error }) else {
            throw Failure("non-vertical TikTok publishing draft was accepted")
        }
        print("publish validation ok")
        for c in socialCommands { try FFmpeg.run(c) }
        let socialSize = (try FileManager.default.attributesOfItem(atPath: socialOut.path)[.size]) as? Int64 ?? 0
        let socialMB = Double(socialSize) / 1_000_000
        guard socialMB > 2.0 && socialMB < 6.0 else {
            throw Failure("social export \(socialMB) MB is far from the 4 MB target")
        }
        print("social ok: \(String(format: "%.2f", socialMB)) MB against a 4 MB target")
    }
}
