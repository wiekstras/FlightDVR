import SwiftUI
import Combine
import CryptoKit
import UniformTypeIdentifiers

struct ClipLibraryRecord: Codable, Equatable {
    var favorite = false
    var tags: [String] = []
    var edit: EditPlan? = nil
    /// Optional keeps records written before highlight shelves decodable.
    var highlights: [SavedHighlight]? = nil
}

/// A single decoded metadata index for the process. Previously every Clip init
/// decoded the complete UserDefaults payload, turning large scans into repeated
/// parsing work. The lock also keeps background queue recovery and UI edits safe.
final class ClipLibraryMetadataIndex: @unchecked Sendable {
    static let shared = ClipLibraryMetadataIndex()

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var records: [String: ClipLibraryRecord]

    init(defaults: UserDefaults = .standard, key: String = "clipLibraryMetadata-v1") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key) {
            records = (try? JSONDecoder().decode([String: ClipLibraryRecord].self, from: data)) ?? [:]
        } else {
            records = [:]
        }
    }

    func record(for url: URL) -> ClipLibraryRecord {
        lock.lock()
        defer { lock.unlock() }
        return records[url.standardizedFileURL.path] ?? ClipLibraryRecord()
    }

    func save(_ record: ClipLibraryRecord, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        records[url.standardizedFileURL.path] = record
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }

    var recordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }
}

/// Durable probe results for unchanged media. The key includes path, byte size,
/// and modification date, so recordings still being written invalidate safely.
final class MediaMetadataCache: @unchecked Sendable {
    static let shared = MediaMetadataCache()
    static let defaultURL = ClipStore.cacheRoot.appendingPathComponent("media-metadata-v1.json")

    private struct Record: Codable {
        var info: ClipInfo
        var storedAt: Date
    }

    private let url: URL
    private let lock = NSLock()
    private var records: [String: Record]

    init(url: URL = MediaMetadataCache.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func info(for key: String) -> ClipInfo? {
        lock.lock()
        defer { lock.unlock() }
        return records[key]?.info
    }

    func store(_ info: ClipInfo, for key: String) {
        lock.lock()
        records[key] = Record(info: info, storedAt: Date())
        lock.unlock()
    }

    func flush(maxRecords: Int = 20_000) throws {
        lock.lock()
        defer { lock.unlock() }
        let limit = max(maxRecords, 1)
        if records.count > limit {
            let keep = Set(records.sorted { $0.value.storedAt > $1.value.storedAt }
                .prefix(limit).map(\.key))
            records = records.filter { keep.contains($0.key) }
        }
        let snapshot = records
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    var recordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }
}

final class Clip: ObservableObject, Identifiable, Hashable {
    private static let filenameDateRegex = try? NSRegularExpression(
        pattern: #"(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?:[-_ T.]?(\d{2})[-_.:]?(\d{2})[-_.:]?(\d{2}))?"#
    )
    let id: URL
    let url: URL
    @Published var info: ClipInfo?
    @Published var thumbnail: NSImage?
    @Published var timelineFilmstrip: NSImage?
    @Published var timelineWaveform: NSImage?
    @Published var ticked = false
    @Published var previewURL: URL?      // remuxed .mp4 the native player can open
    @Published var edit = EditPlan() {
        didSet {
            guard !restoringEdit, edit != oldValue else { return }
            if editTransactionBaseline == nil {
                appendUndo(oldValue)
                redoEdits.removeAll()
            }
            scheduleEditPersistence()
        }
    }
    @Published var relativeName: String = ""   // path relative to the scanned folder
    @Published var favorite = false {
        didSet {
            guard favorite != oldValue else { return }
            persistLibraryRecord()
        }
    }
    @Published var tags: [String] = [] {
        didSet { persistLibraryRecord() }
    }
    @Published var highlights: [SavedHighlight] = [] {
        didSet { persistLibraryRecord() }
    }
    private var undoEdits: [EditPlan] = []
    private var redoEdits: [EditPlan] = []
    private var editTransactionBaseline: EditPlan?
    private var restoringEdit = false
    private var editSaveWorkItem: DispatchWorkItem?
    private let isLibraryBacked: Bool

