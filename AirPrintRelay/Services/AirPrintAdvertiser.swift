import CoreFoundation
import Foundation
import dnssd

struct AdvertisementStatus: Equatable {
    var isAdvertising: Bool
    var message: String
}

@MainActor
final class AirPrintAdvertiser: ObservableObject {
    @Published private(set) var statuses: [String: AdvertisementStatus] = [:]

    private var registrations: [String: BonjourRegistration] = [:]
    private var currentProfile = AdvertisementProfile()
    private var currentSettingsByPrinterName: [String: PrinterAdvertisementSettings] = [:]

    func sync(printers: [Printer], enabledPrinterNames: Set<String>, port: UInt16, profile: AdvertisementProfile, settingsByPrinterName: [String: PrinterAdvertisementSettings]) {
        let selectedPrinters = printers.filter { enabledPrinterNames.contains($0.name) && $0.acceptsJobs }
        let selectedNames = Set(selectedPrinters.map(\.name))
        let profileChanged = currentProfile != profile
        let settingsChanged = currentSettingsByPrinterName != settingsByPrinterName
        currentProfile = profile
        currentSettingsByPrinterName = settingsByPrinterName

        for name in registrations.keys where !selectedNames.contains(name) || profileChanged || settingsChanged {
            stopAdvertising(name)
        }

        for printer in selectedPrinters where registrations[printer.name] == nil {
            startAdvertising(printer, port: port, profile: profile, settings: settingsByPrinterName[printer.name] ?? PrinterAdvertisementSettings())
        }
    }

    func stopAll() {
        for name in Array(registrations.keys) {
            stopAdvertising(name)
        }
    }

    private func startAdvertising(_ printer: Printer, port: UInt16, profile: AdvertisementProfile, settings: PrinterAdvertisementSettings) {
        do {
            let registration = try BonjourRegistration(printer: printer, port: port, profile: profile, settings: settings) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success(let serviceName):
                        self?.statuses[printer.name] = AdvertisementStatus(
                            isAdvertising: true,
                            message: "Advertising as \(serviceName)"
                        )
                        AppLogStore.shared.info("Bonjour registered \(printer.name) as \(serviceName).")
                    case .failure(let error):
                        self?.statuses[printer.name] = AdvertisementStatus(
                            isAdvertising: false,
                            message: error.localizedDescription
                        )
                        AppLogStore.shared.error("Bonjour failed for \(printer.name): \(error.localizedDescription)")
                    }
                }
            }
            registrations[printer.name] = registration
            statuses[printer.name] = AdvertisementStatus(isAdvertising: true, message: "Advertising")
            AppLogStore.shared.info("Started Bonjour registration for \(printer.name) on port \(port) with path \(printer.relayPath). Formats: \(profile.documentFormats.joined(separator: ", ")).")
        } catch {
            statuses[printer.name] = AdvertisementStatus(isAdvertising: false, message: error.localizedDescription)
            AppLogStore.shared.error("Could not start Bonjour registration for \(printer.name): \(error.localizedDescription)")
        }
    }

    private func stopAdvertising(_ printerName: String) {
        registrations[printerName]?.invalidate()
        registrations[printerName] = nil
        statuses[printerName] = AdvertisementStatus(isAdvertising: false, message: "Not advertising")
        AppLogStore.shared.info("Stopped Bonjour registration for \(printerName).")
    }
}

private final class BonjourRegistration {
    typealias Callback = (Result<String, Error>) -> Void

    private var serviceRef: DNSServiceRef?
    private var source: DispatchSourceRead?
    private let callback: Callback

    init(printer: Printer, port: UInt16, profile: AdvertisementProfile, settings: PrinterAdvertisementSettings, callback: @escaping Callback) throws {
        self.callback = callback

        let txtData = AirPrintProfile.encodedTXTData(AirPrintProfile.txtRecords(for: printer, settings: settings, profile: profile))
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let networkPort = CFSwapInt16HostToBig(port)
        var ref: DNSServiceRef?

        let error: DNSServiceErrorType = txtData.withUnsafeBytes { buffer in
            DNSServiceRegister(
                &ref,
                DNSServiceFlags(0),
                UInt32(0),
                settings.serviceName(for: printer),
                "_ipp._tcp,_universal",
                "local.",
                nil,
                networkPort,
                UInt16(txtData.count),
                buffer.baseAddress,
                registrationReply,
                context
            )
        }

        guard error == kDNSServiceErr_NoError, let ref else {
            throw BonjourError.registrationFailed(error)
        }

        serviceRef = ref
        installReadSource(for: ref)
    }

    func invalidate() {
        source?.cancel()
        source = nil
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
        }
        serviceRef = nil
    }

    deinit {
        invalidate()
    }

    private func installReadSource(for ref: DNSServiceRef) {
        let fileDescriptor = DNSServiceRefSockFD(ref)
        guard fileDescriptor >= 0 else { return }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: .global(qos: .utility))
        readSource.setEventHandler { [weak self] in
            guard let self, let serviceRef = self.serviceRef else { return }
            let error = DNSServiceProcessResult(serviceRef)
            if error != kDNSServiceErr_NoError {
                self.callback(.failure(BonjourError.registrationFailed(error)))
            }
        }
        readSource.setCancelHandler { }
        source = readSource
        readSource.resume()
    }

    private let registrationReply: DNSServiceRegisterReply = { _, _, errorCode, name, _, _, context in
        guard let context else { return }
        let owner = Unmanaged<BonjourRegistration>.fromOpaque(context).takeUnretainedValue()

        if errorCode == kDNSServiceErr_NoError {
            owner.callback(.success(name.map { String(cString: $0) } ?? "printer"))
        } else {
            owner.callback(.failure(BonjourError.registrationFailed(errorCode)))
        }
    }
}

private enum BonjourError: LocalizedError {
    case registrationFailed(DNSServiceErrorType)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let code):
            return "Bonjour registration failed with DNS-SD error \(code)."
        }
    }
}
