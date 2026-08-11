import Foundation

/// A cut range removed from the middle of a clip.
struct CutRange: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
}

/// A zone played at a different speed, with eased ramps at both edges.
struct SpeedZone: Identifiable, Equatable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var speed: Double        // 2.0 = twice as fast, 0.5 = half speed
    var rampDuration: Double = 0.6
}

struct MusicTrack: Equatable, Codable {
    var url: URL
    var volume: Double = 0.8         // 0…1
    var fadeIn: Double = 1.0
    var fadeOut: Double = 2.0
    var muteOriginal: Bool = true
}

/// A named, non-destructive bookmark for a moment worth returning to.
struct TimelineMarker: Identifiable, Equatable, Codable {
    var id = UUID()
    var time: Double
    var name: String
}

enum TimelineMath {
    /// Quantize pointer-driven edits to real source-frame boundaries. Unknown or
    /// malformed frame rates fall back to millisecond precision.
    static func snappedTime(_ time: Double, fps: Double, duration: Double) -> Double {
        guard time.isFinite, duration.isFinite, duration > 0 else { return 0 }
        let clamped = min(max(time, 0), duration)
        guard fps.isFinite, fps > 0 else { return (clamped * 1_000).rounded() / 1_000 }
        return min(max((clamped * fps).rounded() / fps, 0), duration)
    }
}

/// Everything the user has done to one clip.
struct EditPlan: Equatable, Codable {
    var inPoint: Double = 0
    var outPoint: Double? = nil      // nil = clip end
    var cuts: [CutRange] = []
    var speedZones: [SpeedZone] = []
    var music: MusicTrack? = nil
    var markers: [TimelineMarker] = []

    var isDefault: Bool {
        inPoint == 0 && outPoint == nil && cuts.isEmpty && speedZones.isEmpty && music == nil
    }

    /// Trim around a moment without exceeding the source. Near either edge the
    /// window slides to preserve the requested length where possible.
    mutating func setHighlight(around time: Double, length: Double, duration: Double) {
        guard duration.isFinite, duration > 0, length.isFinite, length > 0 else { return }
        let window = min(length, duration)
        let center = min(max(time.isFinite ? time : 0, 0), duration)
        var start = center - window / 2
        var end = center + window / 2
        if start < 0 {
            end -= start
            start = 0
        }
        if end > duration {
            start -= end - duration
            end = duration
        }
        inPoint = max(0, start)
        outPoint = min(duration, end)
    }

