import SwiftUI
import AppKit

@main
struct SlantStudioApp: App {
    @StateObject private var store = StudioStore()
    @StateObject private var modalPresentation = ModalPresentationMonitor()
    var body: some Scene {
        WindowGroup {
            StudioView().environmentObject(store)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(.studioAccent)
        }
        .defaultSize(width: 1360, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            let modalUIShown = store.isPresentingSheet || modalPresentation.isPresenting
            let modelFileEnabled = modelFileCommandsEnabled(destination: store.destination, hasSelectedLocal: store.selectedLocal != nil,
                                                            sheetPresented: modalUIShown)
            CommandGroup(replacing: .newItem) {
                Button("New Order Draft…") { store.openOrderComposer() }
                    .keyboardShortcut("n")
                    .disabled(store.orderDraftBlockedReason != nil || store.busy)
                Button("Import Model…") { store.importModel() }
                    .keyboardShortcut("o")
                Button("Import Model from URL…") { store.showImportFromURL = true }
                    .disabled(store.importFromURLBlockedReason != nil)
                Divider()
                // Library file actions only; nothing here uploads, places, pays for or cancels anything.
                Button("Rename Model…") { store.beginRenamingSelectedModelFromMenu() }
                    .disabled(!modelFileEnabled)
                Button("Export Model…") { store.exportSelectedModelFromMenu() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!modelFileEnabled)
                Divider()
                Button("Refresh") { Task { await store.refreshCurrent() } }
                    .keyboardShortcut("r")
                    .disabled(!store.connected || store.busy)
            }
            SidebarCommands()
            CommandMenu("Go") {
                ForEach(goMenuDestinations) { item in
                    if item == sidebarDeveloperDestinations.first { Divider() }
                    let button = Button(item.rawValue) { store.goFromMenu(to: item) }
                        .disabled(modalUIShown)
                    if let key = goMenuShortcut(for: item) {
                        button.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                    } else {
                        button
                    }
                }
            }
        }
        Settings {
            ConnectionView(presentsPlatformComposer: true)
                .environmentObject(store)
                .frame(width: 640, height: 520)
        }
    }
}
