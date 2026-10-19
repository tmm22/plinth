import SwiftUI
import AppKit

@main
struct SlantStudioApp: App {
    @StateObject private var store = StudioStore()
    var body: some Scene {
        WindowGroup {
            StudioView().environmentObject(store)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(.studioAccent)
        }
        .defaultSize(width: 1360, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Order Draft…") { store.openOrderComposer() }
                    .keyboardShortcut("n")
                    .disabled(store.orderDraftBlockedReason != nil || store.busy)
                Button("Import Model…") { store.importModel() }
                    .keyboardShortcut("o")
                Button("Import Model from URL…") { store.showImportFromURL = true }
                    .disabled(store.importFromURLBlockedReason != nil)
                Button("Refresh") { Task { await store.refreshCurrent() } }
                    .keyboardShortcut("r")
                    .disabled(!store.connected || store.busy)
            }
            SidebarCommands()
        }
        Settings {
            ConnectionView(presentsPlatformComposer: true)
                .environmentObject(store)
                .frame(width: 640, height: 520)
        }
    }
}
