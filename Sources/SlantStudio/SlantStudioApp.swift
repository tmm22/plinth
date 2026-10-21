import SwiftUI
import AppKit

@main
struct SlantStudioApp: App {
    @NSApplicationDelegateAdaptor(SlantStudioAppDelegate.self) private var appDelegate
    @StateObject private var store = StudioStore()
    @StateObject private var modalPresentation = ModalPresentationMonitor()
    var body: some Scene {
        WindowGroup(id: mainWindowID) {
            StudioView().environmentObject(store)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(.studioAccent)
                .modifier(ExternalModelOpenAttachment(store: store))
        }
        .defaultSize(width: 1360, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            let modalUIShown = store.isPresentingSheet || modalPresentation.isPresenting
            let modelFileEnabled = modelFileCommandsEnabled(destination: store.destination, hasSelectedLocal: store.selectedLocal != nil,
                                                            sheetPresented: modalUIShown)
            CommandGroup(replacing: .newItem) {
                // Like the Go menu, these do nothing over a sheet, alert or dialog: opening the composer or importing
                // (which shows Models) must never replace an open Pay or Cancel review.
                Button("New Order Draft…") { store.openOrderComposerFromMenu() }
                    .keyboardShortcut("n")
                    .disabled(store.orderDraftBlockedReason != nil || store.busy || modalUIShown)
                Button("Import Model…") { store.importModelFromMenu() }
                    .keyboardShortcut("o")
                    .disabled(modalUIShown)
                Button("Import Model from URL…") { store.importModelFromURLFromMenu() }
                    .disabled(store.importFromURLBlockedReason != nil || modalUIShown)
                Divider()
                // Library file actions only; nothing here uploads, places, pays for or cancels anything.
                Button("Rename Model…") { store.beginRenamingSelectedModelFromMenu() }
                    .disabled(!modelFileEnabled)
                Button("Export Model…") { store.exportSelectedModelFromMenu() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!modelFileEnabled)
                // Saves a CSV of the loaded orders shown in the list; no request is made.
                Button("Export Orders…") { store.exportOrdersFromMenu() }
                    .disabled(!ordersExportMenuEnabled(destination: store.destination, ordersLoaded: !store.orders.isEmpty,
                                                       sheetPresented: modalUIShown))
                Divider()
                Button("Refresh") { store.refreshFromMenu() }
                    .keyboardShortcut("r")
                    .disabled(!store.connected || store.busy || modalUIShown)
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

/// Connects Finder opens to the store once a window exists; files opened earlier wait in the queue.
private struct ExternalModelOpenAttachment: ViewModifier {
    let store: StudioStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let queue = ExternalModelOpenQueue.shared
            queue.openMainWindow = { openWindow(id: mainWindowID) }
            queue.attach(store)
        }
    }
}
