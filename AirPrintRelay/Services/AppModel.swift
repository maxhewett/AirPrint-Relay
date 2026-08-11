import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let defaultShortcutInstallURL = "https://www.icloud.com/shortcuts/d231b340d0244cd5a70ee521c8548af4"

    @Published private(set) var printers: [Printer] = []
    @Published private(set) var cupsStatus = CUPSStatus()
    @Published private(set) var isRefreshing = false
    @Published var enabledPrinterNames: Set<String> {
        didSet {
            saveEnabledPrinterNames()
            syncRelayAndAdvertising()
        }
    }
    @Published var advertisementProfile: AdvertisementProfile {
        didSet {
            saveAdvertisementProfile()
            syncRelayAndAdvertising()
        }
    }
    @Published var advertisementSettingsByPrinterName: [String: PrinterAdvertisementSettings] {
        didSet {
            saveAdvertisementSettings()
            syncRelayAndAdvertising()
        }
    }
    @Published private(set) var shortcutInstallURL: String {
        didSet {
        }
    }
    @Published private(set) var showMenuBarExtra: Bool
    @Published private(set) var showDockIcon: Bool
    @Published var launchAtLogin = false
    @Published var lastRefreshMessage = "Not refreshed yet"
    @Published var isShowingLogs = false
    @Published var isShowingSettings = false

    let relayServer = IPPRelayServer()
    let advertiser = AirPrintAdvertiser()
    let logs = AppLogStore.shared
    let updater = AppUpdater()

    private lazy var menuBarController = MenuBarController(model: self)
    private weak var mainWindow: NSWindow?
    private var appKitMainWindowController: NSWindowController?
    private let enabledDefaultsKey = "enabledPrinterNames"
    private let advertisementSettingsDefaultsKey = "advertisementSettingsByPrinterName"
    private let showMenuBarExtraDefaultsKey = "showMenuBarExtra"
    private let showDockIconDefaultsKey = "showDockIcon"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: enabledDefaultsKey) ?? []
        enabledPrinterNames = Set(saved)
        advertisementProfile = AdvertisementProfile()
        if let data = UserDefaults.standard.data(forKey: advertisementSettingsDefaultsKey),
           let settings = try? JSONDecoder().decode([String: PrinterAdvertisementSettings].self, from: data) {
            advertisementSettingsByPrinterName = settings
        } else {
            advertisementSettingsByPrinterName = [:]
        }
        shortcutInstallURL = Self.defaultShortcutInstallURL
        showMenuBarExtra = UserDefaults.standard.bool(forKey: showMenuBarExtraDefaultsKey)
        if UserDefaults.standard.object(forKey: showDockIconDefaultsKey) == nil {
            showDockIcon = true
        } else {
            showDockIcon = UserDefaults.standard.bool(forKey: showDockIconDefaultsKey)
        }
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        if !showMenuBarExtra && !showDockIcon {
            showDockIcon = true
        }
        applyDockIconVisibility()
        updateMenuBarExtraVisibility()

        Task {
            await refreshPrinters()
        }
    }

    func refreshPrinters() async {
        isRefreshing = true
        logs.info("Refreshing printers and CUPS status.")
        async let loadedPrinters = CUPSService.loadPrinters()
        async let loadedStatus = CUPSService.status()

        printers = await loadedPrinters
        cupsStatus = await loadedStatus
        lastRefreshMessage = printers.isEmpty ? "No CUPS printers found" : "Found \(printers.count) printer\(printers.count == 1 ? "" : "s")"
        logs.info("Refresh complete: \(lastRefreshMessage). CUPS scheduler: \(cupsStatus.schedulerRunning ? "running" : "not running").")
        for printer in printers {
            logs.debug("Queue \(printer.name): accepting=\(printer.acceptsJobs), state=\(printer.state), uri=\(printer.deviceURI.isEmpty ? "unknown" : printer.deviceURI).")
        }
        isRefreshing = false
        syncRelayAndAdvertising()
    }

    func setEnabled(_ enabled: Bool, for printer: Printer) {
        if !enabled {
            logs.info("Stopped advertising \(printer.displayName).")
            enabledPrinterNames.remove(printer.name)
            return
        }

        guard printer.acceptsJobs else {
            logs.warning("Cannot advertise \(printer.name) because CUPS reports it is not accepting jobs.")
            return
        }

        logs.info("Enabled AirPrint Relay endpoint for queue \(printer.name).")
        enabledPrinterNames.insert(printer.name)
    }

    func advertisementSettings(for printer: Printer) -> PrinterAdvertisementSettings {
        advertisementSettingsByPrinterName[printer.name] ?? PrinterAdvertisementSettings()
    }

    func setAdvertisementSettings(_ settings: PrinterAdvertisementSettings, for printer: Printer) {
        advertisementSettingsByPrinterName[printer.name] = settings
        logs.info("Updated AirPrint listing for \(printer.name): name=\(settings.displayName(for: printer)), location=\(settings.location(for: printer).isEmpty ? "none" : settings.location(for: printer)), model=\(settings.model(for: printer)).")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            lastRefreshMessage = "Could not update login item: \(error.localizedDescription)"
        }
    }

    func openPrintersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func registerMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        guard window !== mainWindow else { return }

        configureMainWindow(window)
        mainWindow = window
    }

    func showMainWindow() {
        if focusExistingMainWindow() {
            return
        }

        showAppKitMainWindow()
    }

    func presentLogs() {
        isShowingSettings = false
        isShowingLogs = true
    }

    func presentSettings() {
        isShowingLogs = false
        isShowingSettings = true
    }

    func showLogs() {
        showMainWindow()
        DispatchQueue.main.async {
            self.presentLogs()
        }
    }

    func showSettings() {
        showMainWindow()
        DispatchQueue.main.async {
            self.presentSettings()
        }
    }

    func stopAdvertisingAll() {
        guard !enabledPrinterNames.isEmpty else {
            advertiser.stopAll()
            return
        }

        logs.info("Disabled all AirPrint Relay advertised queues.")
        enabledPrinterNames.removeAll()
        advertiser.stopAll()
    }

    var shortcutQRCodeURL: String {
        Self.defaultShortcutInstallURL
    }

    func setShowMenuBarExtra(_ enabled: Bool) {
        if !enabled && !showDockIcon {
            showDockIcon = true
            applyDockIconVisibility()
        }
        showMenuBarExtra = enabled
        saveAppBehavior()
        updateMenuBarExtraVisibility()
    }

    func setShowDockIcon(_ visible: Bool) {
        if !visible && !showMenuBarExtra {
            showMenuBarExtra = true
        }
        showDockIcon = visible
        saveAppBehavior()
        applyDockIconVisibility()
    }

    private func saveEnabledPrinterNames() {
        UserDefaults.standard.set(Array(enabledPrinterNames).sorted(), forKey: enabledDefaultsKey)
    }

    private func saveAdvertisementProfile() {
    }

    private func saveAdvertisementSettings() {
        if let data = try? JSONEncoder().encode(advertisementSettingsByPrinterName) {
            UserDefaults.standard.set(data, forKey: advertisementSettingsDefaultsKey)
        }
    }

    private func saveAppBehavior() {
        UserDefaults.standard.set(showMenuBarExtra, forKey: showMenuBarExtraDefaultsKey)
        UserDefaults.standard.set(showDockIcon, forKey: showDockIconDefaultsKey)
    }

    private func applyDockIconVisibility() {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func configureMainWindow(_ window: NSWindow) {
        window.title = "AirPrint Relay"
        window.setContentSize(NSSize(width: 960, height: 640))
        window.minSize = NSSize(width: 880, height: 560)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    private func focusExistingMainWindow() -> Bool {
        if let mainWindow, focus(window: mainWindow) {
            return true
        }

        if let candidate = NSApp.windows.first(where: { window in
            window.canBecomeKey && window.title == "AirPrint Relay"
        }) {
            mainWindow = candidate
            return focus(window: candidate)
        }

        return false
    }

    private func showAppKitMainWindow() {
        if let window = appKitMainWindowController?.window {
            mainWindow = window
            _ = focus(window: window)
            return
        }

        let rootView = ContentView()
            .environmentObject(self)
            .frame(minWidth: 880, minHeight: 560)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        configureMainWindow(window)
        window.center()

        let controller = NSWindowController(window: window)
        appKitMainWindowController = controller
        mainWindow = window
        controller.showWindow(nil)
        _ = focus(window: window)
    }

    private func focus(window: NSWindow) -> Bool {
        guard window.canBecomeKey else { return false }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func updateMenuBarExtraVisibility() {
        menuBarController.setVisible(showMenuBarExtra)
    }

    private func syncRelayAndAdvertising() {
        relayServer.sync(
            printers: printers,
            enabledPrinterNames: enabledPrinterNames,
            profile: advertisementProfile,
            settingsByPrinterName: advertisementSettingsByPrinterName
        )
        advertiser.sync(
            printers: printers,
            enabledPrinterNames: enabledPrinterNames,
            port: relayServer.port,
            profile: advertisementProfile,
            settingsByPrinterName: advertisementSettingsByPrinterName
        )
    }
}

@MainActor
private final class MenuBarController: NSObject {
    private weak var model: AppModel?
    private var statusItem: NSStatusItem?

    init(model: AppModel) {
        self.model = model
    }

    func setVisible(_ visible: Bool) {
        if visible {
            installIfNeeded()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func installIfNeeded() {
        guard statusItem == nil else {
            rebuildMenu()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "AirPrint Relay")
        item.button?.toolTip = "AirPrint Relay"
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show AirPrint Relay", action: #selector(showApp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Printers", action: #selector(refreshPrinters), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Printers Settings", action: #selector(openPrintersSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Logs", action: #selector(showLogs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let dockItem = NSMenuItem(title: "Show Dock Icon", action: #selector(toggleDockIcon), keyEquivalent: "")
        dockItem.state = model?.showDockIcon == true ? .on : .off
        menu.addItem(dockItem)

        menu.addItem(NSMenuItem(title: "Stop Advertising All", action: #selector(stopAdvertisingAll), keyEquivalent: ""))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit AirPrint Relay", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem?.menu = menu
    }

    @objc private func showApp() {
        model?.showMainWindow()
    }

    @objc private func refreshPrinters() {
        Task { @MainActor [weak model] in
            await model?.refreshPrinters()
        }
    }

    @objc private func openPrintersSettings() {
        model?.openPrintersSettings()
    }

    @objc private func showLogs() {
        model?.showLogs()
    }

    @objc private func showSettings() {
        model?.showSettings()
    }

    @objc private func stopAdvertisingAll() {
        model?.stopAdvertisingAll()
        rebuildMenu()
    }

    @objc private func toggleDockIcon() {
        guard let model else { return }
        model.setShowDockIcon(!model.showDockIcon)
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
