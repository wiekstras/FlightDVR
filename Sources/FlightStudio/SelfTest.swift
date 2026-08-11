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
        guard scanned.contains(nestedClip) else {
            throw Failure("recursive scan missed \(nestedClip.path)")
        }
        guard !ClipStore.findVideoFiles(in: workDir, onlyTS: true, stopAtFirst: true).isEmpty else {
            throw Failure("stop-at-first .ts search found nothing")
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

        // 3. An edit that uses everything: trim 1–9, cut out 3–4, 2× ramp over 5–8, music under it.
        var plan = EditPlan()
        plan.inPoint = 1
        plan.outPoint = 9
        plan.cuts = [CutRange(start: 3, end: 4)]
        plan.speedZones = [SpeedZone(start: 5, end: 8, speed: 2.0)]
        plan.music = MusicTrack(url: music, volume: 0.5, fadeIn: 0.5, fadeOut: 1.0, muteOriginal: false)

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
        print("date parsing ok")

        // 3c. Invalid timeline data is normalised before it can reach ffmpeg.
        var messy = EditPlan(inPoint: -2, outPoint: 99,
                             cuts: [CutRange(start: 2, end: 4), CutRange(start: 3, end: 6),
                                    CutRange(start: 8, end: 7)],
                             speedZones: [SpeedZone(start: -1, end: 2, speed: 99, rampDuration: 9)])
        messy = messy.sanitized(duration: info.duration)
        guard messy.inPoint == 0, messy.effectiveOut(duration: info.duration) == info.duration,
              messy.cuts.count == 1, messy.cuts[0].start == 2, messy.cuts[0].end == 6,
              messy.speedZones[0].speed == 4, messy.speedZones[0].rampDuration <= 1 else {
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

        // 3d. Queued and on-disk name collisions receive predictable suffixes.
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

        // 3e. Source↔output time mapping must round-trip through cuts and ramps.
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
        let commands = ExportCommandBuilder.build(
            plan: plan, settings: settings, info: info,
            source: src, output: out, jobID: UUID())
        guard commands.count == 1 else { throw Failure("master preset should be one pass") }
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
        nonisolated(unsafe) var compError: (any Error)?
        let compPlan = plan
        let compDuration = info.duration
        Task.detached {
            do {
                let (comp, mix) = try await PlayerController.buildEditComposition(
                    plan: compPlan, sourceDuration: compDuration, previewURL: previewMP4)
                compSeconds = comp.duration.seconds
                if mix == nil { compError = Failure("audio mix missing despite music track") }
            } catch {
                compError = error
            }
            compSem.signal()
        }
        guard compSem.wait(timeout: .now() + 30) == .success else {
            throw Failure("composition build timed out")
        }
        if let compError { throw compError }
        guard abs(compSeconds - expected) < 0.35 else {
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

        // 6. Social preset: two passes, lands near the target size.
        var socialSettings = ExportSettings()
        socialSettings.preset = .social
        socialSettings.socialTargetMB = 4
        let socialOut = workDir.appendingPathComponent("social.mp4")
        let socialCommands = ExportCommandBuilder.build(
            plan: plan, settings: socialSettings, info: info,
            source: src, output: socialOut, jobID: UUID())
        guard socialCommands.count == 2 else { throw Failure("social preset should be two passes") }
        for c in socialCommands { try FFmpeg.run(c) }
        let socialSize = (try FileManager.default.attributesOfItem(atPath: socialOut.path)[.size]) as? Int64 ?? 0
        let socialMB = Double(socialSize) / 1_000_000
        guard socialMB > 2.0 && socialMB < 6.0 else {
            throw Failure("social export \(socialMB) MB is far from the 4 MB target")
        }
        print("social ok: \(String(format: "%.2f", socialMB)) MB against a 4 MB target")
    }
}
