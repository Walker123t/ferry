import AppKit
import SwiftUI

@main
struct FerryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Ferry", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 540)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1200, height: 740)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { FerryCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

struct FerryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder on Phone") { model.beginNewFolder(.phone) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Folder on Mac") { model.beginNewFolder(.mac) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandMenu("Transfer") {
            Button("Copy Selection to Mac") { model.copySelectionToMac() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Copy Selection to Phone") { model.copySelectionToPhone() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Divider()
            Button("Clear Finished Transfers") { model.clearFinishedJobs() }
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh") { model.refreshAll() }
                .keyboardShortcut("r")
            Button(model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { model.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
        }
    }
}
