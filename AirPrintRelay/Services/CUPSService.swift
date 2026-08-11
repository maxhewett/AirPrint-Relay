import Foundation

struct CUPSStatus: Equatable {
    var schedulerRunning: Bool = false
    var rawSummary: String = ""
}

enum CUPSService {
    static func loadPrinters() async -> [Printer] {
        let lpstat = await Shell.run("/usr/bin/lpstat", ["-p"])
        guard lpstat.succeeded, !lpstat.standardOutput.isEmpty else {
            return []
        }

        let names = lpstat.standardOutput
            .components(separatedBy: .newlines)
            .compactMap(printerName(fromStatusLine:))

        var printers: [Printer] = []
        for name in names {
            if let printer = await loadPrinter(named: name) {
                printers.append(printer)
            }
        }

        return printers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func status() async -> CUPSStatus {
        let schedulerResult = await Shell.run("/usr/bin/lpstat", ["-r"])

        return CUPSStatus(
            schedulerRunning: schedulerResult.standardOutput.localizedCaseInsensitiveContains("scheduler is running"),
            rawSummary: schedulerResult.standardOutput
        )
    }

    private static func loadPrinter(named name: String) async -> Printer? {
        async let optionsTask = Shell.run("/usr/bin/lpoptions", ["-p", name])
        async let capabilitiesTask = Shell.run("/usr/bin/lpoptions", ["-l", "-p", name])
        async let detailTask = Shell.run("/usr/bin/lpstat", ["-l", "-p", name])
        async let uriTask = Shell.run("/usr/bin/lpstat", ["-v", name])
        async let acceptingTask = Shell.run("/usr/bin/lpstat", ["-a", name])

        let optionsResult = await optionsTask
        let capabilitiesResult = await capabilitiesTask
        let detailResult = await detailTask
        let uriResult = await uriTask
        let acceptingResult = await acceptingTask

        let options = parseKeyValueOptions(optionsResult.standardOutput)
        let detail = detailResult.standardOutput
        let capabilities = capabilitiesResult.standardOutput
        let rawOptions = optionsResult.standardOutput

        let displayName = options["printer-info"].flatMap(nonEmpty)
            ?? detailValue(named: "Description", in: detail)
            ?? name
        let makeAndModel = options["printer-make-and-model"].flatMap(nonEmpty) ?? displayName
        let location = options["printer-location"].flatMap(nonEmpty)
            ?? detailValue(named: "Location", in: detail)
            ?? ""
        let state = stateDescription(from: options["printer-state"].flatMap(nonEmpty), detail: detail)
        let deviceURI = deviceURI(from: uriResult.standardOutput)
        let iconPath = printerIconPath(options: options, detail: detail)
        let isShared = options["printer-is-shared"] == "true"
            || rawOptions.contains("printer-is-shared=true")
            || detail.localizedCaseInsensitiveContains("shared: yes")
        let accepting = acceptingResult.standardOutput.localizedCaseInsensitiveContains("accepting requests")
            && !acceptingResult.standardOutput.localizedCaseInsensitiveContains("not accepting requests")
        let capabilitySummary = CapabilitySummary(from: capabilities)

        return Printer(
            name: name,
            displayName: displayName,
            makeAndModel: makeAndModel,
            location: location,
            deviceURI: deviceURI,
            state: state,
            iconPath: iconPath,
            isShared: isShared,
            acceptsJobs: accepting,
            supportsColor: capabilitySummary.supportsColor,
            supportsDuplex: capabilitySummary.supportsDuplex,
            urf: capabilitySummary.urf
        )
    }

    private static func printerName(fromStatusLine line: String) -> String? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "printer" else { return nil }
        return String(parts[1])
    }

    private static func parseKeyValueOptions(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var isReadingKey = true
        var quote: Character?

        func commit() {
            guard !key.isEmpty else { return }
            result[key] = value
            key = ""
            value = ""
            isReadingKey = true
            quote = nil
        }

        for character in string {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if isReadingKey {
                    key.append(character)
                } else {
                    value.append(character)
                }
                continue
            }

            if isReadingKey && key.isEmpty && character.isWhitespace {
                continue
            }

            if !isReadingKey && character.isWhitespace {
                commit()
                continue
            }

            switch character {
            case "'", "\"":
                quote = character
            case "=" where isReadingKey:
                isReadingKey = false
            default:
                if isReadingKey {
                    key.append(character)
                } else {
                    value.append(character)
                }
            }
        }

