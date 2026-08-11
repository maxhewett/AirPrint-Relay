import Foundation

struct AdvertisementProfile: Codable, Equatable {
    var advertisePDF = true
    var advertiseJPEG = true
    var advertiseURF = true
    var advertisePWGRaster = false
    var advertiseColor = true
    var advertiseDuplex = true
    var urf = "V1.4,SRGB24,W8,CP1,RS600"

    var documentFormats: [String] {
        var formats: [String] = []
        if advertisePDF {
            formats.append("application/pdf")
        }
        if advertiseJPEG {
            formats.append("image/jpeg")
        }
        if advertiseURF {
            formats.append("image/urf")
        }
        if advertisePWGRaster {
            formats.append("image/pwg-raster")
        }
        return formats.isEmpty ? ["application/pdf"] : formats
    }

    var defaultDocumentFormat: String {
        documentFormats.first ?? "application/pdf"
    }
}

struct PrinterAdvertisementSettings: Codable, Equatable {
    var name = ""
    var location = ""
    var model = ""

    func displayName(for printer: Printer) -> String {
        sanitized(name).isEmpty ? printer.displayName : sanitized(name)
    }

    func location(for printer: Printer) -> String {
        sanitized(location).isEmpty ? printer.location : sanitized(location)
    }

    func model(for printer: Printer) -> String {
        sanitized(model).isEmpty ? printer.makeAndModel : sanitized(model)
    }

    func serviceName(for printer: Printer) -> String {
        "\(displayName(for: printer)) @ \(Host.current().localizedName ?? Host.current().name ?? "Mac")"
    }

    private func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AirPrintProfile {
    static func txtRecords(for printer: Printer, settings: PrinterAdvertisementSettings, profile: AdvertisementProfile) -> [AirPrintTXTRecord] {
        let advertisedName = sanitized(settings.displayName(for: printer))
        let model = sanitized(settings.model(for: printer).isEmpty ? advertisedName : settings.model(for: printer))
        let location = sanitized(settings.location(for: printer))
        let note: String
        if location.isEmpty {
            note = "Relayed by \(Host.current().localizedName ?? "Mac")"
        } else {
            note = "\(location) via \(Host.current().localizedName ?? "Mac")"
        }

        var records: [AirPrintTXTRecord] = [
            .init(key: "txtvers", value: "1"),
            .init(key: "qtotal", value: "1"),
            .init(key: "rp", value: printer.relayPath),
            .init(key: "ty", value: model),
            .init(key: "product", value: "(\(model))"),
            .init(key: "adminurl", value: "ipp://\(Host.current().localizedName ?? "Mac").local:\(IPPRelayServer.defaultPort)/\(printer.relayPath)"),
            .init(key: "note", value: sanitized(note)),
            .init(key: "pdl", value: profile.documentFormats.joined(separator: ",")),
            .init(key: "Color", value: profile.advertiseColor && printer.supportsColor ? "T" : "F"),
            .init(key: "Duplex", value: profile.advertiseDuplex && printer.supportsDuplex ? "T" : "F"),
            .init(key: "Copies", value: "T"),
            .init(key: "Collate", value: "F"),
            .init(key: "Staple", value: "F"),
            .init(key: "Punch", value: "F"),
            .init(key: "Bind", value: "F"),
            .init(key: "Sort", value: "F"),
            .init(key: "Fax", value: "F"),
            .init(key: "Scan", value: "F"),
            .init(key: "Transparent", value: "T"),
            .init(key: "Binary", value: "T"),
            .init(key: "TBCP", value: "F")
        ]

        if profile.advertiseURF {
            records.append(.init(key: "URF", value: sanitized(profile.urf.isEmpty ? printer.urf : profile.urf)))
        }

        return records
    }

    static func encodedTXTData(_ records: [AirPrintTXTRecord]) -> Data {
        var data = Data()
        for record in records {
            let bytes = Array(record.stringValue.utf8.prefix(255))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