    let fileDate: Date           // the filesystem's story
    let parsedDate: Date?        // a date found in the filename, which we trust more

    convenience init(url: URL) {
        self.init(url: url, fileDate: Self.readFileDate(for: url))
    }

    init(url: URL, fileDate: Date, isLibraryBacked: Bool = true,
         editOverride: EditPlan? = nil) {
        self.url = url
        self.id = url
        self.isLibraryBacked = isLibraryBacked
        self.relativeName = url.lastPathComponent
        self.fileDate = fileDate
        self.parsedDate = Clip.parseDate(from: url.lastPathComponent)
        let record = isLibraryBacked
            ? ClipLibraryMetadataIndex.shared.record(for: url) : ClipLibraryRecord()
        self.favorite = record.favorite
        self.tags = record.tags
        self.edit = editOverride ?? record.edit ?? EditPlan()
        self.highlights = record.highlights ?? []
    }

    static func exportVariant(from clip: Clip, edit: EditPlan) -> Clip {
        let variant = Clip(url: clip.url, fileDate: clip.fileDate,
                           isLibraryBacked: false, editOverride: edit)
        variant.info = clip.info
        variant.thumbnail = clip.thumbnail
        variant.relativeName = clip.relativeName
        return variant
    }

    var name: String { url.lastPathComponent }
    var canUndoEdit: Bool { !undoEdits.isEmpty }
    var canRedoEdit: Bool { !redoEdits.isEmpty }

    /// Groups a continuous UI gesture (for example a trim-handle drag or audio
    /// slider movement) into one useful undo step instead of one step per pixel.
    func beginEditTransaction() {
        guard editTransactionBaseline == nil else { return }
        editTransactionBaseline = edit
    }

    func endEditTransaction() {
        guard let baseline = editTransactionBaseline else { return }
        editTransactionBaseline = nil
        guard edit != baseline else { return }
        appendUndo(baseline)
        redoEdits.removeAll()
        scheduleEditPersistence()
    }

    func undoEdit() {
        endEditTransaction()
        guard let previous = undoEdits.popLast() else { return }
        restoringEdit = true
        redoEdits.append(edit)
        edit = previous
        restoringEdit = false
        persistLibraryRecord()
    }

    func redoEdit() {
        endEditTransaction()
        guard let next = redoEdits.popLast() else { return }
        restoringEdit = true
        undoEdits.append(edit)
        edit = next
        restoringEdit = false
        persistLibraryRecord()
    }

    func clearEditHistory() {
        editTransactionBaseline = nil
        undoEdits.removeAll()
        redoEdits.removeAll()
    }

    private func appendUndo(_ previous: EditPlan) {
        undoEdits.append(previous)
        if undoEdits.count > 100 { undoEdits.removeFirst(undoEdits.count - 100) }
    }

    func addTag(_ tag: String) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else { return }
        tags.append(cleaned)
        tags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    @discardableResult
    func saveCurrentHighlight(duration: Double) -> SavedHighlight? {
        guard edit.validationError(duration: duration) == nil else { return nil }
        let highlight = SavedHighlight(name: "Highlight \(highlights.count + 1)",
                                       edit: edit.sanitized(duration: duration))
        highlights.append(highlight)
        return highlight
    }

    func loadHighlight(_ highlight: SavedHighlight) {
        edit = highlight.edit
    }

    func removeHighlight(id: UUID) {
        highlights.removeAll { $0.id == id }
    }

    private func persistLibraryRecord() {
        guard isLibraryBacked else { return }
        editSaveWorkItem?.cancel()
        let savedEdit = edit.isDefault && edit.markers.isEmpty ? nil : edit
        ClipLibraryMetadataIndex.shared.save(
            ClipLibraryRecord(favorite: favorite, tags: tags, edit: savedEdit,
                              highlights: highlights.isEmpty ? nil : highlights),
            for: url
        )
    }

