import Foundation

/// A cut range removed from the middle of a clip.
struct CutRange: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
}

/// A zone played at a different speed, with eased ramps at both edges.
struct SpeedZone: Identifiable, Equatable {
    let id = UUID()
    var start: Double
    var end: Double
    var speed: Double        // 2.0 = twice as fast, 0.5 = half speed
    var rampDuration: Double = 0.6
}

struct MusicTrack: Equatable {
    var url: URL
    var volume: Double = 0.8         // 0…1
    var fadeIn: Double = 1.0
    var fadeOut: Double = 2.0
    var muteOriginal: Bool = true
}

/// Everything the user has done to one clip.
struct EditPlan: Equatable {
    var inPoint: Double = 0
    var outPoint: Double? = nil      // nil = clip end
    var cuts: [CutRange] = []
    var speedZones: [SpeedZone] = []
    var music: MusicTrack? = nil

    var isDefault: Bool {
        inPoint == 0 && outPoint == nil && cuts.isEmpty && speedZones.isEmpty && music == nil
    }

    func effectiveOut(duration: Double) -> Double { min(outPoint ?? duration, duration) }

    /// Source-time segments that survive the cuts, in order.
    func keptRanges(duration: Double) -> [(Double, Double)] {
        let out = effectiveOut(duration: duration)
        guard out > inPoint else { return [] }
        var kept: [(Double, Double)] = [(inPoint, out)]
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
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
        var boundaries: Set<Double> = []
        for (a, b) in keptRanges(duration: duration) { boundaries.insert(a); boundaries.insert(b) }
        for z in speedZones {
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
        for (a, b) in keptRanges(duration: duration) {
            let cutPoints = ([a, b] + boundaries.filter { $0 > a && $0 < b }).sorted()
            for i in 0..<(cutPoints.count - 1) {
                let s = cutPoints[i], e = cutPoints[i + 1]
                guard e - s > 0.005 else { continue }
                segments.append((s, e, speed(at: (s + e) / 2)))
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
                      fixColorRange: Bool) -> Graph {
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
