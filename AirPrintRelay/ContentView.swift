import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environmentObject(model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            PrinterListView()
                .environmentObject(model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    Task { await model.refreshPrinters() }
                } label: {
                    Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("Refresh CUPS printers")

                Button {
                    model.openPrintersSettings()
                } label: {
                    Label("Printers", systemImage: "printer")
                }
                .help("Open macOS Printers settings")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.stopAdvertisingAll()
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .disabled(model.enabledPrinterNames.isEmpty)
                .help("Stop advertising every printer")

                Button {
                    model.presentLogs()
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
                .help("Show AirPrint Relay logs")

                Button {
                    model.presentSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Show settings")
            }
        }
        .sheet(isPresented: $model.isShowingLogs) {
            LogPanelView(logs: model.logs)
                .frame(minWidth: 720, minHeight: 460)
        }
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsPanelView()
                .environmentObject(model)
                .frame(minWidth: 660, minHeight: 620)
        }
        .background {
            WindowAccessor { window in
                model.registerMainWindow(window)
            }
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AirPrint Relay")
                    .font(.title2.weight(.semibold))
                Text(model.lastRefreshMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HealthRow(title: "CUPS", isHealthy: model.cupsStatus.schedulerRunning)
                HealthRow(title: "IPP Listener", isHealthy: model.relayServer.isRunning, value: ":\(model.relayServer.port)")
                HealthRow(title: "Advertised", isHealthy: advertisedCount > 0, value: "\(advertisedCount)")
            }

            Divider()

            SidebarMetric(title: "Queues", value: "\(model.printers.count)", systemImage: "list.bullet.rectangle")
            SidebarMetric(title: "Enabled", value: "\(model.enabledPrinterNames.count)", systemImage: "antenna.radiowaves.left.and.right")
            SidebarMetric(title: "Jobs", value: "\(totalJobs)", systemImage: "doc.on.doc")

            Spacer()
        }
        .padding(20)
    }

    private var advertisedCount: Int {
        model.advertiser.statuses.values.filter(\.isAdvertising).count
    }

    private var totalJobs: Int {
        model.relayServer.statsByPrinterName.values.reduce(0) { $0 + $1.totalJobs }
    }
}

private struct SettingsPanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings")
                        .font(.title3.weight(.semibold))
                    Text("App behavior and iOS printing helpers")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.shortcutQRCodeURL, forType: .string)
                } label: {
                    Label("Copy Shortcut", systemImage: "doc.on.doc")
                }

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsSection(title: "App Behavior", systemImage: "macwindow") {
                        Toggle("Open at Login", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        Toggle("Show Menu Bar Item", isOn: Binding(
                            get: { model.showMenuBarExtra },
                            set: { model.setShowMenuBarExtra($0) }
                        ))
                        Toggle("Show Dock Icon", isOn: Binding(
                            get: { model.showDockIcon },
                            set: { model.setShowDockIcon($0) }
                        ))
                        Text("At least one of these stays enabled so AirPrint Relay remains reachable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    SettingsSection(title: "Software Updates", systemImage: "arrow.down.circle") {
                        UpdateSettingsView(updater: model.updater)
                    }

                    SettingsSection(title: "iOS Image Printing", systemImage: "photo.on.rectangle") {
                        HStack(alignment: .top, spacing: 22) {
                            VStack(alignment: .center, spacing: 12) {
                                QRCodeView(text: model.shortcutQRCodeURL)
                                    .frame(width: 190, height: 190)
                                    .padding(12)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(.quaternary, lineWidth: 1)
                                    )

                                Text(model.shortcutQRCodeURL)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .frame(width: 240)
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Scan this QR code on an iPhone or iPad to install the Print Safari Image shortcut.")
                                    .font(.callout)
                                Text("It makes printing images from iOS Safari easier when the normal long-press share flow does not expose Print directly.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        DisclosureGroup("Make your own shortcut") {
                            VStack(alignment: .leading, spacing: 8) {
                                ShortcutStep(number: 1, text: "Name it Print Safari Image.")
                                ShortcutStep(number: 2, text: "Enable Show in Share Sheet.")
                                ShortcutStep(number: 3, text: "Accepted input: Images, URLs, Safari web pages.")
                                ShortcutStep(number: 4, text: "Add Get Images from Shortcut Input.")
                                ShortcutStep(number: 5, text: "If Images has any value, Print Images.")
                                ShortcutStep(number: 6, text: "Otherwise Get Contents of URL from Shortcut Input, then Print the result.")
                                ShortcutStep(number: 7, text: "Keep Show Print Dialog on for the first run and select the AirPrint Relay printer.")
                            }
                            .padding(.top, 6)
                        }

                        Text("Safari long-press image sharing may pass either image bytes or an image URL. The shortcut handles both.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
    }
}

private struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Channel", selection: Binding(
                get: { updater.selectedChannel },
                set: { updater.setUpdateChannel($0) }
            )) {
                ForEach(AppUpdater.UpdateChannel.allCases) { channel in
                    Text(channel.label).tag(channel)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }
            ))
            .disabled(!updater.isConfigured)

            Toggle("Download updates automatically", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.setAutomaticallyDownloadsUpdates($0) }
            ))
            .disabled(!updater.isConfigured)

            HStack {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(!updater.canCheckForUpdates)

                if let releaseNotesURL = updater.releaseNotesURL {
                    Button {
                        NSWorkspace.shared.open(releaseNotesURL)
                    } label: {
                        Label("Release Notes", systemImage: "doc.text")
                    }
                    .disabled(!updater.isConfigured)
                }
            }
            .buttonStyle(.bordered)

            Text(updaterStatusText)
                .font(.caption)
                .foregroundStyle(updater.isConfigured ? Color.secondary : Color.orange)
                .textSelection(.enabled)
        }
    }

    private var updaterStatusText: String {
        if updater.isConfigured {
            return "Sparkle feed: \(updater.feedURLString)"
        }

        if updater.feedURLString.isEmpty {
            return "Sparkle is not configured: SUFeedURL is missing."
        }

        if !updater.hasPublicKey {
            return "Sparkle feed is set to \(updater.feedURLString), but SUPublicEDKey still needs the ShipHook/Sparkle public key."
        }

        return "Sparkle is not configured."
    }
}

