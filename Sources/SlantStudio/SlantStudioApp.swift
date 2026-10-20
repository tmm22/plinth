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
            CommandMenu("Go") {
                ForEach(goMenuDestinations) { item in
                    if item == sidebarDeveloperDestinations.first { Divider() }
                    let button = Button(item.rawValue) { if !keyWindowShowsSheet() { store.destination = item } }
                        .disabled(store.isPresentingSheet)
                    if let key = goMenuShortcut(for: item) {
                        button.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                    } else {
                        button
                    }
                }
            }
            // Library file actions only; nothing here uploads, places, pays for or cancels anything.
            CommandMenu("Model") {
                let enabled = modelMenuEnabled(destination: store.destination, hasSelectedLocal: store.selectedLocal != nil,
                                               sheetPresented: store.isPresentingSheet)
                Button("Rename…") { if let id = store.selectedLocalID, !keyWindowShowsSheet() { store.renamingModelID = id } }
                    .disabled(!enabled)
                Button("Export…") { if let id = store.selectedLocalID, !keyWindowShowsSheet() { store.exportLocalModel(id: id) } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!enabled)
                Button("Show in Finder") { if let id = store.selectedLocalID, !keyWindowShowsSheet() { store.revealLocalModel(id: id) } }
                    .disabled(!enabled)
            }
        }
        Settings {
            ConnectionView(presentsPlatformComposer: true)
                .environmentObject(store)
                .frame(width: 640, height: 520)
        }
    }
}
