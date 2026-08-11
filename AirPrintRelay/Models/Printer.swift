import Foundation

struct Printer: Identifiable, Codable, Equatable {
    var id: String { name }

    let name: String
    var displayName: String
    var makeAndModel: String
    var location: String
    var deviceURI: String
    var state: String
    var iconPath: String
    var isShared: Bool
    var acceptsJobs: Bool
    var supportsColor: Bool
    var supportsDuplex: Bool
    var urf: String

    var serviceName: String {
        let base = displayName.isEmpty ? name : displayName
        let host = Host.current().localizedName ?? Host.current().name ?? "Mac"
        return "\(base) @ \(host)"
    }

    var relayPath: String {
        "ipp/\(name)"
    }

    var backendKind: PrinterBackendKind {
        PrinterBackendKind(deviceURI: deviceURI)
    }

    var stateLabel: String {
        let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "3":
            return "Idle"
        case "4":
            return "Processing"
        case "5":
            return "Stopped"
        default:
            return trimmed.isEmpty ? "Unknown" : trimmed.capitalized
        }
    }

    var warnings: [String] {
        var result: [String] = []
        if !acceptsJobs {
            result.append("The queue is not accepting jobs.")
        }
        if urf == "none" {
            result.append("Limited capability data found; using a conservative AirPrint profile.")
        }
        return result
    }
}

enum PrinterBackendKind: String, Codable, Equatable {
    case usb
    case ipp
    case lpd
    case smb
    case dnssd
    case socket
    case file
    case unknown

    init(deviceURI: String) {
        let lower = deviceURI.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("usb:") {
            self = .usb
        } else if lower.hasPrefix("ipp:") || lower.hasPrefix("ipps:") {
            self = .ipp
        } else if lower.hasPrefix("lpd:") {
            self = .lpd
        } else if lower.hasPrefix("smb:") {
            self = .smb
        } else if lower.hasPrefix("dnssd:") || lower.hasPrefix("mdns:") {
            self = .dnssd
        } else if lower.hasPrefix("socket:") || lower.hasPrefix("jetdirect:") {
            self = .socket
        } else if lower.hasPrefix("file:") {
            self = .file
        } else {
            self = .unknown
        }
    }

    var label: String {
        switch self {
        case .usb:
            return "USB"
        case .ipp:
            return "IPP"
        case .lpd:
            return "LPD"
        case .smb:
            return "SMB"
        case .dnssd:
            return "Bonjour"
        case .socket:
            return "Socket"
        case .file:
            return "File"
        case .unknown:
            return "Unknown backend"
        }
    }
}

struct AirPrintTXTRecord {
    let key: String
    let value: String

    var stringValue: String {
        "\(key)=\(value)"
    }
}
