import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var store: ClipStore
    @EnvironmentObject var queue: ExportQueue
    @StateObject private var player = PlayerController()

    var body: some View {
        NavigationSplitView {
            ClipListView(player: player)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            if store.selectedClip != nil {
                HSplitView {
                    VStack(spacing: 0) {
                        PlayerPane(player: player)
                        Divider()
                        TimelinePane(player: player)
                            .frame(minHeight: 250, maxHeight: 320)
                    }
                    .layoutPriority(1)
                    TabView {
                        ExportPane()
                            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
                        PublishPane()
                            .tabItem { Label("Publish", systemImage: "paperplane") }
                    }
                        .frame(minWidth: 300, maxWidth: 340)
                }
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.findSDCard()
                } label: {
                    Label("Find SD Card", systemImage: "sdcard")
                }
                Button {
                    store.chooseFolder()
                } label: {
                    Label("Browse…", systemImage: "folder")
                }
                Button {
                    store.rescan()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(store.sourceFolder == nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusBar()
        }
        .onChange(of: store.selectedClip) { _, clip in
            player.load(clip: clip, store: store)
        }
        .task {
            store.refreshCacheSize()
            // `FlightStudio --open <folder>` scans a folder straight away.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open"), args.count > i + 1 {
                store.sourceFolder = URL(fileURLWithPath: args[i + 1])
                store.rescan()
            } else {
                store.restoreLastSourceFolder()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.openImportedURLs(urls)
        } isTargeted: { targeted in
            if targeted {
                store.statusMessage = "Drop to scan recordings"
            } else if store.statusMessage == "Drop to scan recordings" {
                store.statusMessage = "\(store.clips.count) clip\(store.clips.count == 1 ? "" : "s")"
            }
        }
        .onOpenURL { url in
            _ = store.openImportedURLs([url])
        }
        .alert("Couldn’t open edit project", isPresented: Binding(
            get: { store.projectOpenError != nil },
            set: { if !$0 { store.projectOpenError = nil } }
        )) {
            Button("OK", role: .cancel) { store.projectOpenError = nil }
        } message: {
            Text(store.projectOpenError ?? "")
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: ClipStore
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "airplane.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Insert a goggle card and press Find SD Card,\nor browse to any folder of recordings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Find SD Card") { store.findSDCard() }
                Button("Browse…") { store.chooseFolder() }
            }
            if store.ffmpegMissing {
                Text("ffmpeg was not found. Install it with:  brew install ffmpeg")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: ClipStore
    @EnvironmentObject var queue: ExportQueue
    var body: some View {
        HStack {
            if store.ffmpegMissing {
                Label("ffmpeg not found — brew install ffmpeg", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Text(store.statusMessage)
            }
            Spacer()
            if queue.isRunning {
                ProgressView().controlSize(.small)
                Text(queue.currentMessage)
            }
            if store.previewCacheBytes > 0 {
                Text("Media cache: \(byteString(store.previewCacheBytes))")
                Button("Clear") { store.clearPreviewCache() }
                    .controlSize(.mini)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Clip list

struct ClipListView: View {
    @EnvironmentObject var store: ClipStore
    @ObservedObject var player: PlayerController

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Sort", selection: $store.sortOrder) {
                    ForEach(SortOrder.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button {
                    store.reverseSort.toggle()
                } label: {
                    Image(systemName: store.reverseSort ? "arrow.up" : "arrow.down")
                }
                .help("Reverse sort order")
                Toggle(isOn: $store.favoritesOnly) {
                    Image(systemName: store.favoritesOnly ? "star.fill" : "star")
                }
                .toggleStyle(.button)
                .help("Show favorites only")
            }
            .padding(8)
            TextField("Filter clips", text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            TextField("Filter tags", text: $store.tagFilter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            Divider()
            List(selection: Binding(
                get: { store.selectedClip },
                set: { store.selectedClip = $0 }
            )) {
                if store.sortOrder == .date {
                    // One section per flying day, so a card reads as a logbook.
                    ForEach(store.daySections, id: \.day) { section in
                        Section {
                            ForEach(section.clips) { clip in
                                ClipRow(clip: clip).tag(clip)
                            }
                        } header: {
                            HStack {
                                Eyebrow(Self.dayFormatter.string(from: section.day))
                                Spacer()
                                Text("\(section.clips.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    ForEach(store.sortedClips) { clip in
                        ClipRow(clip: clip).tag(clip)
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: Clip.self) { selection in
                Button("Preview") {
                    if let clip = selection.first { store.selectedClip = clip }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(selection.map(\.url))
                }
                Button("Copy paths") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        selection.map(\.url.path).sorted().joined(separator: "\n"),
                        forType: .string)
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    store.moveToTrash(Array(selection))
                }
            }
            .onDeleteCommand {
                if let clip = store.selectedClip { store.moveToTrash([clip]) }
            }
            Divider()
            HStack {
                Button("All") { store.tickAll(true) }
                Button("None") { store.tickAll(false) }
                Button("Invert") { store.invertTicks() }
                Spacer()
                Text(store.tickedClips.isEmpty
                     ? "0 ticked"
                     : "\(store.tickedClips.count) ticked · \(byteString(store.tickedBytes))")
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .padding(8)
        }
    }
}

struct ClipRow: View {
    @ObservedObject var clip: Clip
    @EnvironmentObject var store: ClipStore
    @State private var newTag = ""

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb = clip.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 92, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator.opacity(0.5)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Button {
                        store.toggleFavorite(clip)
                    } label: {
                        Image(systemName: clip.favorite ? "star.fill" : "star")
                            .foregroundStyle(clip.favorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(clip.favorite ? "Remove favorite" : "Mark favorite")
                    Text(clip.name)
                        .font(.callout.weight(.medium).monospacedDigit())
                    if !clip.edit.isDefault {
                        Image(systemName: "scissors")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Has edits")
                    }
                    if !clip.highlights.isEmpty {
                        Label("\(clip.highlights.count)", systemImage: "sparkles.rectangle.stack")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("\(clip.highlights.count) saved highlight\(clip.highlights.count == 1 ? "" : "s")")
                    }
                }
                if let info = clip.info {
                    Text("\(format(seconds: info.duration)) · \(info.width)×\(info.height) \(Int(info.fps.rounded()))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(clip.relativeName.contains("/")
                         ? "\(byteString(info.fileSize)) · \(clip.relativeName.split(separator: "/").dropLast().joined(separator: "/"))"
                         : byteString(info.fileSize))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Reading…").font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    ForEach(clip.tags, id: \.self) { tag in
                        Button {
                            clip.removeTag(tag)
                            store.objectWillChange.send()
                        } label: {
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Remove tag \(tag)")
                    }
                    TextField("Add tag", text: $newTag)
                        .textFieldStyle(.plain)
                        .font(.caption2)
                        .frame(width: 72)
                        .onSubmit {
                            clip.addTag(newTag)
                            newTag = ""
                            store.objectWillChange.send()
                        }
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $clip.ticked)
                .labelsHidden()
                .toggleStyle(.checkbox)
        }
        .padding(.vertical, 3)
    }
}

func format(seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "–" }
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