    /// Timeline drags and sliders can publish dozens of changes per second.
    /// Coalesce those writes so editing never repeatedly rewrites library data.
    private func scheduleEditPersistence() {
        editSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistLibraryRecord() }
        editSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    /// Best guess at when this was flown: a date embedded in the filename wins,
    /// otherwise the file's own date.
    var flightDate: Date { parsedDate ?? fileDate }
    var flightDay: Date { Calendar.current.startOfDay(for: flightDate) }

    /// Finds yyyyMMdd / yyyy-MM-dd / yyyy_MM_dd in a filename, with an optional
    /// HHmmss / HH-mm-ss after it (e.g. hdz_20250712_143005.ts).
    static func parseDate(from name: String) -> Date? {
        guard let regex = filenameDateRegex,
              let m = regex.firstMatch(
            in: name, range: NSRange(name.startIndex..., in: name))
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

    static func readFileDate(for url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] ?? attrs?[.modificationDate]) as? Date ?? .distantPast
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

struct ScannedVideoFile: Equatable, Sendable {
    var url: URL
    var fileDate: Date
    var cachedInfo: ClipInfo?
}

enum TimelineFilmstripBuilder {
    static func command(source: URL, duration: Double, output: URL,
                        frameCount: Int = 12) -> [String] {
        let count = max(2, frameCount)
        var args = ["-y"]
        for index in 0..<count {
            let fraction = (Double(index) + 0.5) / Double(count)
            args += ["-ss", String(format: "%.3f", max(0, duration * fraction)),
                     "-i", source.path]
        }
        var filters: [String] = []
        for index in 0..<count {
            // Decode past the imprecise transport-stream seek point before
            // taking a frame, avoiding the torn first GOP common on DVR files.
            filters.append("[\(index):v]select=gte(n\\,12),scale=160:90,setpts=PTS-STARTPTS[v\(index)]")
        }
        let inputs = (0..<count).map { "[v\($0)]" }.joined()
        filters.append("\(inputs)hstack=inputs=\(count)[strip]")
        args += ["-filter_complex", filters.joined(separator: ";"),
                 "-map", "[strip]", "-frames:v", "1", "-q:v", "5", output.path]
        return args
    }
}

enum TimelineWaveformBuilder {
    static func command(source: URL, output: URL, width: Int = 1600,
                        height: Int = 80) -> [String] {
        let safeWidth = max(width, 320)
        let safeHeight = max(height, 40)
        let filter = "[0:a]aformat=channel_layouts=mono,showwavespic=s=\(safeWidth)x\(safeHeight):colors=white[wave]"
        return ["-y", "-i", source.path, "-filter_complex", filter,
                "-map", "[wave]", "-frames:v", "1", output.path]
    }
}

enum MediaCacheFiles {
    static let evictablePrefixes = ["preview-", "filmstrip-", "waveform-", "thumb-"]

    static func isEvictable(_ url: URL) -> Bool {
        guard !url.lastPathComponent.contains("-work-") else { return false }
        return evictablePrefixes.contains { url.lastPathComponent.hasPrefix($0) }
    }

    static func evictableFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter(isEvictable)
    }
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
    @Published var favoritesOnly = false
    @Published var tagFilter = ""
    @Published var previewCacheBytes: Int64 = 0
    @Published var projectOpenError: String?
    private var filmstripTasks: [URL: (id: UUID, task: Task<Void, Never>)] = [:]
    private var waveformTasks: [URL: (id: UUID, task: Task<Void, Never>)] = [:]
    private var pendingProjectOpen: (data: Data, sourceURL: URL)?
    private var activeScanID: UUID?

