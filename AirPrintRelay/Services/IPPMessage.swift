import Foundation

struct IPPRequest {
    let versionMajor: UInt8
    let versionMinor: UInt8
    let operationID: UInt16
    let requestID: UInt32
    let attributes: [String: [String]]
    let document: Data

    var jobName: String? {
        firstAttribute("job-name") ?? firstAttribute("document-name")
    }

    var documentFormat: String? {
        firstAttribute("document-format")
    }

    func firstAttribute(_ name: String) -> String? {
        attributes[name]?.first
    }
}

enum IPPOperation {
    static let printJob: UInt16 = 0x0002
    static let validateJob: UInt16 = 0x0004
    static let createJob: UInt16 = 0x0005
    static let sendDocument: UInt16 = 0x0006
    static let cancelJob: UInt16 = 0x0008
    static let getJobAttributes: UInt16 = 0x0009
    static let getJobs: UInt16 = 0x000A
    static let getPrinterAttributes: UInt16 = 0x000B
    static let closeJob: UInt16 = 0x003B
}

enum IPPStatus {
    static let successfulOK: UInt16 = 0x0000
    static let clientErrorBadRequest: UInt16 = 0x0400
    static let clientErrorNotFound: UInt16 = 0x0404
    static let serverErrorOperationNotSupported: UInt16 = 0x0501
    static let serverErrorInternalError: UInt16 = 0x0500
}

enum IPPMessage {
    static func parse(_ data: Data) throws -> IPPRequest {
        var reader = BinaryReader(data: data)
        let major = try reader.readUInt8()
        let minor = try reader.readUInt8()
        let operationID = try reader.readUInt16()
        let requestID = try reader.readUInt32()
        var attributes: [String: [String]] = [:]
        var currentName = ""

        while !reader.isAtEnd {
            let tag = try reader.readUInt8()
            if tag == 0x03 {
                let document = reader.remainingData()
                return IPPRequest(
                    versionMajor: major,
                    versionMinor: minor,
                    operationID: operationID,
                    requestID: requestID,
                    attributes: attributes,
                    document: document
                )
            }

            if tag <= 0x0F {
                continue
            }

            let nameLength = Int(try reader.readUInt16())
            let name: String
            if nameLength > 0 {
                name = try reader.readString(length: nameLength)
                currentName = name
            } else {
                name = currentName
            }

            let valueLength = Int(try reader.readUInt16())
            let valueData = try reader.readData(length: valueLength)
            let value = stringValue(tag: tag, data: valueData)
            attributes[name, default: []].append(value)
        }

        throw IPPError.missingEndTag
    }

    static func response(status: UInt16, requestID: UInt32, printer: Printer? = nil, profile: AdvertisementProfile = AdvertisementProfile(), settings: PrinterAdvertisementSettings = PrinterAdvertisementSettings(), printerURI: String? = nil, message: String? = nil, jobID: Int32? = nil, jobState: Int32 = 3, jobStateReason: String = "none", jobName: String? = nil) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt8(0x02)
        writer.writeUInt8(0x00)
        writer.writeUInt16(status)
        writer.writeUInt32(requestID)

        writer.writeUInt8(0x01)
        writer.writeAttribute(tag: 0x47, name: "attributes-charset", value: "utf-8")
        writer.writeAttribute(tag: 0x48, name: "attributes-natural-language", value: "en")
        if let message {
            writer.writeAttribute(tag: 0x41, name: "status-message", value: message)
        }

