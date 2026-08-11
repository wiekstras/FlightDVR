import SwiftUI
import Combine
import CryptoKit

final class Clip: ObservableObject, Identifiable, Hashable {
    let id: URL
    let url: URL
    @Published var info: ClipInfo?
    @Published var thumbnail: NSImage?
    @Published var ticked = false
    @Published var previewURL: URL?      // remuxed .mp4 the native player can open
    @Published var edit = EditPlan()
    @Published var relativeName: String = ""   // path relative to the scanned folder

    let fileDate: Date           // the filesystem's story
    let parsedDate: Date?        // a date found in the filename, which we trust more

    init(url: URL) {
        self.url = url
        self.id = url
        self.relativeName = url.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.fileDate = (attrs?[.creationDate] ?? attrs?[.modificationDate]) as? Date ?? .distantPast
        self.parsedDate = Clip.parseDate(from: url.lastPathComponent)
    }

    var name: String { url.lastPathComponent }
    /// Best guess at when this was flown: a date embedded in the filename wins,
    /// otherwise the file's own date.
    var flightDate: Date { parsedDate ?? fileDate }
    var flightDay: Date { Calendar.current.startOfDay(for: flightDate) }

    /// Finds yyyyMMdd / yyyy-MM-dd / yyyy_MM_dd in a filename, with an optional
    /// HHmmss / HH-mm-ss after it (e.g. hdz_20250712_143005.ts).
    static func parseDate(from name: String) -> Date? {
        let pattern = #"(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?:[-_ T.]?(\d{2})[-_.:]?(\d{2})[-_.:]?(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
        else { return nil }
        func group(_ i: Int) -> Int? {
            guard m.range(at: i).location != NSNotFound,
                  let r = Range(m.range(at: i), in: name) else { return nil }
            return Int(name[r])
        }
        guard let y = group(1), let mo = group(2), let d = group(3),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var comps = DateComponents(year: y, month: mo, day: d)
        if let h = group(4), let mi = group(5), let s = group(6),
           (0...23).contains(h), (0...59).contains(mi), (0...59).contains(s) {
            comps.hour = h; comps.minute = mi; comps.second = s
        }
        guard let date = Calendar.current.date(from: comps) else { return nil }
        // DateComponents normalises impossible dates (e.g. February 31) instead
        // of rejecting them, which would silently put a clip in the wrong day.
        let verified = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard verified.year == y, verified.month == mo, verified.day == d,
              (comps.hour == nil || (verified.hour == comps.hour && verified.minute == comps.minute && verified.second == comps.second))
        else { return nil }
        return date
    }

    static func == (lhs: Clip, rhs: Clip) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case date = "Date"
    case name = "Name"
    case duration = "Length"
    case size = "Size"
    var id: String { rawValue }
}

@MainActor
final class ClipStore: ObservableObject {
    private static let lastFolderDefaultsKey = "lastSourceFolder"
    @Published var sourceFolder: URL?
    @Published var clips: [Clip] = []
    @Published var selectedClip: Clip?
    @Published var isScanning = false
    @Published var statusMessage = ""
    @Published var ffmpegMissing = !FFmpeg.isAvailable
    @Published var sortOrder: SortOrder = .date
    @Published var reverseSort = false
    @Published var searchQuery = ""
    @Published var previewCacheBytes: Int64 = 0