        commit()
        return result
    }

    private static func detailValue(named field: String, in details: String) -> String? {
        for line in details.components(separatedBy: .newlines) {
            guard let range = line.range(of: "\(field):", options: [.caseInsensitive]) else { continue }
            return nonEmpty(String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func stateDescription(from rawState: String?, detail: String) -> String {
        if let rawState {
            switch rawState {
            case "3":
                return "Idle"
            case "4":
                return "Processing"
            case "5":
                return "Stopped"
            default:
                return rawState
            }
        }

        let firstLine = detail.components(separatedBy: .newlines).first ?? ""
        if firstLine.localizedCaseInsensitiveContains("disabled") {
            return "Disabled"
        }
        if firstLine.localizedCaseInsensitiveContains("idle") {
            return "Idle"
        }
        if firstLine.localizedCaseInsensitiveContains("printing") || firstLine.localizedCaseInsensitiveContains("processing") {
            return "Processing"
        }
        return "Available"
    }

    private static func deviceURI(from lpstatOutput: String) -> String {
        guard let range = lpstatOutput.range(of: ":") else { return "" }
        return String(lpstatOutput[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func printerIconPath(options: [String: String], detail: String) -> String {
        let optionKeys = ["printer-icons", "printer-icon", "APPrinterIconPath"]
        for key in optionKeys {
            if let path = options[key].flatMap(resolvedIconPath) {
                return path
            }
        }

        guard let ppdPath = detailValue(named: "Interface", in: detail),
              let ppd = try? String(contentsOfFile: ppdPath, encoding: .utf8) else {
            return ""
        }

        for line in ppd.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            guard lower.contains("printericon") || lower.contains("apprintericon") else { continue }
            guard let value = ppdQuotedValue(from: line).flatMap(resolvedIconPath) else { continue }
            return value
        }

        return ""
    }

    private static func resolvedIconPath(from rawValue: String) -> String? {
        let firstValue = rawValue
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines)) ?? ""
        guard !firstValue.isEmpty else { return nil }

        if firstValue.hasPrefix("file://"), let url = URL(string: firstValue) {
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }

        if firstValue.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: firstValue) ? firstValue : nil
        }

        return nil
    }

    private static func ppdQuotedValue(from line: String) -> String? {
        guard let range = line.range(of: ":") else { return nil }
        let value = String(line[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return nonEmpty(value)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CapabilitySummary {
    var supportsColor = false
    var supportsDuplex = false
    var urf = "none"

    init(from lpoptions: String) {
        var codes = OrderedSet<String>()

        for line in lpoptions.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            let values = optionValues(from: line).lowercased()

            if lower.contains("colormodel") || lower.contains("brmonocolor") || lower.contains("print-color-mode") {
                if values.contains("rgb") || values.contains("color") || values.contains("cmyk") || values.contains("auto") {
                    supportsColor = true
                    codes.append("SRGB24")
                }
                if values.contains("gray") || values.contains("black") || values.contains("mono") {
                    codes.append("W8")
                }
            }

            if lower.contains("duplex") || lower.contains("sides/") {
                if values.contains("duplexnotumble") || values.contains("two-sided-long-edge") {
                    supportsDuplex = true
                    codes.append("DM2")
                }
                if values.contains("duplextumble") || values.contains("two-sided-short-edge") {
                    supportsDuplex = true
                    codes.append("DM3")
                }
                if values.contains("none") || values.contains("one-sided") {
                    codes.append("DM1")
                }
            }

            if lower.contains("cupsprintquality") || lower.contains("print-quality") {
                if values.contains("draft") { codes.append("PQ1") }
                if values.contains("normal") { codes.append("PQ2") }
                if values.contains("high") { codes.append("PQ3") }
                if values.contains("photo") || values.contains("best") { codes.append("PQ4") }
            }

            if lower.contains("pagesize") || lower.contains("media/") {
                appendMediaCodes(from: values, to: &codes)
            }
        }

        codes.append("CP1")
        codes.append("RS600")

        if codes.isEmpty {
            urf = "none"
        } else {
            urf = "V1.4,\(codes.joined(separator: ","))"
        }
    }

    private func appendMediaCodes(from lower: String, to codes: inout OrderedSet<String>) {
        if lower.contains("letter") { codes.append("MS_LETTER") }
        if lower.contains("legal") { codes.append("MS_LEGAL") }
        if lower.contains("a4") { codes.append("MS_A4") }
        if lower.contains("a3") { codes.append("MS_A3") }
        if lower.contains("a5") { codes.append("MS_A5") }
        if lower.contains("a6") { codes.append("MS_A6") }
        if lower.contains("b5") { codes.append("MS_B5") }
        if lower.contains("executive") { codes.append("MS_EXECUTIVE") }
        if lower.contains("tabloid") { codes.append("MS_TABLOID") }
        if lower.contains("4x6") { codes.append("MS_4X6") }
        if lower.contains("5x7") { codes.append("MS_5X7") }
    }

    private func optionValues(from line: String) -> String {
        guard let range = line.range(of: ":") else { return line }
        return String(line[range.upperBound...])
    }
}

private struct OrderedSet<Element: Hashable>: Sequence {
    private var elements: [Element] = []
    private var seen: Set<Element> = []

    var isEmpty: Bool {
        elements.isEmpty
    }

    mutating func append(_ element: Element) {
        guard seen.insert(element).inserted else { return }
        elements.append(element)
    }

    func joined(separator: String) -> String where Element == String {
        elements.joined(separator: separator)
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}