        if let printer {
            let resolvedPrinterURI = printerURI ?? "ipp://\(Host.current().localizedName ?? "Mac").local:\(IPPRelayServer.defaultPort)/\(printer.relayPath)"
            let formats = profile.documentFormats
            let advertisedName = settings.displayName(for: printer)
            let advertisedLocation = settings.location(for: printer)
            let advertisedModel = settings.model(for: printer)

            writer.writeUInt8(0x04)
            writer.writeAttribute(tag: 0x45, name: "printer-uri-supported", value: resolvedPrinterURI)
            writer.writeAttribute(tag: 0x44, name: "uri-authentication-supported", value: "none")
            writer.writeAttribute(tag: 0x44, name: "uri-security-supported", value: "none")
            writer.writeAttribute(tag: 0x42, name: "printer-name", value: advertisedName)
            writer.writeAttribute(tag: 0x41, name: "printer-info", value: advertisedName)
            writer.writeAttribute(tag: 0x41, name: "printer-location", value: advertisedLocation)
            writer.writeAttribute(tag: 0x41, name: "printer-make-and-model", value: advertisedModel)
            writer.writeAttribute(tag: 0x23, name: "printer-state", intValue: 3)
            writer.writeAttribute(tag: 0x41, name: "printer-state-message", value: "")
            writer.writeAttribute(tag: 0x44, name: "printer-state-reasons", value: "none")
            writer.writeAttribute(tag: 0x44, name: "printer-state-reason", value: "none")
            writer.writeAttribute(tag: 0x22, name: "printer-is-accepting-jobs", boolValue: printer.acceptsJobs)
            writer.writeAttribute(tag: 0x22, name: "printer-is-shared", boolValue: false)
            writer.writeAttribute(tag: 0x23, name: "printer-type", intValue: 4)
            writer.writeAttribute(tag: 0x45, name: "device-uri", value: printer.deviceURI)
            writer.writeAttribute(tag: 0x21, name: "printer-up-time", intValue: Int32(ProcessInfo.processInfo.systemUptime))
            writer.writeAttribute(tag: 0x49, name: "document-format-default", value: profile.defaultDocumentFormat)
            for (index, format) in formats.enumerated() {
                writer.writeAttribute(tag: 0x49, name: "document-format-supported", value: format, repeatName: index == 0)
            }
            writer.writeAttribute(tag: 0x22, name: "document-password-supported", boolValue: false)
            writer.writeAttribute(tag: 0x44, name: "compression-supported", value: "none")
            if profile.advertiseURF {
                writer.writeAttribute(tag: 0x44, name: "urf-supported", value: profile.urf.isEmpty ? printer.urf : profile.urf)
            }
            writer.writeAttribute(tag: 0x23, name: "queued-job-count", intValue: 0)
            writer.writeAttribute(tag: 0x44, name: "ipp-versions-supported", value: "1.1")
            writer.writeAttribute(tag: 0x44, name: "ipp-versions-supported", value: "2.0", repeatName: false)
            writer.writeAttribute(tag: 0x47, name: "charset-configured", value: "utf-8")
            writer.writeAttribute(tag: 0x47, name: "charset-supported", value: "utf-8")
            writer.writeAttribute(tag: 0x48, name: "natural-language-configured", value: "en")
            writer.writeAttribute(tag: 0x48, name: "generated-natural-language-supported", value: "en")
            writer.writeAttribute(tag: 0x21, name: "copies-default", intValue: 1)
            writer.writeAttribute(tag: 0x33, name: "copies-supported", rangeLower: 1, rangeUpper: 99)
            writer.writeAttribute(tag: 0x23, name: "orientation-requested-default", intValue: 3)
            writer.writeAttribute(tag: 0x23, name: "orientation-requested-supported", intValue: 3)
            writer.writeAttribute(tag: 0x23, name: "orientation-requested-supported", intValue: 4, repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "landscape-orientation-requested-preferred", intValue: 4)
            writer.writeAttribute(tag: 0x44, name: "media-default", value: "iso_a4_210x297mm")
            writer.writeAttribute(tag: 0x44, name: "media-supported", value: "iso_a4_210x297mm")
            writer.writeAttribute(tag: 0x44, name: "media-supported", value: "na_letter_8.5x11in", repeatName: false)
            writer.writeMediaCollection(name: "media-col-default", media: .a4)
            writer.writeMediaCollection(name: "media-col-ready", media: .a4)
            writer.writeMediaCollection(name: "media-col-database", media: .a4)
            writer.writeMediaCollection(name: "media-col-database", media: .letter, repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "media-col-supported", value: "media-size")
            writer.writeAttribute(tag: 0x44, name: "media-col-supported", value: "media-source", repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "media-col-supported", value: "media-type", repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "media-source-supported", value: "auto")
            writer.writeAttribute(tag: 0x44, name: "media-source-supported", value: "main", repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "media-source-ready", value: "main")
            writer.writeAttribute(tag: 0x44, name: "media-type-supported", value: "stationery")
            writer.writeAttribute(tag: 0x30, name: "printer-input-tray", value: "type=sheetFeedAutoRemovableTray;mediafeed=0;mediaxfeed=0;maxcapacity=250;level=100;status=0;name=main")
            writer.writeAttribute(tag: 0x44, name: "sides-default", value: "one-sided")
            writer.writeAttribute(tag: 0x44, name: "sides-supported", value: "one-sided")
            if profile.advertiseDuplex && printer.supportsDuplex {
                writer.writeAttribute(tag: 0x44, name: "sides-supported", value: "two-sided-long-edge", repeatName: false)
                writer.writeAttribute(tag: 0x44, name: "sides-supported", value: "two-sided-short-edge", repeatName: false)
            }
            writer.writeAttribute(tag: 0x22, name: "color-supported", boolValue: profile.advertiseColor && printer.supportsColor)
            writer.writeAttribute(tag: 0x44, name: "print-color-mode-default", value: profile.advertiseColor && printer.supportsColor ? "color" : "monochrome")
            writer.writeAttribute(tag: 0x44, name: "print-color-mode-supported", value: "monochrome")
            if profile.advertiseColor && printer.supportsColor {
                writer.writeAttribute(tag: 0x44, name: "print-color-mode-supported", value: "color", repeatName: false)
            }
            writer.writeAttribute(tag: 0x23, name: "finishings-default", intValue: 3)
            writer.writeAttribute(tag: 0x23, name: "finishings-supported", intValue: 3)
            writer.writeAttribute(tag: 0x44, name: "output-bin-default", value: "face-down")
            writer.writeAttribute(tag: 0x44, name: "output-bin-supported", value: "face-down")
            writer.writeAttribute(tag: 0x30, name: "printer-output-tray", value: "face-down: Main Output Tray")
            writer.writeAttribute(tag: 0x44, name: "identify-actions-supported", value: "none")
            writer.writeAttribute(tag: 0x22, name: "job-account-id-supported", boolValue: false)
            writer.writeAttribute(tag: 0x44, name: "jpeg-features-supported", value: "none")
            writer.writeAttribute(tag: 0x33, name: "jpeg-k-octets-supported", rangeLower: 0, rangeUpper: Int32.max)
            writer.writeAttribute(tag: 0x33, name: "jpeg-x-dimension-supported", rangeLower: 1, rangeUpper: 65535)
            writer.writeAttribute(tag: 0x33, name: "jpeg-y-dimension-supported", rangeLower: 1, rangeUpper: 65535)
            writer.writeAttribute(tag: 0x33, name: "pdf-k-octets-supported", rangeLower: 0, rangeUpper: Int32.max)
            writer.writeAttribute(tag: 0x23, name: "print-quality-default", intValue: 4)
            writer.writeAttribute(tag: 0x23, name: "print-quality-supported", intValue: 3)
            writer.writeAttribute(tag: 0x23, name: "print-quality-supported", intValue: 4, repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "print-quality-supported", intValue: 5, repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "print-scaling-default", value: "auto")
            writer.writeAttribute(tag: 0x44, name: "print-scaling-supported", value: "auto")
            writer.writeAttribute(tag: 0x44, name: "print-scaling-supported", value: "auto-fit", repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "print-scaling-supported", value: "fit", repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "print-scaling-supported", value: "fill", repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "print-scaling-supported", value: "none", repeatName: false)
            writer.writeAttribute(tag: 0x44, name: "printer-mandatory-job-attributes", value: "document-format")
            writer.writeAttribute(tag: 0x44, name: "pdl-override-supported", value: "attempted")
            writer.writeAttribute(tag: 0x45, name: "printer-more-info", value: resolvedPrinterURI)
            writer.writeAttribute(tag: 0x44, name: "job-presets-supported", value: "none")
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.printJob))
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.validateJob), repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.createJob), repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.sendDocument), repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.cancelJob), repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.getJobAttributes), repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.getJobs), repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.getPrinterAttributes), repeatName: false)
            writer.writeAttribute(tag: 0x23, name: "operations-supported", intValue: Int32(IPPOperation.closeJob), repeatName: false)
        }

        if let jobID {
            writer.writeUInt8(0x02)
            writer.writeAttribute(tag: 0x21, name: "job-id", intValue: jobID)
            let resolvedJobURI = printerURI.map { "\($0)?job-id=\(jobID)" } ?? "ipp://\(Host.current().localizedName ?? "Mac").local:\(IPPRelayServer.defaultPort)/jobs/\(jobID)"
            writer.writeAttribute(tag: 0x45, name: "job-uri", value: resolvedJobURI)
            writer.writeAttribute(tag: 0x42, name: "job-name", value: jobName ?? "AirPrint Relay Job")
            writer.writeAttribute(tag: 0x23, name: "job-state", intValue: jobState)
            writer.writeAttribute(tag: 0x44, name: "job-state-reasons", value: jobStateReason)
            writer.writeAttribute(tag: 0x21, name: "job-impressions-completed", intValue: jobState >= 9 ? 1 : 0)
        }

        writer.writeUInt8(0x03)
        return writer.data
    }

    private static func stringValue(tag: UInt8, data: Data) -> String {
        switch tag {
        case 0x21 where data.count == 4:
            let value = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return String(value)
        case 0x22 where data.count == 1:
            return data.first == 1 ? "true" : "false"
        default:
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

enum IPPError: Error {
    case truncated
    case missingEndTag
}

private struct BinaryReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool {
        offset >= data.count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw IPPError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(length: 2)
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(length: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readString(length: Int) throws -> String {
        String(data: try readData(length: length), encoding: .utf8) ?? ""
    }

    mutating func readData(length: Int) throws -> Data {
        guard offset + length <= data.count else { throw IPPError.truncated }
        let range = offset..<(offset + length)
        offset += length
        return data.subdata(in: range)
    }

    func remainingData() -> Data {
        guard offset < data.count else { return Data() }
        return data.subdata(in: offset..<data.count)
    }
}

private struct BinaryWriter {
    var data = Data()

    mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func writeUInt16(_ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func writeAttribute(tag: UInt8, name: String, value: String, repeatName: Bool = true) {
        let nameData = Data((repeatName ? name : "").utf8)
        let valueData = Data(value.utf8)
        writeUInt8(tag)
        writeUInt16(UInt16(nameData.count))
        data.append(nameData)
        writeUInt16(UInt16(valueData.count))
        data.append(valueData)
    }

    mutating func writeAttribute(tag: UInt8, name: String, intValue: Int32, repeatName: Bool = true) {
        let nameData = Data((repeatName ? name : "").utf8)
        writeUInt8(tag)
        writeUInt16(UInt16(nameData.count))
        data.append(nameData)
        writeUInt16(4)
        writeUInt32(UInt32(bitPattern: intValue))
    }

    mutating func writeAttribute(tag: UInt8, name: String, boolValue: Bool, repeatName: Bool = true) {
        let nameData = Data((repeatName ? name : "").utf8)
        writeUInt8(tag)
        writeUInt16(UInt16(nameData.count))
        data.append(nameData)
        writeUInt16(1)
        writeUInt8(boolValue ? 1 : 0)
    }

    mutating func writeAttribute(tag: UInt8, name: String, rangeLower: Int32, rangeUpper: Int32, repeatName: Bool = true) {
        let nameData = Data((repeatName ? name : "").utf8)
        writeUInt8(tag)
        writeUInt16(UInt16(nameData.count))
        data.append(nameData)
        writeUInt16(8)
        writeUInt32(UInt32(bitPattern: rangeLower))
        writeUInt32(UInt32(bitPattern: rangeUpper))
    }

    mutating func writeMediaCollection(name: String, media: IPPMedia, repeatName: Bool = true) {
        writeBeginCollection(name: name, repeatName: repeatName)
        writeCollectionMember(tag: 0x44, name: "media-key", value: media.keyword)
        writeCollectionMember(tag: 0x44, name: "media-size-name", value: media.keyword)
        writeCollectionMember(tag: 0x44, name: "media-source", value: "main")
        writeCollectionMember(tag: 0x44, name: "media-type", value: "stationery")
        writeCollectionMemberCollection(name: "media-size") {
            $0.writeCollectionMember(tag: 0x21, name: "x-dimension", intValue: media.xDimension)
            $0.writeCollectionMember(tag: 0x21, name: "y-dimension", intValue: media.yDimension)
        }
        writeEndCollection()
    }

    private mutating func writeBeginCollection(name: String, repeatName: Bool = true) {
        let nameData = Data((repeatName ? name : "").utf8)
        writeUInt8(0x34)
        writeUInt16(UInt16(nameData.count))
        data.append(nameData)
        writeUInt16(0)
    }

    private mutating func writeEndCollection() {
        writeUInt8(0x37)
        writeUInt16(0)
        writeUInt16(0)
    }

    private mutating func writeCollectionMemberName(_ name: String) {
        let valueData = Data(name.utf8)
        writeUInt8(0x4A)
        writeUInt16(0)
        writeUInt16(UInt16(valueData.count))
        data.append(valueData)
    }

    private mutating func writeCollectionMember(tag: UInt8, name: String, value: String) {
        writeCollectionMemberName(name)
        writeAttribute(tag: tag, name: "", value: value)
    }

    private mutating func writeCollectionMember(tag: UInt8, name: String, intValue: Int32) {
        writeCollectionMemberName(name)
        writeAttribute(tag: tag, name: "", intValue: intValue)
    }

    private mutating func writeCollectionMemberCollection(name: String, members: (inout BinaryWriter) -> Void) {
        writeCollectionMemberName(name)
        writeBeginCollection(name: "")
        members(&self)
        writeEndCollection()
    }
}

private struct IPPMedia {
    let keyword: String
    let xDimension: Int32
    let yDimension: Int32

    static let a4 = IPPMedia(keyword: "iso_a4_210x297mm", xDimension: 21000, yDimension: 29700)
    static let letter = IPPMedia(keyword: "na_letter_8.5x11in", xDimension: 21590, yDimension: 27940)
}