private struct ShortcutStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Text(text)
                .font(.callout)
        }
    }
}

private struct QRCodeView: View {
    let text: String

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = qrImage {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
        }
    }

    private var qrImage: NSImage? {
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
}

private struct LogPanelView: View {
    @ObservedObject var logs: AppLogStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Logs")
                        .font(.title3.weight(.semibold))
                    Text("\(logs.entries.count) entr\(logs.entries.count == 1 ? "y" : "ies")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    logs.copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    logs.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }

                Button {
                    dismiss()
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
            .padding()

            Divider()

            if logs.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No log entries yet")
                        .font(.headline)
                    Text("Refresh printers or toggle a queue to generate diagnostics.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(logs.entries) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .onChange(of: logs.entries.count) { _ in
                        if let last = logs.entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

private struct LogEntryRow: View {
    let entry: AppLogEntry

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.formatter.string(from: entry.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.level.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(levelColor)
                Spacer()
            }
            Text(entry.message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug:
            return .secondary
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct PrinterListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.printers.isEmpty {
                EmptyStateView()
            } else {
                List(model.printers) { printer in
                    PrinterRowView(printer: printer)
                        .environmentObject(model)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                .listStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Printers")
                    .font(.title3.weight(.semibold))
                Text("Selected queues are advertised through AirPrint Relay and submitted locally to CUPS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

private struct PrinterRowView: View {
    @EnvironmentObject private var model: AppModel
    let printer: Printer
    @State private var isEditingListing = false
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PrinterIconView(printer: printer, isActive: canAdvertise)

                VStack(alignment: .leading, spacing: 3) {
                    Text(printer.displayName)
                        .font(.headline)
                    Text("\(printer.makeAndModel) - \(printer.backendKind.label) - \(printer.stateLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                StatusPill(status: status)

                Toggle("", isOn: Binding(
                    get: { model.enabledPrinterNames.contains(printer.name) },
                    set: { model.setEnabled($0, for: printer) }
                ))
                .toggleStyle(.switch)
                .disabled(!printer.acceptsJobs)
                .labelsHidden()
            }

            JobStatsStrip(stats: model.relayServer.statsByPrinterName[printer.name] ?? PrinterJobStats())

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("AirPrint Listing", systemImage: "tag")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        isEditingListing.toggle()
                    } label: {
                        Label(isEditingListing ? "Done" : "Edit", systemImage: isEditingListing ? "checkmark" : "pencil")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }

                if isEditingListing {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            ListingField(title: "Name", text: listingBinding(\.name))
                            ListingField(title: "Location", text: listingBinding(\.location))
                            ListingField(title: "Model", text: listingBinding(\.model))
                        }
                    }
                } else {
                    ListingSummaryView(printer: printer, settings: model.advertisementSettings(for: printer))
                }
            }

            DisclosureGroup(isExpanded: $isShowingDetails) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        DetailLabel(title: "Queue", value: printer.name)
                        DetailLabel(title: "Path", value: printer.relayPath)
                        DetailLabel(title: "Formats", value: model.advertisementProfile.documentFormats.joined(separator: ", "))
                    }
                    GridRow {
                        DetailLabel(title: "Backend", value: printer.backendKind.label)
                        DetailLabel(title: "Device", value: printer.deviceURI)
                        DetailLabel(title: "CUPS Sharing", value: printer.isShared ? "On" : "Off")
                    }
                    GridRow {
                        DetailLabel(title: "Color", value: printer.supportsColor ? "Yes" : "No")
                        DetailLabel(title: "Duplex", value: printer.supportsDuplex ? "Yes" : "No")
                        DetailLabel(title: "Driver Icon", value: printer.iconPath.isEmpty ? "Fallback" : "Driver supplied")
                    }
                }
                .font(.callout)
                .padding(.top, 6)
            } label: {
                Text("Queue Details")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !printer.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(printer.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(14)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private var canAdvertise: Bool {
        printer.acceptsJobs
    }

    private var status: AdvertisementStatus {
        if let status = model.advertiser.statuses[printer.name] {
            return status
        }
        if !printer.acceptsJobs {
            return AdvertisementStatus(isAdvertising: false, message: "Not accepting jobs")
        }
        return AdvertisementStatus(isAdvertising: false, message: "Ready")
    }

    private func listingBinding(_ keyPath: WritableKeyPath<PrinterAdvertisementSettings, String>) -> Binding<String> {
        Binding {
            model.advertisementSettings(for: printer)[keyPath: keyPath]
        } set: { value in
            var settings = model.advertisementSettings(for: printer)
            settings[keyPath: keyPath] = value
            model.setAdvertisementSettings(settings, for: printer)
        }
    }
}

private struct PrinterIconView: View {
    let printer: Printer
    let isActive: Bool

    var body: some View {
        ZStack {
            if let image = driverImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "printer.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
        }
        .frame(width: 42, height: 42)
    }

    private var driverImage: NSImage? {
        guard !printer.iconPath.isEmpty else { return nil }
        if let image = NSImage(contentsOfFile: printer.iconPath) {
            image.size = NSSize(width: 42, height: 42)
            return image
        }

        let image = NSWorkspace.shared.icon(forFile: printer.iconPath)
        return image.isValid ? image : nil
    }
}

private struct JobStatsStrip: View {
    let stats: PrinterJobStats

    var body: some View {
        HStack(spacing: 14) {
            StatItem(title: "Jobs", value: "\(stats.totalJobs)")
            StatItem(title: "Done", value: "\(stats.completedJobs)")
            StatItem(title: "Failed", value: "\(stats.failedJobs)", isWarning: stats.failedJobs > 0)
            StatItem(title: "Active", value: "\(stats.activeJobs)")

            if stats.hasJobs {
                Divider()
                    .frame(height: 18)
                Text(lastJobText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var lastJobText: String {
        let title = stats.lastJobTitle.isEmpty ? "Untitled" : stats.lastJobTitle
        if let cupsID = stats.lastCUPSJobID {
            return "Last: \(title) - CUPS \(cupsID)"
        }
        return "Last: \(title)"
    }
}

private struct StatItem: View {
    let title: String
    let value: String
    var isWarning = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.tertiary)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(isWarning ? .red : .secondary)
        }
        .font(.caption.monospacedDigit())
    }
}

private struct ListingSummaryView: View {
    let printer: Printer
    let settings: PrinterAdvertisementSettings

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                DetailLabel(title: "Name", value: settings.displayName(for: printer))
                DetailLabel(title: "Location", value: settings.location(for: printer))
                DetailLabel(title: "Model", value: settings.model(for: printer))
            }
        }
        .font(.callout)
    }
}

private struct ListingField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 220)
        }
    }
}

private struct HealthRow: View {
    let title: String
    let isHealthy: Bool
    var value: String?

    var body: some View {
        HStack {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isHealthy ? .green : .red)
            Text(title)
            Spacer()
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct SidebarMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private struct StatusPill: View {
    let status: AdvertisementStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.isAdvertising ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(status.message)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .frame(maxWidth: 240, alignment: .trailing)
    }
}

private struct DetailLabel: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value.isEmpty ? "Unknown" : value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: 260, alignment: .leading)
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "printer")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No CUPS printers found")
                .font(.title3.weight(.semibold))
            Text("Add a printer in macOS, make sure the queue accepts jobs, then refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
