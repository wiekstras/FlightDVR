import Foundation
import AppKit

/// `FlightStudio --selftest [work-dir]` — exercises the real pipeline headlessly:
/// synthesises an HDZero-style clip (H.265, full range, bt470bg tags, MPEG-TS),
/// applies a trim + middle cut + 2× speed ramp + music mix, exports with the same
/// command builder the GUI uses, and verifies the result with ffprobe.
enum SelfTest {
    private final class RacingPublishProvider: PublishingProvider, @unchecked Sendable {
        let platform = PublishingPlatform.youtube
        private let lock = NSLock()
        private var uploadCount = 0

        func connectionStatus() async -> ProviderConnectionStatus {
            .connected(accountName: "Self-test")
        }

        func upload(file: URL, draft: PublishDraft,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
            lock.lock()
            uploadCount += 1
            let call = uploadCount
            lock.unlock()
            // Deliberately ignore task cancellation like a provider request
            // which cannot abort once the server has accepted its body.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + (call == 1 ? 0.2 : 0.03)) {
                    progress(call == 1 ? 0.25 : 1)
                    continuation.resume()
                }
            }
        }
    }

    @MainActor static func runIfRequested() {
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

    @MainActor static func run() throws {
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

        guard ClipStore.importFolder(for: [src]) == workDir.standardizedFileURL,
              ClipStore.importFolder(for: [nested]) == nested,
              ClipStore.importFolder(for: [workDir.appendingPathComponent("notes.txt")]) == nil,
              ClipStore.importFolder(for: [src, nestedClip]) == nil else {
            throw Failure("Finder import routing accepted an unsupported or ambiguous drop")
        }
        print("Finder drag-and-drop routing ok")

        // 2. Probe it.
        let info = try Probe.probe(src)
        guard info.videoCodec == "hevc", info.width == 1280, abs(info.duration - 10) < 0.5 else {
            throw Failure("probe returned unexpected info: \(info)")
        }
        guard info.hasAudio else { throw Failure("probe missed the audio stream") }
        print("probe ok: \(info.width)x\(info.height) \(info.videoCodec) \(info.duration)s range=\(info.colorRange ?? "?")")

        let metadataJournal = workDir.appendingPathComponent("metadata-cache-test.json")
        try? FileManager.default.removeItem(at: metadataJournal)
        let metadataCache = MediaMetadataCache(url: metadataJournal)
        metadataCache.store(info, for: "stable-media")
        try metadataCache.flush()
        guard MediaMetadataCache(url: metadataJournal).info(for: "stable-media") == info else {
            throw Failure("media metadata cache did not survive a relaunch")
        }
        metadataCache.store(info, for: "second")
        metadataCache.store(info, for: "third")
        try metadataCache.flush(maxRecords: 2)
        guard metadataCache.recordCount == 2 else {
            throw Failure("media metadata cache did not enforce its record cap")
        }
        let identityFile = workDir.appendingPathComponent("identity-test.bin")
        try Data("short".utf8).write(to: identityFile, options: .atomic)
        let firstIdentity = ClipStore.mediaCacheKey(for: identityFile)
        try Data("a meaningfully longer payload".utf8).write(to: identityFile, options: .atomic)
        guard ClipStore.mediaCacheKey(for: identityFile) != firstIdentity else {
            throw Failure("changed media did not invalidate its cached metadata")
        }
        guard MediaCacheFiles.isEvictable(URL(fileURLWithPath: "/cache/thumb-a.jpg")),
              MediaCacheFiles.isEvictable(URL(fileURLWithPath: "/cache/preview-a.mp4")),
              !MediaCacheFiles.isEvictable(URL(fileURLWithPath: "/cache/filmstrip-work-a.jpg")),
              !MediaCacheFiles.isEvictable(URL(fileURLWithPath: "/cache/title-a-0.png")) else {
            throw Failure("media cache accounting included active work or missed durable previews")
        }
        let evictionFolder = workDir.appendingPathComponent("cache-eviction", isDirectory: true)
        try FileManager.default.createDirectory(at: evictionFolder, withIntermediateDirectories: true)
        let oldCache = evictionFolder.appendingPathComponent("thumb-old.jpg")
        let newCache = evictionFolder.appendingPathComponent("preview-new.mp4")
        let activeWork = evictionFolder.appendingPathComponent("filmstrip-work-active.jpg")
        for url in [oldCache, newCache, activeWork] { try Data("1234".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: oldCache.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)],
                                              ofItemAtPath: newCache.path)
        ClipStore.enforceCacheCap(keeping: nil, cap: 4, in: evictionFolder)
        guard !FileManager.default.fileExists(atPath: oldCache.path),
              FileManager.default.fileExists(atPath: newCache.path),
              FileManager.default.fileExists(atPath: activeWork.path) else {
            throw Failure("media cache eviction did not preserve active work or newest assets")
        }
        print("durable media metadata cache ok")

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

        guard PlaybackMath.sanitizedRate(.nan) == 1,
              PlaybackMath.sanitizedRate(0.4) == 0.5,
              PlaybackMath.sanitizedRate(1.8) == 2,
              PlaybackMath.supportedRates == [0.25, 0.5, 1, 1.5, 2] else {
            throw Failure("playback speed sanitisation selected an unsupported rate")
        }
        print("playback speed controls ok")

        // 3. An edit that uses everything: trim 1–9, cut out 3–4, 2× ramp over 5–8, music under it.
        var plan = EditPlan()
        plan.inPoint = 1
        plan.outPoint = 9
        plan.cuts = [CutRange(start: 3, end: 4)]
        plan.speedZones = [SpeedZone(start: 5, end: 8, speed: 2.0)]
        plan.music = MusicTrack(url: music, volume: 0.5, fadeIn: 0.5, fadeOut: 1.0, muteOriginal: false)
        plan.sourceAudio = SourceAudioSettings(volume: 0.55, fadeIn: 0.25, fadeOut: 0.5)
        plan.titles = [
            TitleOverlay(text: "Lap: 100% 'fast'", start: 1.5, end: 2.5, position: .top),
            TitleOverlay(text: "Final push", start: 8.1, end: 8.8, position: .bottom)
        ]
        var trimReset = plan
        trimReset.markers = [TimelineMarker(time: 6, name: "Keep me")]
        trimReset.resetTrim()
        guard trimReset.inPoint == 0, trimReset.outPoint == nil,
              trimReset.cuts == plan.cuts,
              trimReset.speedZones == plan.speedZones,
              trimReset.music == plan.music,
              trimReset.sourceAudio == plan.sourceAudio,
              trimReset.titleOverlays == plan.titleOverlays,
              trimReset.markers.map(\.name) == ["Keep me"] else {
            throw Failure("resetting trim discarded unrelated edit work")
        }

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
        guard favoriteClip.saveCurrentHighlight(duration: info.duration) != nil else {
            throw Failure("valid edit could not be saved as a highlight")
        }
        favoriteClip.highlights[0].name = "Opening lap"
        favoriteClip.favorite = false // also flushes the coalesced edit draft
        let recoveredClip = Clip(url: src)
        guard recoveredClip.edit.inPoint == 1.5,
              recoveredClip.edit.markers.first?.name == "Recovered",
              recoveredClip.highlights.first?.name == "Opening lap",
              recoveredClip.highlights.first?.edit.inPoint == 1.5 else {
            throw Failure("automatic edit draft or highlight shelf was not recovered")
        }
        let detachedVariant = Clip.exportVariant(
            from: favoriteClip, edit: EditPlan(inPoint: 4, outPoint: 5))
        detachedVariant.edit.inPoint = 4.5
        favoriteClip.edit.inPoint = 8
        guard Clip(url: src).edit.inPoint == 1.5,
              detachedVariant.edit.inPoint == 4.5 else {
            throw Failure("detached export variant did not isolate queued and active edits")
        }
        print("library metadata, highlight shelf and edit recovery ok")

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
              messy.sourceAudio == nil, messy.title == nil, messy.titles == nil else {
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
        guard EditProjectFile.isProjectURL(URL(fileURLWithPath: "lap.flightedit")),
              EditProjectFile.isProjectURL(URL(fileURLWithPath: "lap.flightedit.json")),
              !EditProjectFile.isProjectURL(URL(fileURLWithPath: "lap.json")),
              try EditProjectFile.project(from: projectData).sourcePath == src.path else {
            throw Failure("native edit-project document routing was not deterministic")
        }
        let loadedPlan = try EditProjectFile.decode(projectData, for: projectClip)
        guard loadedPlan == plan else {
            throw Failure("edit project did not round-trip")
        }
        var rejectedWrongProjectSource = false
        do {
            _ = try EditProjectFile.decode(projectData, for: Clip(url: nestedClip))
        } catch let error as EditProjectError {
            guard error == .wrongSource("hdz_001.ts") else {
                throw Failure("project source validation returned an unclear error: \(error)")
            }
            rejectedWrongProjectSource = true
        } catch {
            throw Failure("project source validation returned an unclear error: \(error)")
        }
        let movedProject = EditProject(
            sourcePath: workDir.appendingPathComponent("moved-source.ts").path,
            edit: plan)
        let movedProjectData = try JSONEncoder().encode(movedProject)
        guard rejectedWrongProjectSource,
              try EditProjectFile.decode(movedProjectData, for: projectClip) == plan else {
            throw Failure("project source validation rejected recovery or accepted the wrong recording")
        }
        print("edit project ok")

        // 3e. Every non-destructive edit can be undone and redone.
        let historyClip = Clip.exportVariant(from: favoriteClip, edit: EditPlan())
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

        // A continuous drag or slider movement is one user action, even though
        // SwiftUI can publish hundreds of intermediate values.
        historyClip.clearEditHistory()
        let transactionBaseline = historyClip.edit
        historyClip.beginEditTransaction()
        for step in 1...100 {
            historyClip.edit.inPoint = 2 + Double(step) / 100
        }
        historyClip.endEditTransaction()
        guard historyClip.canUndoEdit, !historyClip.canRedoEdit,
              historyClip.edit.inPoint == 3 else {
            throw Failure("continuous edit transaction did not retain its final value")
        }
        historyClip.undoEdit()
        guard historyClip.edit == transactionBaseline, !historyClip.canUndoEdit,
              historyClip.canRedoEdit else {
            throw Failure("continuous edit transaction created more than one undo step")
        }
        historyClip.redoEdit()
        guard historyClip.edit.inPoint == 3 else {
            throw Failure("continuous edit transaction could not be redone")
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
        let navigationMarkers = [TimelineMarker(time: 8, name: "Third"),
                                 TimelineMarker(time: 2, name: "First"),
                                 TimelineMarker(time: 5, name: "Second"),
                                 TimelineMarker(time: .nan, name: "Invalid")]
        guard MarkerNavigation.previous(in: navigationMarkers, from: 5) == 2,
              MarkerNavigation.next(in: navigationMarkers, from: 5) == 8,
              MarkerNavigation.previous(in: navigationMarkers, from: 2) == nil,
              MarkerNavigation.next(in: navigationMarkers, from: 8) == nil,
              MarkerNavigation.next(in: navigationMarkers, from: 4) == 5 else {
            throw Failure("marker traversal did not respect order or timeline boundaries")
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
              third.lastPathComponent == "flight 3.mp4",
              OutputNamer.safeBaseName(" Final/Lap:\n ") == "Final-Lap" else {
            throw Failure("output-name collision handling is not deterministic")
        }
        print("output naming ok")

        guard SequenceOrder.moved(["A", "B", "C"], from: 2, to: 0) == ["C", "A", "B"],
              SequenceOrder.moved(["A", "B"], from: 0, to: 9) == ["A", "B"] else {
            throw Failure("sequence reordering lost or misplaced a clip")
        }
        print("sequence ordering ok")

        // Export jobs survive relaunches with their exact edit and probe data.
        // A running job recovers as retryable, never as a completed output.
        let exportJobID = UUID()
        var pendingPublishDraft = PublishDraft()
        pendingPublishDraft.title = "Queued highlight"
        pendingPublishDraft.platforms = [.youtube]
        let exportSnapshot = ExportJobSnapshot(
            id: exportJobID,
            clips: [ExportClipSnapshot(url: src, info: info, edit: plan)],
            settings: ExportSettings(), outputURL: first, state: .running, progress: 0.6,
            pendingPublishDraft: pendingPublishDraft)
        let exportJournalURL = workDir.appendingPathComponent("export-queue.json")
        try ExportQueueStore.save([exportSnapshot], to: exportJournalURL)
        let recoveredExports = try ExportQueueStore.load(from: exportJournalURL)
        guard recoveredExports.count == 1,
              recoveredExports[0].id == exportJobID,
              recoveredExports[0].clips[0].edit == plan,
              recoveredExports[0].clips[0].info == info,
              recoveredExports[0].pendingPublishDraft == pendingPublishDraft,
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
        let temporaryFolder = workDir.appendingPathComponent("export-temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder,
                                                withIntermediateDirectories: true)
        let titleTemporary = temporaryFolder.appendingPathComponent(
            "title-\(exportJobID.uuidString)-0.png")
        let passTemporary = temporaryFolder.appendingPathComponent(
            "2pass-\(exportJobID.uuidString)-0.log")
        let unrelatedTemporary = temporaryFolder.appendingPathComponent("keep.log")
        for url in [titleTemporary, passTemporary, unrelatedTemporary] {
            try Data("temporary".utf8).write(to: url)
        }
        ExportTemporaryFiles.cleanup(jobID: exportJobID, in: temporaryFolder)
        guard !FileManager.default.fileExists(atPath: titleTemporary.path),
              !FileManager.default.fileExists(atPath: passTemporary.path),
              FileManager.default.fileExists(atPath: unrelatedTemporary.path) else {
            throw Failure("export temporary cleanup leaked job files or removed unrelated data")
        }
        print("export queue recovery and atomic output promotion ok")

        var diskSettings = ExportSettings()
        diskSettings.preset = .edit
        let diskEstimate = ExportDiskSpace.requiredBytes(
            clips: [ExportClipSnapshot(url: src, info: info, edit: plan)], settings: diskSettings)
        guard diskEstimate > 64_000_000,
              ExportDiskSpace.validationError(required: diskEstimate,
                                              available: diskEstimate - 1)?.contains("Not enough free space") == true,
              ExportDiskSpace.validationError(required: diskEstimate,
                                              available: diskEstimate) == nil else {
            throw Failure("export disk-space preflight did not enforce its staging estimate")
        }
        var socialDiskSettings = ExportSettings()
        socialDiskSettings.preset = .social
        socialDiskSettings.socialTargetMB = 25
        let socialDiskEstimate = ExportDiskSpace.requiredBytes(
            clips: [ExportClipSnapshot(url: src, info: info, edit: plan)],
            settings: socialDiskSettings)
        let socialSequenceDiskEstimate = ExportDiskSpace.requiredBytes(
            clips: [ExportClipSnapshot(url: src, info: info, edit: plan),
                    ExportClipSnapshot(url: src, info: info, edit: plan)],
            settings: socialDiskSettings)
        guard socialDiskEstimate == 92_750_000,
              socialSequenceDiskEstimate == socialDiskEstimate else {
            throw Failure("social disk estimate did not track the target file size")
        }
        print("export disk-space preflight ok")

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
        defer {
            for index in 0..<2 {
                try? FileManager.default.removeItem(
                    at: ExportCommandBuilder.titleAssetURL(jobID: commandsJobID, index: index))
            }
        }
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
                && $0.contains("[vtitle0]") && $0.contains("[vtitle1]")
        }), FileManager.default.fileExists(atPath: ExportCommandBuilder.titleAssetURL(
            jobID: commandsJobID, index: 0).path),
           FileManager.default.fileExists(atPath: ExportCommandBuilder.titleAssetURL(
            jobID: commandsJobID, index: 1).path) else {
            throw Failure("multi-title images, placement or visibility were missing from the export graph")
        }
        guard let titleImage = NSImage(contentsOf: ExportCommandBuilder.titleAssetURL(
            jobID: commandsJobID)), titleImage.size.height > 40, titleImage.size.height < 100 else {
            throw Failure("title asset did not scale to the 720p export canvas")
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

        // 5b. Stitching renders each frozen edit plan before concatenation. A
        // sequence must never silently fall back to the raw source recordings.
        let stitchOut = workDir.appendingPathComponent("stitched.mp4")
        let stitchJobID = UUID()
        defer { ExportTemporaryFiles.cleanup(jobID: stitchJobID) }
        var silentInfo = info
        silentInfo.hasAudio = false
        var silentPlan = plan
        silentPlan.music = nil
        let stitchClips = [ExportClipSnapshot(url: src, info: info, edit: plan),
                           ExportClipSnapshot(url: src, info: silentInfo, edit: silentPlan)]
        let stitchCommands = try StitchCommandBuilder.build(clips: stitchClips,
                                                             settings: settings, output: stitchOut,
                                                             jobID: stitchJobID)
        guard stitchCommands.count == 1 else {
            throw Failure("master stitch unexpectedly required multiple passes")
        }
        let stitchArgs = stitchCommands[0]
        guard stitchArgs.contains(where: { $0.contains("concat=n=2:v=1:a=0") }),
              stitchArgs.contains(where: { $0.contains("[s0_v0]") && $0.contains("[s1_v0]") }),
              stitchArgs.contains(where: { $0.contains("anullsrc=r=48000") }),
              stitchArgs.contains("[aout]"), stitchArgs.contains(stitchOut.path) else {
            throw Failure("stitch command did not build edited, isolated A/V graphs")
        }
        try FFmpeg.run(stitchArgs)
        let stitchInfo = try Probe.probe(stitchOut)
        guard abs(stitchInfo.duration - expected * 2) < 0.5, stitchInfo.hasAudio else {
            throw Failure("stitch export ignored edits or lost audio: \(stitchInfo)")
        }
        print("edited stitch ok: \(String(format: "%.2f", stitchInfo.duration))s")

        // Social sequences retain the selected delivery canvas and two-pass
        // target-size encode instead of silently becoming a Master export.
        var socialStitchSettings = settings
        socialStitchSettings.preset = .social
        socialStitchSettings.socialProfile = .instagramSquare
        socialStitchSettings.socialFraming = .fill
        socialStitchSettings.socialTargetMB = 1
        var shortEdit = EditPlan()
        shortEdit.outPoint = 0.5
        let shortClips = [ExportClipSnapshot(url: src, info: info, edit: shortEdit),
                          ExportClipSnapshot(url: src, info: info, edit: shortEdit)]
        let socialStitchOut = workDir.appendingPathComponent("social-stitched.mp4")
        let socialStitchJobID = UUID()
        defer { ExportTemporaryFiles.cleanup(jobID: socialStitchJobID) }
        let socialStitchCommands = try StitchCommandBuilder.build(
            clips: shortClips, settings: socialStitchSettings,
            output: socialStitchOut, jobID: socialStitchJobID)
        guard socialStitchCommands.count == 2,
              socialStitchCommands[0].joined(separator: " ").contains("-pass 1"),
              socialStitchCommands[1].joined(separator: " ").contains("-pass 2"),
              socialStitchCommands[1].contains(where: {
                  $0.contains("scale=1080:1080") && $0.contains("crop=1080:1080")
              }) else {
            throw Failure("social stitch lost its delivery canvas or two-pass encode")
        }
        for command in socialStitchCommands { try FFmpeg.run(command) }
        let socialStitchInfo = try Probe.probe(socialStitchOut)
        guard socialStitchInfo.width == 1080, socialStitchInfo.height == 1080,
              abs(socialStitchInfo.duration - 1) < 0.25 else {
            throw Failure("social stitch output did not match its delivery preset")
        }
        print("social stitch ok: \(socialStitchInfo.width)×\(socialStitchInfo.height)")

        // Publishing journals preserve completed destinations and turn a
        // process-interrupted upload into an explicit retryable failure.
        var publishSettings = ExportSettings()
        publishSettings.preset = .social
        var recoveryDraft = PublishDraft()
        recoveryDraft.title = "Recovery test"
        recoveryDraft.platforms = [.youtube, .tiktok]
        let publishSnapshot = PublishJobSnapshot(
            id: UUID(), exportURL: stitchOut, settings: publishSettings, draft: recoveryDraft,
            states: [.youtube: .uploaded, .tiktok: .uploading],
            progress: [.youtube: 1, .tiktok: 0.4], sourceExportID: exportJobID)
        let journalURL = workDir.appendingPathComponent("publish-queue.json")
        try PublishQueueStore.save([publishSnapshot], to: journalURL)
        let recoveredPublish = try PublishQueueStore.load(from: journalURL)
        guard recoveredPublish.count == 1,
              recoveredPublish[0].id == publishSnapshot.id,
              recoveredPublish[0].sourceExportID == exportJobID,
              recoveredPublish[0].states[.youtube] == .uploaded,
              recoveredPublish[0].states[.tiktok] == .failed("Upload was interrupted. Retry when connected."),
              recoveredPublish[0].progress[.tiktok] == 0.4 else {
            throw Failure("publishing queue journal did not recover platform state")
        }
        guard PublishState.queued.canStart, PublishState.waitingForConnection.canStart,
              PublishState.cancelled.canStart, PublishState.failed("offline").canStart,
              !PublishState.uploading.canStart, !PublishState.uploaded.canStart else {
            throw Failure("publishing retry eligibility did not preserve terminal destinations")
        }

        // A cancelled provider can complete after its replacement retry. Only
        // the current attempt is allowed to mutate queue state.
        var attempts = PublishAttemptRegistry<String>()
        let cancelledAttempt = attempts.begin("youtube")
        attempts.invalidate("youtube")
        let retryAttempt = attempts.begin("youtube")
        guard !attempts.isCurrent(cancelledAttempt, for: "youtube"),
              attempts.isCurrent(retryAttempt, for: "youtube") else {
            throw Failure("publishing attempt identity accepted a stale completion")
        }
        attempts.finish(cancelledAttempt, for: "youtube")
        guard attempts.isCurrent(retryAttempt, for: "youtube") else {
            throw Failure("stale publishing cleanup invalidated the active retry")
        }
        attempts.finish(retryAttempt, for: "youtube")
        guard !attempts.isCurrent(retryAttempt, for: "youtube") else {
            throw Failure("completed publishing attempt remained active")
        }

        let racingProvider = RacingPublishProvider()
        let racingQueueURL = workDir.appendingPathComponent("racing-publish-queue.json")
        try? FileManager.default.removeItem(at: racingQueueURL)
        let racingQueue = PublishQueue(
            persistenceURL: racingQueueURL,
            providers: [.youtube: racingProvider as any PublishingProvider])
        var racingDraft = PublishDraft()
        racingDraft.title = "Attempt identity"
        racingDraft.platforms = [.youtube]
        let racingJob = PublishJob(exportURL: stitchOut, settings: settings,
                                   draft: racingDraft)
        racingQueue.jobs.append(racingJob)
        racingQueue.start(racingJob)
        guard waitUntil({ racingJob.states[.youtube] == .uploading }) else {
            throw Failure("publishing race test never started its first upload")
        }
        racingQueue.cancel(racingJob, platform: .youtube)
        racingQueue.retry(racingJob, platform: .youtube)
        guard waitUntil({ racingJob.states[.youtube] == .uploaded }) else {
            throw Failure("publishing retry did not complete")
        }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        guard racingJob.states[.youtube] == .uploaded,
              racingJob.progress[.youtube] == 1 else {
            throw Failure("cancelled publishing attempt overwrote its completed retry")
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
        let thumbnailURL = waveformOut
        savedDraft.thumbnailURL = thumbnailURL
        PublishDraftStore.save(savedDraft, defaults: publishDefaults, key: draftKey)
        guard PublishDraftStore.load(defaults: publishDefaults, key: draftKey) == savedDraft else {
            throw Failure("publish composer draft did not survive persistence")
        }
        publishDefaults.set(Data("invalid".utf8), forKey: draftKey)
        guard PublishDraftStore.load(defaults: publishDefaults, key: draftKey) == PublishDraft() else {
            throw Failure("corrupt publish composer draft did not recover safely")
        }
        print("publish composer draft recovery ok")

        let thumbnailCommand = PublishThumbnailBuilder.command(
            source: out, time: 2.5,
            output: workDir.appendingPathComponent("generated-thumbnail.jpg"))
        guard thumbnailCommand.contains("2.500"),
              thumbnailCommand.contains(where: { $0.contains("scale=1280:720") }),
              thumbnailCommand.last?.hasSuffix("generated-thumbnail.jpg") == true else {
            throw Failure("publish thumbnail command did not build a 1280×720 frame")
        }
        try FFmpeg.run(thumbnailCommand)
        guard let generatedThumbnail = thumbnailCommand.last.map({ URL(fileURLWithPath: $0) }),
              NSImage(contentsOf: generatedThumbnail) != nil else {
            throw Failure("publish thumbnail generation did not create a readable image")
        }

        // 6. Social preset: two passes, lands near the target size.
        var socialSettings = ExportSettings()
        socialSettings.preset = .social
        socialSettings.socialTargetMB = 4
        let socialOut = workDir.appendingPathComponent("social.mp4")
        let socialJobID = UUID()
        defer { ExportTemporaryFiles.cleanup(jobID: socialJobID) }
        let socialCommands = ExportCommandBuilder.build(
            plan: plan, settings: socialSettings, info: info,
            source: src, output: socialOut, jobID: socialJobID)
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
        let invalidTikTokMedia = ClipInfo(duration: 601, width: 1080, height: 1920, fps: 120,
                                          videoCodec: "h264", hasAudio: true,
                                          colorRange: "tv", fileSize: 4_000_000_001)
        let tiktokLimits = PlatformMediaValidator.validate(invalidTikTokMedia, for: .tiktok)
        guard tiktokLimits.filter({ $0.severity == .error }).count == 3,
              tiktokLimits.contains(where: { $0.message.contains("10 minutes") }),
              tiktokLimits.contains(where: { $0.message.contains("4 GB") }),
              tiktokLimits.contains(where: { $0.message.contains("23 and 60 FPS") }) else {
            throw Failure("TikTok API media constraints did not reject an invalid export")
        }
        var longTikTokMedia = invalidTikTokMedia
        longTikTokMedia.duration = 181
        longTikTokMedia.fps = 60
        longTikTokMedia.fileSize = 10_000_000
        guard PlatformMediaValidator.validate(longTikTokMedia, for: .tiktok)
            .contains(where: { $0.severity == .warning && $0.message.contains("over 3 minutes") }) else {
            throw Failure("TikTok account-dependent duration warning was missing")
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
        var invalidYouTubeDraft = PublishDraft()
        invalidYouTubeDraft.title = String(repeating: "x", count: 101)
        invalidYouTubeDraft.caption = String(repeating: "é", count: 2_501)
        invalidYouTubeDraft.platforms = [.youtube]
        let oversizedThumbnail = workDir.appendingPathComponent("oversized-thumbnail.jpg")
        try Data(repeating: 0, count: 2_000_001).write(to: oversizedThumbnail)
        invalidYouTubeDraft.thumbnailURL = oversizedThumbnail
        let youtubeMetadataIssues = PublishValidator.validate(
            draft: invalidYouTubeDraft, settings: socialSettings)
        guard youtubeMetadataIssues.contains(where: { $0.message.contains("100 characters") }),
              youtubeMetadataIssues.contains(where: { $0.message.contains("5,000 bytes") }),
              youtubeMetadataIssues.contains(where: { $0.message.contains("2 MB") }),
              youtubeMetadataIssues.contains(where: { $0.message.contains("not a readable image") }) else {
            throw Failure("YouTube metadata or thumbnail constraints were not enforced")
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

    @MainActor private static func waitUntil(timeout: TimeInterval = 2,
                                             _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.current.run(mode: .default,
                                    before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}