    /// Clips in the chosen order. Date order = newest flight first.
    var sortedClips: [Clip] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = query.isEmpty ? clips : clips.filter {
            $0.relativeName.localizedCaseInsensitiveContains(query)
        }
        let favoriteFiltered = favoritesOnly ? matched.filter(\.favorite) : matched
        let tag = tagFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchable = tag.isEmpty ? favoriteFiltered : favoriteFiltered.filter {
            $0.tags.contains { $0.localizedCaseInsensitiveContains(tag) }
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

    nonisolated static func mediaCacheKey(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int64 ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = Insecure.MD5.hash(data: Data("\(url.path)|\(size)|\(modified)".utf8))
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
            found.append(url.standardizedFileURL)
            if stopAtFirst { break }
        }
        return found.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// Resolve filesystem attributes on the scanning worker, not while SwiftUI
    /// is constructing thousands of observable Clip objects on the main actor.
    nonisolated static func scanVideoFiles(in folder: URL, maxDepth: Int = 5) -> [ScannedVideoFile] {
        findVideoFiles(in: folder, maxDepth: maxDepth).map {
            let key = mediaCacheKey(for: $0)
            return ScannedVideoFile(url: $0, fileDate: Clip.readFileDate(for: $0),
                                    cachedInfo: MediaMetadataCache.shared.info(for: key))
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

    /// Resolve Finder drops and Open With events to the narrowest library
    /// folder DVR Studio can scan without copying or moving source footage.
    @discardableResult
    func openImportedURLs(_ urls: [URL]) -> Bool {
        if urls.count == 1, let projectURL = urls.first,
           EditProjectFile.isProjectURL(projectURL) {
            openEditProject(at: projectURL)
            return true
        }
        guard let folder = Self.importFolder(for: urls) else {
            statusMessage = "Drop a video, project, or folder containing recordings."
            return false
        }
        sourceFolder = folder
        rescan()
        return true
    }

    /// Open a native edit document, locating a moved source when necessary.
    /// The edit is applied only after the asynchronous library scan has created
    /// the matching Clip object, keeping player and metadata state coherent.
    func openEditProject(at projectURL: URL) {
        do {
            let data = try Data(contentsOf: projectURL)
            let project = try EditProjectFile.project(from: data)
            let recorded = URL(fileURLWithPath: project.sourcePath).standardizedFileURL
            let sourceURL: URL
            if FileManager.default.fileExists(atPath: recorded.path) {
                sourceURL = recorded
            } else {
                let panel = NSOpenPanel()
                panel.message = "Locate the recording for \(projectURL.lastPathComponent)"
                panel.prompt = "Use Recording"
                panel.allowedContentTypes = Self.videoExtensions.compactMap {
                    UTType(filenameExtension: $0)
                }
                panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let replacement = panel.url else { return }
                sourceURL = replacement.standardizedFileURL
            }
            guard Self.videoExtensions.contains(sourceURL.pathExtension.lowercased()) else {
                throw EditProjectError.wrongSource(sourceURL.lastPathComponent)
            }
            pendingProjectOpen = (data, sourceURL)
            let currentFolder = sourceFolder?.standardizedFileURL
            if let currentFolder,
               sourceURL.path.hasPrefix(currentFolder.path + "/") {
                sourceFolder = currentFolder
            } else {
                sourceFolder = sourceURL.deletingLastPathComponent()
            }
            rescan()
        } catch {
            projectOpenError = error.localizedDescription
        }
    }

    nonisolated static func importFolder(for urls: [URL]) -> URL? {
        let standardized = urls.map(\.standardizedFileURL)
        if let folder = standardized.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) {
            return folder
        }
        let videos = standardized.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        guard let first = videos.first else { return nil }
        let parent = first.deletingLastPathComponent()
        return videos.allSatisfy { $0.deletingLastPathComponent() == parent } ? parent : nil
    }

    func rescan() {
        guard let folder = sourceFolder else { return }
        let scanID = UUID()
        activeScanID = scanID
        UserDefaults.standard.set(folder.path, forKey: Self.lastFolderDefaultsKey)
        isScanning = true
        statusMessage = "Scanning \(folder.path)…"
        Task.detached { [weak self] in
            let files = Self.scanVideoFiles(in: folder)
            await MainActor.run { [weak self] in
                guard let self, self.activeScanID == scanID else { return }
                self.activeScanID = nil
                let existing = Dictionary(uniqueKeysWithValues: self.clips.map { ($0.url, $0) })
                self.clips = files.map { file in
                    let clip = existing[file.url] ?? Clip(url: file.url, fileDate: file.fileDate)
                    if clip.info == nil { clip.info = file.cachedInfo }
                    clip.relativeName = file.url.path.hasPrefix(folder.path + "/")
                        ? String(file.url.path.dropFirst(folder.path.count + 1))
                        : file.url.lastPathComponent
                    return clip
                }
                self.isScanning = false
                if let pending = self.pendingProjectOpen {
                    self.pendingProjectOpen = nil
                    if let target = self.clips.first(where: {
                        $0.url.standardizedFileURL == pending.sourceURL.standardizedFileURL
                    }) {
                        do {
                            target.edit = try EditProjectFile.decode(pending.data, for: target)
                            self.selectedClip = target
                            self.statusMessage = "Opened edit project for \(target.name)"
                        } catch {
                            self.projectOpenError = error.localizedDescription
                            self.statusMessage = "Couldn’t open edit project"
                        }
                    } else {
                        self.projectOpenError = "The selected recording was not found in the scanned folder."
                        self.statusMessage = "Couldn’t locate project recording"
                    }
                } else {
                    self.statusMessage = "\(files.count) clip\(files.count == 1 ? "" : "s")"
                    if let selected = self.selectedClip {
                        if !self.clips.contains(selected) { self.selectedClip = self.clips.first }
                    } else {
                        self.selectedClip = self.clips.first
                    }
                }
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
        let pending = clips.filter { $0.info == nil || $0.thumbnail == nil }
            .map { (clip: $0, cachedInfo: $0.info) }
        guard !pending.isEmpty else { return }
        let needsCacheFlush = pending.contains { $0.cachedInfo == nil }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                func addNext(_ group: inout TaskGroup<Void>) -> Bool {
                    guard let item = iterator.next() else { return false }
                    group.addTask {
                        let clip = item.clip
                        let info = item.cachedInfo ?? (try? Probe.probe(clip.url))
                        if item.cachedInfo == nil, let info {
                            MediaMetadataCache.shared.store(
                                info, for: Self.mediaCacheKey(for: clip.url))
                        }
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
            if needsCacheFlush { try? MediaMetadataCache.shared.flush() }
            Self.enforceCacheCap(keeping: nil)
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
            let bytes = Self.evictableCacheFiles().reduce(Int64(0)) { sum, url in
                sum + (((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0)
            }
            await MainActor.run { [weak self] in self?.previewCacheBytes = bytes }
        }
    }

    func clearPreviewCache() {
        for entry in filmstripTasks.values { entry.task.cancel() }
        filmstripTasks.removeAll()
        for entry in waveformTasks.values { entry.task.cancel() }
        waveformTasks.removeAll()
        for url in Self.evictableCacheFiles() {
            try? FileManager.default.removeItem(at: url)
        }
        for clip in clips where clip.url.pathExtension.lowercased() == "ts" {
            clip.previewURL = nil
        }
        for clip in clips { clip.timelineFilmstrip = nil }
        for clip in clips { clip.timelineWaveform = nil }
        refreshCacheSize()
        statusMessage = "Media cache cleared."
    }

    nonisolated private static func evictableCacheFiles(in folder: URL = cacheRoot) -> [URL] {
        MediaCacheFiles.evictableFiles(in: folder)
    }

    /// Drop the oldest previews until the cache fits the cap, sparing `keep`.
    nonisolated static func enforceCacheCap(keeping keep: URL?,
                                            cap: Int64 = previewCacheCap,
                                            in folder: URL = cacheRoot) {
        var entries: [(url: URL, size: Int64, date: Date)] = evictableCacheFiles(in: folder).compactMap { url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return (url, attrs[.size] as? Int64 ?? 0, attrs[.modificationDate] as? Date ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > max(cap, 0) {
            if entry.url == keep { continue }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: Thumbnails

    nonisolated private static func extractThumbnail(for url: URL, duration: Double) -> NSImage? {
        let out = cacheRoot.appendingPathComponent("thumb-\(mediaCacheKey(for: url)).jpg")
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

    /// Lazily build a visual timeline only for clips the user opens. A library
    /// with thousands of recordings therefore pays no up-front filmstrip cost.
    func prepareTimelineFilmstrip(for clip: Clip) {
        let obsolete = filmstripTasks.keys.filter { $0 != clip.url }
        for url in obsolete {
            filmstripTasks[url]?.task.cancel()
            filmstripTasks[url] = nil
        }
        guard clip.timelineFilmstrip == nil,
              let duration = clip.info?.duration, duration > 0,
              filmstripTasks[clip.url] == nil else { return }
        let out = Self.cacheRoot.appendingPathComponent(
            "filmstrip-\(Self.mediaCacheKey(for: clip.url)).jpg")
        if let cached = NSImage(contentsOf: out) {
            clip.timelineFilmstrip = cached
            return
        }
        let clipURL = clip.url
        let taskID = UUID()
        let staging = Self.cacheRoot.appendingPathComponent(
            "filmstrip-work-\(taskID.uuidString).jpg")
        let task = Task.detached(priority: .utility) {
            let args = TimelineFilmstripBuilder.command(
                source: clip.url, duration: duration, output: staging)
            let generated: Bool
            do {
                _ = try FFmpeg.run(args, isCancelled: { Task.isCancelled })
                generated = !Task.isCancelled
            } catch {
                generated = false
                try? FileManager.default.removeItem(at: staging)
            }
            await MainActor.run { [weak self, weak clip] in
                guard self?.filmstripTasks[clipURL]?.id == taskID else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                self?.filmstripTasks[clipURL] = nil
                if generated {
                    try? FileManager.default.removeItem(at: out)
                    try? FileManager.default.moveItem(at: staging, to: out)
                }
                if generated, let image = NSImage(contentsOf: out) {
                    clip?.timelineFilmstrip = image
                    Task.detached { Self.enforceCacheCap(keeping: out) }
                    self?.refreshCacheSize()
                }
            }
        }
        filmstripTasks[clipURL] = (taskID, task)
    }

    /// Waveforms are also selected-clip-only. Long recordings may take time to
    /// analyse, so obsolete work is terminated as soon as selection changes.
    func prepareTimelineWaveform(for clip: Clip) {
        let obsolete = waveformTasks.keys.filter { $0 != clip.url }
        for url in obsolete {
            waveformTasks[url]?.task.cancel()
            waveformTasks[url] = nil
        }
        guard clip.timelineWaveform == nil,
              clip.info?.hasAudio == true,
              waveformTasks[clip.url] == nil else { return }
        let out = Self.cacheRoot.appendingPathComponent(
            "waveform-\(Self.mediaCacheKey(for: clip.url)).png")
        if let cached = NSImage(contentsOf: out) {
            clip.timelineWaveform = cached
            return
        }

        let clipURL = clip.url
        let taskID = UUID()
        let staging = Self.cacheRoot.appendingPathComponent(
            "waveform-work-\(taskID.uuidString).png")
        let task = Task.detached(priority: .utility) {
            let args = TimelineWaveformBuilder.command(source: clip.url, output: staging)
            let generated: Bool
            do {
                _ = try FFmpeg.run(args, isCancelled: { Task.isCancelled })
                generated = !Task.isCancelled
            } catch {
                generated = false
                try? FileManager.default.removeItem(at: staging)
            }
            await MainActor.run { [weak self, weak clip] in
                guard self?.waveformTasks[clipURL]?.id == taskID else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                self?.waveformTasks[clipURL] = nil
                if generated {
                    try? FileManager.default.removeItem(at: out)
                    try? FileManager.default.moveItem(at: staging, to: out)
                }
                if generated, let image = NSImage(contentsOf: out) {
                    clip?.timelineWaveform = image
                    Task.detached { Self.enforceCacheCap(keeping: out) }
                    self?.refreshCacheSize()
                }
            }
        }
        waveformTasks[clipURL] = (taskID, task)
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
        let out = Self.cacheRoot.appendingPathComponent("preview-\(Self.mediaCacheKey(for: clip.url)).mp4")
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

    func toggleFavorite(_ clip: Clip) {
        clip.favorite.toggle()
        objectWillChange.send()
    }

    var tickedClips: [Clip] { clips.filter(\.ticked) }
    var tickedBytes: Int64 { tickedClips.reduce(0) { $0 + ($1.info?.fileSize ?? 0) } }
}