    /// Clips in the chosen order. Date order = newest flight first.
    var sortedClips: [Clip] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchable = query.isEmpty ? clips : clips.filter {
            $0.relativeName.localizedCaseInsensitiveContains(query)
        }
        let ordered: [Clip]
        switch sortOrder {
        case .date:
            ordered = searchable.sorted { ($0.flightDate, $0.name) > ($1.flightDate, $1.name) }
        case .name:
            ordered = searchable.sorted { $0.relativeName.localizedStandardCompare($1.relativeName) == .orderedAscending }
        case .duration:
            ordered = searchable.sorted { ($0.info?.duration ?? 0) > ($1.info?.duration ?? 0) }
        case .size:
            ordered = searchable.sorted { ($0.info?.fileSize ?? 0) > ($1.info?.fileSize ?? 0) }
        }
        return reverseSort ? Array(ordered.reversed()) : ordered
    }

    /// Clips grouped into one section per flying day (date order only).
    var daySections: [(day: Date, clips: [Clip])] {
        let grouped = Dictionary(grouping: sortedClips, by: \.flightDay)
        return grouped.keys.sorted { reverseSort ? $0 < $1 : $0 > $1 }
            .map { ($0, grouped[$0]!) }
    }

    nonisolated static let cacheRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlightStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    nonisolated private static func cacheKey(for url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 ?? 0
        let digest = Insecure.MD5.hash(data: Data("\(url.path)|\(size)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Scanning

    nonisolated static let videoExtensions = ["ts", "mp4", "mov", "mkv"]

    /// All video files under a folder, nested up to `maxDepth` levels deep.
    nonisolated static func findVideoFiles(in folder: URL, maxDepth: Int = 5,
                                           onlyTS: Bool = false, stopAtFirst: Bool = false) -> [URL] {
        let exts = onlyTS ? ["ts"] : videoExtensions
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var found: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard exts.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
            if stopAtFirst { break }
        }
        return found.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    func findSDCard() {
        statusMessage = "Looking for a card…"
        Task.detached { [weak self] in
            let volumes = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "/Volumes"),
                includingPropertiesForKeys: nil)) ?? []
            let hit = volumes.first { vol in
                // /Volumes contains a link to the boot volume — never trawl that.
                let resolved = vol.resolvingSymlinksInPath().path
                if resolved == "/" || resolved.hasPrefix("/System") { return false }
                // Recordings can be nested (movies/, DCIM/…, or copied subfolders),
                // so search the whole card, not one fixed path.
                if !Self.findVideoFiles(in: vol, onlyTS: true, stopAtFirst: true).isEmpty {
                    return true
                }
                return false
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let hit {
                    self.sourceFolder = hit
                    self.rescan()
                } else {
                    self.statusMessage = "No volume with .ts recordings found under /Volumes."
                }
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            sourceFolder = url
            rescan()
        }
    }

    func rescan() {
        guard let folder = sourceFolder else { return }
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderDefaultsKey)
        isScanning = true
        statusMessage = "Scanning \(folder.path)…"
        Task.detached { [weak self] in
            let files = Self.findVideoFiles(in: folder)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let existing = Dictionary(uniqueKeysWithValues: self.clips.map { ($0.url, $0) })
                self.clips = files.map { url in
                    let clip = existing[url] ?? Clip(url: url)
                    clip.relativeName = url.path.hasPrefix(folder.path + "/")
                        ? String(url.path.dropFirst(folder.path.count + 1))
                        : url.lastPathComponent
                    return clip
                }
                self.isScanning = false
                self.statusMessage = "\(files.count) clip\(files.count == 1 ? "" : "s")"
                if self.selectedClip == nil { self.selectedClip = self.clips.first }
                self.loadMetadata()
            }
        }
    }

    /// Reopen the last successfully chosen source when it is still mounted.
    func restoreLastSourceFolder() {
        guard sourceFolder == nil,
              let path = UserDefaults.standard.string(forKey: Self.lastFolderDefaultsKey),
              FileManager.default.fileExists(atPath: path) else { return }
        sourceFolder = URL(fileURLWithPath: path, isDirectory: true)
        rescan()
    }

    /// Probe + thumbnail every clip, at most four at a time — hundreds of
    /// concurrent ffmpeg processes fighting over one USB card reader is slower
    /// than a small pool, not faster.
    private func loadMetadata() {
        let pending = clips.filter { $0.info == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                func addNext(_ group: inout TaskGroup<Void>) -> Bool {
                    guard let clip = iterator.next() else { return false }
                    group.addTask {
                        let info = try? Probe.probe(clip.url)
                        let thumb = Self.extractThumbnail(for: clip.url, duration: info?.duration ?? 0)
                        await MainActor.run {
                            clip.info = info
                            clip.thumbnail = thumb
                        }
                    }
                    return true
                }
                for _ in 0..<4 where addNext(&group) {}
                while await group.next() != nil {
                    _ = addNext(&group)
                }
            }
        }
    }

    // MARK: File management

    /// Move clips to the Trash (recoverable — the app never hard-deletes).
    /// Returns false if the user cancelled.
    @discardableResult
    func moveToTrash(_ toDelete: [Clip]) -> Bool {
        guard !toDelete.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = toDelete.count == 1
            ? "Move “\(toDelete[0].name)” to the Trash?"
            : "Move \(toDelete.count) clips to the Trash?"
        let total = toDelete.compactMap { $0.info?.fileSize }.reduce(0, +)
        alert.informativeText = "They can be recovered from the Trash."
            + (total > 0 ? " Frees \(byteString(total)) on the card." : "")
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        var failed: [String] = []
        for clip in toDelete {
            do {
                try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
                if let preview = clip.previewURL, preview != clip.url {
                    try? FileManager.default.removeItem(at: preview)
                }
                clips.removeAll { $0.id == clip.id }
                if selectedClip == clip { selectedClip = nil }
            } catch {
                failed.append(clip.name)
            }
        }
        statusMessage = failed.isEmpty
            ? "Moved \(toDelete.count - failed.count) clip\(toDelete.count == 1 ? "" : "s") to the Trash."
            : "Could not trash: \(failed.joined(separator: ", "))"
        refreshCacheSize()
        return true
    }

    // MARK: Preview cache management

    nonisolated static let previewCacheCap: Int64 = 20_000_000_000   // 20 GB

    func refreshCacheSize() {
        Task.detached {
            let bytes = Self.previewFiles().reduce(Int64(0)) { sum, url in
                sum + (((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0)
            }
            await MainActor.run { [weak self] in self?.previewCacheBytes = bytes }
        }
    }

    func clearPreviewCache() {
        for url in Self.previewFiles() {
            try? FileManager.default.removeItem(at: url)
        }
        for clip in clips where clip.url.pathExtension.lowercased() == "ts" {
            clip.previewURL = nil
        }
        refreshCacheSize()
        statusMessage = "Preview cache cleared."
    }

    nonisolated private static func previewFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("preview-") }
    }

    /// Drop the oldest previews until the cache fits the cap, sparing `keep`.
    nonisolated static func enforceCacheCap(keeping keep: URL?) {
        var entries: [(url: URL, size: Int64, date: Date)] = previewFiles().compactMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return (url, attrs[.size] as? Int64 ?? 0, attrs[.modificationDate] as? Date ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > previewCacheCap {
            if entry.url == keep { continue }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Thumbnails

    nonisolated private static func extractThumbnail(for url: URL, duration: Double) -> NSImage? {
        let out = cacheRoot.appendingPathComponent("thumb-\(cacheKey(for: url)).jpg")
        if !FileManager.default.fileExists(atPath: out.path) {
            // Seek a third of the way in (past the bench-sitting), then decode a couple of
            // dozen frames before grabbing one: seeking into MPEG-TS lands on an estimated
            // byte offset, so the first frames after a seek are torn or grey.
            let seek = max(0, duration * 0.33)
            _ = try? FFmpeg.run([
                "-y", "-ss", String(format: "%.2f", seek),
                "-i", url.path,
                "-vf", "select=gte(n\\,24),scale=480:-2",
                "-frames:v", "1", "-q:v", "4",
                out.path,
            ])
        }
        return NSImage(contentsOf: out)
    }

    // MARK: Preview cache (lossless remux so AVPlayer can open it)

    func preparePreview(for clip: Clip, completion: @escaping (URL?) -> Void) {
        if let ready = clip.previewURL {
            completion(ready)
            return
        }
        // Non-.ts sources play natively already.
        if clip.url.pathExtension.lowercased() != "ts" {
            clip.previewURL = clip.url
            completion(clip.url)
            return
        }
        let out = Self.cacheRoot.appendingPathComponent("preview-\(Self.cacheKey(for: clip.url)).mp4")
        if FileManager.default.fileExists(atPath: out.path) {
            clip.previewURL = out
            completion(out)
            return
        }
        statusMessage = "Preparing preview…"
        let isHEVC = clip.info?.videoCodec == "hevc"
        Task.detached {
            var args = ["-y", "-i", clip.url.path, "-map", "0:v:0", "-map", "0:a?",
                        "-c", "copy", "-movflags", "+faststart"]
            if isHEVC {
                // AVFoundation refuses the default hev1 sample entry; hvc1 plays.
                args += ["-tag:v", "hvc1"]
            }
            args.append(out.path)
            let ok = (try? FFmpeg.run(args)) != nil
            if ok { Self.enforceCacheCap(keeping: out) }
            await MainActor.run { [weak self] in
                if ok {
                    clip.previewURL = out
                    self?.statusMessage = ""
                    completion(out)
                } else {
                    self?.statusMessage = "Could not prepare a preview for \(clip.name)."
                    completion(nil)
                }
                self?.refreshCacheSize()
            }
        }
    }

    // MARK: Selection

    func tickAll(_ on: Bool) {
        for c in clips { c.ticked = on }
        objectWillChange.send()
    }

    func invertTicks() {
        for c in clips { c.ticked.toggle() }
        objectWillChange.send()
    }

    var tickedClips: [Clip] { clips.filter(\.ticked) }
    var tickedBytes: Int64 { tickedClips.reduce(0) { $0 + ($1.info?.fileSize ?? 0) } }
}
