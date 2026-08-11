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
        if deviceURI.hasPrefix("usb:") {
            result.append("USB queue detected. Jobs will be captured by AirPrint Relay and submitted locally to CUPS.")
        }
        if urf == "none" {
            result.append("Limited capability data found; using a conservative AirPrint profile.")
        }
        return result
    }
}

struct AirPrintTXTRecord {
    let key: String
    let value: String

    var stringValue: String {
        "\(key)=\(value)"
    }
}