    /// Returns a safe, deterministic version of an edit before it is rendered.
    /// Imported or manually edited projects can otherwise contain negative times,
    /// inverted ranges, or overlapping cuts that make ffmpeg reject the graph.
    func sanitized(duration: Double) -> EditPlan {
        guard duration.isFinite, duration > 0 else { return EditPlan() }
        var result = self
        result.inPoint = min(max(inPoint.isFinite ? inPoint : 0, 0), duration)
        let requestedOut = outPoint ?? duration
        let safeOut = requestedOut.isFinite ? requestedOut : duration
        result.outPoint = min(max(safeOut, result.inPoint), duration)

        let rangeEnd = result.outPoint ?? duration
        let clampedCuts = cuts.compactMap { cut -> CutRange? in
            let start = min(max(cut.start, result.inPoint), rangeEnd)
            let end = min(max(cut.end, result.inPoint), rangeEnd)
            return end - start > 0.05 ? CutRange(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var mergedCuts: [CutRange] = []
        for cut in clampedCuts {
            if var last = mergedCuts.last, cut.start <= last.end + 0.001 {
                last.end = max(last.end, cut.end)
                mergedCuts[mergedCuts.count - 1] = last
            } else {
                mergedCuts.append(cut)
            }
        }
        result.cuts = mergedCuts

        // Zones remain ordered as entered: for overlapping legacy zones the first
        // one continues to win, matching the previous renderer's behaviour.
        result.speedZones = speedZones.compactMap { zone -> SpeedZone? in
            let start = min(max(zone.start, result.inPoint), rangeEnd)
            let end = min(max(zone.end, result.inPoint), rangeEnd)
            guard end - start > 0.05 else { return nil }
            var cleaned = zone
            cleaned.start = start
            cleaned.end = end
            cleaned.speed = min(max(zone.speed.isFinite ? zone.speed : 1, 0.25), 4)
            cleaned.rampDuration = min(max(zone.rampDuration.isFinite ? zone.rampDuration : 0, 0), (end - start) / 2)
            return cleaned
        }
        result.markers = markers.compactMap { marker in
            guard marker.time.isFinite else { return nil }
            var cleaned = marker
            cleaned.time = min(max(marker.time, result.inPoint), rangeEnd)
            cleaned.name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned
        }.sorted { $0.time < $1.time }
        if let music = music, !music.url.path.isEmpty {
            var cleaned = music
            cleaned.volume = min(max(music.volume.isFinite ? music.volume : 0.8, 0), 1)
            cleaned.fadeIn = max(music.fadeIn.isFinite ? music.fadeIn : 0, 0)
            cleaned.fadeOut = max(music.fadeOut.isFinite ? music.fadeOut : 0, 0)
            result.music = cleaned
        } else {
            result.music = nil
        }
        return result
    }

    /// A human-readable reason an edit cannot produce any video.
    func validationError(duration: Double) -> String? {
        guard duration.isFinite, duration > 0 else { return "The clip has no usable duration." }
        let safe = sanitized(duration: duration)
        guard safe.effectiveOut(duration: duration) - safe.inPoint > 0.05 else {
            return "The trim out point must be after the trim in point."
        }
        guard !safe.resolvedSegments(duration: duration).isEmpty else {
            return "Cuts remove the entire trimmed clip."
        }
        return nil
    }

    func effectiveOut(duration: Double) -> Double { min(outPoint ?? duration, duration) }

    /// Source-time segments that survive the cuts, in order.
    func keptRanges(duration: Double) -> [(Double, Double)] {
        let safe = sanitized(duration: duration)
        let out = safe.effectiveOut(duration: duration)
        guard out > safe.inPoint else { return [] }
        var kept: [(Double, Double)] = [(safe.inPoint, out)]
        for cut in safe.cuts {
            var next: [(Double, Double)] = []
            for (a, b) in kept {
                let cs = max(cut.start, a), ce = min(cut.end, b)
                if cs >= ce { next.append((a, b)); continue }
                if cs > a { next.append((a, cs)) }
                if ce < b { next.append((ce, b)) }
            }
            kept = next
        }
        return kept.filter { $1 - $0 > 0.05 }
    }

    /// Speed at a given source time, with cosine-eased ramps inside zone edges.
    func speed(at t: Double) -> Double {
        for z in speedZones where t >= z.start && t <= z.end {
            let ramp = min(z.rampDuration, (z.end - z.start) / 2)
            if ramp > 0.01 {
                if t < z.start + ramp {
                    let p = (t - z.start) / ramp
                    return 1 + (z.speed - 1) * easeInOut(p)
                }
                if t > z.end - ramp {
                    let p = (z.end - t) / ramp
                    return 1 + (z.speed - 1) * easeInOut(p)
                }
            }
            return z.speed
        }
        return 1.0
    }

    private func easeInOut(_ p: Double) -> Double {
        (1 - cos(.pi * min(max(p, 0), 1))) / 2
    }

    /// Atomic (srcStart, srcEnd, speed) segments: constant-speed stretches plus
    /// stepped sub-segments through each ramp. ffmpeg has no continuous speed
    /// ramp, so ramps become short steps — at 8+ steps over half a second the
    /// result reads as smooth.
    func resolvedSegments(duration: Double, rampSteps: Int = 10) -> [(start: Double, end: Double, speed: Double)] {
        let safe = sanitized(duration: duration)
        var boundaries: Set<Double> = []
        for (a, b) in safe.keptRanges(duration: duration) { boundaries.insert(a); boundaries.insert(b) }
        for z in safe.speedZones {
            let ramp = min(z.rampDuration, (z.end - z.start) / 2)
            boundaries.insert(z.start); boundaries.insert(z.end)
            if ramp > 0.01 {
                for i in 1...rampSteps {
                    boundaries.insert(z.start + ramp * Double(i) / Double(rampSteps))
                    boundaries.insert(z.end - ramp * Double(i) / Double(rampSteps))
                }
            }
        }
        var segments: [(Double, Double, Double)] = []
        for (a, b) in safe.keptRanges(duration: duration) {
            let cutPoints = ([a, b] + boundaries.filter { $0 > a && $0 < b }).sorted()
            for i in 0..<(cutPoints.count - 1) {
                let s = cutPoints[i], e = cutPoints[i + 1]
                guard e - s > 0.005 else { continue }
                segments.append((s, e, safe.speed(at: (s + e) / 2)))
            }
        }
        // Merge neighbours with (near) identical speed to keep the graph small.
        var merged: [(start: Double, end: Double, speed: Double)] = []
        for seg in segments {
            if var last = merged.last, abs(last.speed - seg.2) < 0.001, abs(last.end - seg.0) < 0.001 {
                last.end = seg.1
                merged[merged.count - 1] = last
            } else {
                merged.append((seg.0, seg.1, seg.2))
            }
        }
        return merged
    }

    /// Length of the finished video after cuts and speed changes.
    func outputDuration(duration: Double) -> Double {
        resolvedSegments(duration: duration).reduce(0) { $0 + ($1.end - $1.start) / $1.speed }
    }

    /// Where a source-time moment lands in the edited output.
    /// A time inside a cut maps to the start of the next kept piece.
    func outputTime(forSource t: Double, duration: Double) -> Double {
        var acc = 0.0
        for seg in resolvedSegments(duration: duration) {
            if t < seg.start { return acc }
            if t <= seg.end { return acc + (t - seg.start) / seg.speed }
            acc += (seg.end - seg.start) / seg.speed
        }
        return acc
    }

    /// The source-time moment playing at a given output time.
    func sourceTime(forOutput o: Double, duration: Double) -> Double {
        var acc = 0.0
        for seg in resolvedSegments(duration: duration) {
            let d = (seg.end - seg.start) / seg.speed
            if o <= acc + d { return seg.start + (o - acc) * seg.speed }
            acc += d
        }
        return effectiveOut(duration: duration)
    }
}

// MARK: - Filtergraph construction

enum FilterGraphBuilder {
    /// atempo only accepts 0.5–100; chain filters for slower speeds.
    static func atempoChain(_ speed: Double) -> String {
        var s = speed
        var parts: [String] = []
        while s < 0.5 {
            parts.append("atempo=0.5")
            s /= 0.5
        }
        parts.append(String(format: "atempo=%.5f", s))
        return parts.joined(separator: ",")
    }

    struct Graph {
        var filterComplex: String
        var videoLabel: String
        var audioLabel: String?      // nil = no audio track in the output
        var needsMusicInput: Bool
    }

    /// Build the -filter_complex for one clip's edit plan.
    /// Input 0 is the clip; input 1 (optional) is the music file.
    static func build(plan: EditPlan, duration: Double, sourceHasAudio: Bool,
                      fixColorRange: Bool, outputVideoFilter: String? = nil) -> Graph {
        let plan = plan.sanitized(duration: duration)
        let segs = plan.resolvedSegments(duration: duration)
        precondition(!segs.isEmpty, "empty edit")
        let outDur = plan.outputDuration(duration: duration)

        var lines: [String] = []
        var vLabels: [String] = []
        var aLabels: [String] = []
        let wantOriginalAudio = sourceHasAudio && !(plan.music?.muteOriginal ?? false)

        for (i, seg) in segs.enumerated() {
            let v = "v\(i)"
            lines.append(String(format: "[0:v]trim=start=%.4f:end=%.4f,setpts=(PTS-STARTPTS)/%.5f[\(v)]",
                                seg.start, seg.end, seg.speed))
            vLabels.append("[\(v)]")
            if wantOriginalAudio {
                let a = "a\(i)"
                lines.append(String(format: "[0:a]atrim=start=%.4f:end=%.4f,asetpts=PTS-STARTPTS,%@[\(a)]",
                                    seg.start, seg.end, atempoChain(seg.speed)))
                aLabels.append("[\(a)]")
            }
        }

        var vOut = "vcat"
        if segs.count == 1 {
            vOut = String(vLabels[0].dropFirst().dropLast())
        } else {
            lines.append("\(vLabels.joined())concat=n=\(segs.count):v=1:a=0[vcat]")
        }
        if fixColorRange {
            // The one provably wrong thing about HDZero recordings: full-range video
            // most players treat as limited. Fix the range, touch nothing else.
            lines.append("[\(vOut)]scale=in_range=pc:out_range=tv[vfix]")
            vOut = "vfix"
        }
        if let outputVideoFilter {
            lines.append("[\(vOut)]\(outputVideoFilter)[vdelivery]")
            vOut = "vdelivery"
        }

        var aOut: String? = nil
        if wantOriginalAudio {
            if aLabels.count == 1 {
                aOut = String(aLabels[0].dropFirst().dropLast())
            } else {
                lines.append("\(aLabels.joined())concat=n=\(aLabels.count):v=0:a=1[acat]")
                aOut = "acat"
            }
        }

        var needsMusic = false
        if let music = plan.music {
            needsMusic = true
            let fadeOutStart = max(0, outDur - music.fadeOut)
            lines.append(String(
                format: "[1:a]atrim=0:%.3f,asetpts=PTS-STARTPTS,volume=%.3f,afade=t=in:d=%.2f,afade=t=out:st=%.3f:d=%.2f[music]",
                outDur, music.volume, music.fadeIn, fadeOutStart, music.fadeOut))
            if let existing = aOut {
                lines.append("[\(existing)][music]amix=inputs=2:duration=first:normalize=0[amix]")
                aOut = "amix"
            } else {
                aOut = "music"
            }
        }

        return Graph(filterComplex: lines.joined(separator: ";"),
                     videoLabel: vOut, audioLabel: aOut, needsMusicInput: needsMusic)
    }
}
