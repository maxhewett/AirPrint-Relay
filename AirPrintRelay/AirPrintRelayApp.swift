import AppKit
import SwiftUI

@main
struct AirPrintRelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        Window("AirPrint Relay", id: "main") {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 880, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appModel.updater.checkForUpdates()
                }
                .disabled(!appModel.updater.canCheckForUpdates)

                Button("Settings...") {
                    appModel.showSettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu("Relay") {
                Button("Refresh Printers") {
                    Task { await appModel.refreshPrinters() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Open Printers Settings") {
                    appModel.openPrintersSettings()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Show Logs") {
                    appModel.showLogs()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Button("Stop Advertising All") {
                    appModel.stopAdvertisingAll()
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
