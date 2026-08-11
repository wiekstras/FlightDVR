import SwiftUI

@main
struct FlightStudioApp: App {
    @StateObject private var store = ClipStore()
    @StateObject private var queue = ExportQueue()
    @StateObject private var publishQueue = PublishQueue()

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(queue)
                .environmentObject(publishQueue)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Edit") { store.selectedClip?.undoEdit() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!(store.selectedClip?.canUndoEdit ?? false))
                Button("Redo Edit") { store.selectedClip?.redoEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!(store.selectedClip?.canRedoEdit ?? false))
            }
            CommandMenu("Clips") {
                Button("Scan") { store.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Find SD Card") { store.findSDCard() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Select All") { store.tickAll(true) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Deselect All") { store.tickAll(false) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("Move Ticked to Trash") { store.moveToTrash(store.tickedClips) }
                    .disabled(store.tickedClips.isEmpty)
            }
        }
    }
}
