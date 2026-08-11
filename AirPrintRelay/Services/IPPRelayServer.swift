import Foundation
import Network
import CryptoKit

@MainActor
final class IPPRelayServer: ObservableObject {
    nonisolated static let defaultPort: UInt16 = 8631

    @Published private(set) var isRunning = false
    @Published private(set) var statsByPrinterName: [String: PrinterJobStats] = [:]

    let port = defaultPort

    private var listener: NWListener?
    private var routesByPath: [String: IPPRoute] = [:]
    private var pendingJobs: [Int32: PendingIPPJob] = [:]
    private var jobRecords: [Int32: IPPJobRecord] = [:]
    private var recentDocumentFingerprints: [String: Int32] = [:]
    private var nextJobID: Int32 = 1
    private let queue = DispatchQueue(label: "com.maxhewett.AirPrint-Relay.ipp-server")

    init() {
        start()
    }

    func sync(printers: [Printer], enabledPrinterNames: Set<String>, profile: AdvertisementProfile, settingsByPrinterName: [String: PrinterAdvertisementSettings]) {
        routesByPath = Dictionary(
            uniqueKeysWithValues: printers
                .filter { enabledPrinterNames.contains($0.name) && $0.acceptsJobs }
                .map {
                    (
                        "/\($0.relayPath)",
                        IPPRoute(
                            printer: $0,
                            profile: profile,
                            settings: settingsByPrinterName[$0.name] ?? PrinterAdvertisementSettings()
                        )
                    )
                }
        )
        AppLogStore.shared.debug("IPP routes: \(routesByPath.keys.sorted().joined(separator: ", ")). Formats: \(profile.documentFormats.joined(separator: ", ")).")
    }

    private func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    let routes = self?.routesByPath ?? [:]
                    self?.handle(connection: connection, routes: routes)
                }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        AppLogStore.shared.info("IPP listener ready on port \(self.port).")
                    case .failed(let error):
                        self.isRunning = false
                        AppLogStore.shared.error("IPP listener failed: \(error.localizedDescription)")
                    case .cancelled:
                        self.isRunning = false
                        AppLogStore.shared.info("IPP listener stopped.")
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            AppLogStore.shared.error("Could not start IPP listener on port \(port): \(error.localizedDescription)")
        }
    }

    private func handle(connection: NWConnection, routes: [String: IPPRoute]) {
        let parser = HTTPMessageAccumulator()
        AppLogStore.shared.debug("IPP connection accepted from \(connection.endpoint). Routes available: \(routes.keys.sorted().joined(separator: ", ")).")
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Task { @MainActor in
                    AppLogStore.shared.error("IPP connection failed: \(error.localizedDescription)")
                }
            }
        }
        connection.start(queue: queue)
        receive(on: connection, parser: parser, routes: routes)
    }

    nonisolated private func receive(on connection: NWConnection, parser: HTTPMessageAccumulator, routes: [String: IPPRoute]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                parser.append(data)
                if let summary = parser.headerSummary, !parser.didLogHeaders {
                    parser.didLogHeaders = true
                    Task { @MainActor in
                        AppLogStore.shared.debug("IPP HTTP request headers: \(summary)")
                    }
                }
                if parser.shouldSendContinue {
                    parser.markContinueSent()
                    self?.sendContinue(on: connection)
                }
            }

            if let error {
                Task { @MainActor in
                    AppLogStore.shared.error("IPP receive failed: \(error.localizedDescription)")
                }
                connection.cancel()
                return
            }

            if let request = parser.request {
                self?.respond(to: request, on: connection, routes: routes)
                return
            }

            if isComplete {
                Task { @MainActor in
                    AppLogStore.shared.warning("IPP connection ended before a complete HTTP request was parsed. Bytes received: \(parser.receivedByteCount).")
                }
                connection.cancel()
                return
            }

            self?.receive(on: connection, parser: parser, routes: routes)
        }
    }

    nonisolated private func respond(to httpRequest: HTTPRequest, on connection: NWConnection, routes: [String: IPPRoute]) {
        guard httpRequest.method == "POST" else {
            Task { @MainActor in
                AppLogStore.shared.warning("Rejected non-POST IPP HTTP request: \(httpRequest.method) \(httpRequest.path).")
            }
            sendHTTP(status: "405 Method Not Allowed", body: Data(), on: connection)
            return
        }

        guard let route = routes[httpRequest.normalizedPath] else {
            Task { @MainActor in
                AppLogStore.shared.warning("Unknown IPP path \(httpRequest.path). Known paths: \(routes.keys.sorted().joined(separator: ", ")).")
            }
            let response = IPPMessage.response(status: IPPStatus.clientErrorNotFound, requestID: 1, message: "Unknown printer path.")
            sendIPP(response, on: connection)
            return
        }

        let printer = route.printer

        let ippRequest: IPPRequest
        do {
            ippRequest = try IPPMessage.parse(httpRequest.body)
        } catch {
            Task { @MainActor in
                AppLogStore.shared.error("Could not parse IPP payload for \(httpRequest.path): \(error). HTTP body bytes: \(httpRequest.body.count).")
            }
            let response = IPPMessage.response(status: IPPStatus.clientErrorBadRequest, requestID: 1, message: "Could not parse IPP request.")
            sendIPP(response, on: connection)
            return
        }

        Task { @MainActor in
            let requestedAttributes = ippRequest.attributes["requested-attributes"]?.joined(separator: ", ") ?? "none"
            AppLogStore.shared.info("IPP operation \(ippRequest.operationID) for \(printer.name), request=\(ippRequest.requestID), document bytes=\(ippRequest.document.count), format=\(ippRequest.documentFormat ?? "unspecified"), requested=\(requestedAttributes).")
        }
        let printerURI = httpRequest.printerURI(port: Self.defaultPort)
        Task { @MainActor in
            AppLogStore.shared.debug("Resolved printer URI for \(printer.name): \(printerURI).")
        }
        Task {
            await self.handle(ippRequest: ippRequest, printer: printer, profile: route.profile, settings: route.settings, printerURI: printerURI, connection: connection)
        }
    }

    nonisolated private func handle(ippRequest: IPPRequest, printer: Printer, profile: AdvertisementProfile, settings: PrinterAdvertisementSettings, printerURI: String, connection: NWConnection) async {
        switch ippRequest.operationID {
        case IPPOperation.getPrinterAttributes, IPPOperation.validateJob, IPPOperation.getJobs:
            let response = IPPMessage.response(status: IPPStatus.successfulOK, requestID: ippRequest.requestID, printer: printer, profile: profile, settings: settings, printerURI: printerURI)
            sendIPP(response, on: connection)

        case IPPOperation.getJobAttributes:
            let jobID = Int32(ippRequest.firstAttribute("job-id") ?? "") ?? 0
            let record = await MainActor.run { jobRecords[jobID] }
            let response = IPPMessage.response(
                status: record == nil ? IPPStatus.clientErrorNotFound : IPPStatus.successfulOK,
                requestID: ippRequest.requestID,
                printer: printer,
                profile: profile,
                settings: settings,
                printerURI: printerURI,
                message: record == nil ? "Unknown job." : record?.message,
                jobID: record?.id ?? jobID,
                jobState: record?.state ?? 9,
                jobStateReason: record?.stateReason ?? "job-completed-successfully",
                jobName: record?.title
            )
            sendIPP(response, on: connection)

        case IPPOperation.cancelJob:
            let jobID = Int32(ippRequest.firstAttribute("job-id") ?? "") ?? 0
            await MainActor.run {
                if var record = jobRecords[jobID] {
                    record.state = 7
                    record.stateReason = "job-canceled-by-user"
                    record.message = "Job canceled."
                    record.completedAt = Date()
                    jobRecords[jobID] = record
                    refreshJobStats()
                }
            }
            let response = IPPMessage.response(status: IPPStatus.successfulOK, requestID: ippRequest.requestID, printer: printer, profile: profile, settings: settings, printerURI: printerURI, message: "Job canceled.", jobID: jobID, jobState: 7, jobStateReason: "job-canceled-by-user")
            sendIPP(response, on: connection)

        case IPPOperation.closeJob:
            let jobID = Int32(ippRequest.firstAttribute("job-id") ?? "") ?? 0
            let record = await MainActor.run { jobRecords[jobID] }
            let response = IPPMessage.response(
                status: record == nil ? IPPStatus.clientErrorNotFound : IPPStatus.successfulOK,
                requestID: ippRequest.requestID,
                printer: printer,
                profile: profile,
                settings: settings,
                printerURI: printerURI,
                message: record == nil ? "Unknown job." : "Job closed.",
                jobID: record?.id ?? jobID,
                jobState: record?.state ?? 9,
                jobStateReason: record?.stateReason ?? "job-completed-successfully",
                jobName: record?.title
            )
            sendIPP(response, on: connection)

        case IPPOperation.createJob:
            let jobID = await MainActor.run { () -> Int32 in
                let id = nextJobID
                nextJobID += 1
                pendingJobs[id] = PendingIPPJob(printer: printer, documentFormat: ippRequest.documentFormat, title: ippRequest.jobName)
                AppLogStore.shared.info("Created pending IPP job \(id) for \(printer.name).")
                return id
            }
            let response = IPPMessage.response(status: IPPStatus.successfulOK, requestID: ippRequest.requestID, printer: printer, profile: profile, settings: settings, printerURI: printerURI, message: "Job created.", jobID: jobID)
            sendIPP(response, on: connection)

        case IPPOperation.sendDocument:
            guard !ippRequest.document.isEmpty else {
                let response = IPPMessage.response(status: IPPStatus.clientErrorBadRequest, requestID: ippRequest.requestID, message: "Send-Document did not include a document.")
                sendIPP(response, on: connection)
                return
            }
            let jobID = Int32(ippRequest.firstAttribute("job-id") ?? "") ?? 0
            let existing = await MainActor.run { jobRecords[jobID] }
            if let existing {
                await MainActor.run {
                    AppLogStore.shared.warning("Ignoring duplicate Send-Document for IPP job \(jobID); current state=\(existing.state), CUPS=\(existing.cupsJobID.map { "job \($0)" } ?? "pending").")
                }
                let response = IPPMessage.response(status: IPPStatus.successfulOK, requestID: ippRequest.requestID, printer: printer, profile: profile, settings: settings, printerURI: printerURI, message: "Job already accepted.", jobID: jobID, jobState: existing.state, jobStateReason: existing.stateReason, jobName: existing.title)
                sendIPP(response, on: connection)
                return
            }
            let pending = await MainActor.run { pendingJobs[jobID] }
            await submitDocument(
                ippRequest.document,
                to: pending?.printer ?? printer,
                documentFormat: ippRequest.documentFormat ?? pending?.documentFormat,
                title: ippRequest.jobName ?? pending?.title,
                requestID: ippRequest.requestID,
                ippJobID: jobID == 0 ? nil : jobID,
                printerURI: printerURI,
                profile: profile,
                settings: settings,
                connection: connection
            )

        case IPPOperation.printJob:
            guard !ippRequest.document.isEmpty else {
                let response = IPPMessage.response(status: IPPStatus.clientErrorBadRequest, requestID: ippRequest.requestID, message: "Print-Job did not include a document.")
                sendIPP(response, on: connection)
                return
            }

            await submitDocument(
                ippRequest.document,
                to: printer,
                documentFormat: ippRequest.documentFormat,
                title: ippRequest.jobName,
                requestID: ippRequest.requestID,
                ippJobID: nil,
                printerURI: printerURI,
                profile: profile,
                settings: settings,
                connection: connection
            )
        default:
            let response = IPPMessage.response(status: IPPStatus.serverErrorOperationNotSupported, requestID: ippRequest.requestID, message: "Unsupported IPP operation \(ippRequest.operationID).")
            sendIPP(response, on: connection)
        }
    }

    nonisolated private func submitDocument(_ document: Data, to printer: Printer, documentFormat: String?, title: String?, requestID: UInt32, ippJobID: Int32?, printerURI: String, profile: AdvertisementProfile, settings: PrinterAdvertisementSettings, connection: NWConnection) async {
        let fingerprint = documentFingerprint(document, printerName: printer.name)
        let jobID = await MainActor.run { () -> Int32 in
            if let ippJobID {
                return ippJobID
            }
            if let recentJobID = recentDocumentFingerprints[fingerprint] {
                return recentJobID
            }
            let id = nextJobID
            nextJobID += 1
            return id
        }

        if let duplicate = await MainActor.run(body: { jobRecords[jobID] ?? recentDocumentFingerprints[fingerprint].flatMap { jobRecords[$0] } }) {
            await MainActor.run {
                AppLogStore.shared.warning("Ignoring duplicate document for \(printer.name); current state=\(duplicate.state), CUPS=\(duplicate.cupsJobID.map { "job \($0)" } ?? "pending").")
            }
            let response = IPPMessage.response(status: IPPStatus.successfulOK, requestID: requestID, printer: printer, profile: profile, settings: settings, printerURI: printerURI, message: "Job already accepted.", jobID: duplicate.id, jobState: duplicate.state, jobStateReason: duplicate.stateReason, jobName: duplicate.title)
            sendIPP(response, on: connection)
            return
        }

        await MainActor.run {
            AppLogStore.shared.info("Captured IPP document for \(printer.name): \(document.count) bytes, format=\(documentFormat ?? "unknown").")
            pendingJobs.removeValue(forKey: jobID)
            jobRecords[jobID] = IPPJobRecord(
                id: jobID,
                printer: printer,
                title: title ?? "AirPrint Relay Job",
                documentFormat: documentFormat,
                state: 5,
                stateReason: "job-printing",
                message: "Submitting to CUPS.",
                cupsJobID: nil,
                fingerprint: fingerprint,
                byteCount: document.count,
                createdAt: Date(),
                completedAt: nil
            )
            recentDocumentFingerprints[fingerprint] = jobID
            refreshJobStats()
        }
        let result = await CUPSJobSubmitter.submit(
            document: document,
            to: printer,
            documentFormat: documentFormat,
            title: title
        )

        await MainActor.run {
            if result.succeeded {
                let cupsJobID = Self.cupsJobID(from: result.standardOutput)
                jobRecords[jobID]?.state = 9
                jobRecords[jobID]?.stateReason = "job-completed-successfully"
                jobRecords[jobID]?.message = "Submitted to CUPS."
                jobRecords[jobID]?.cupsJobID = cupsJobID
                jobRecords[jobID]?.completedAt = Date()
                AppLogStore.shared.info("Submitted captured job to CUPS queue \(printer.name): \(result.standardOutput)")
            } else {
                jobRecords[jobID]?.state = 9
                jobRecords[jobID]?.stateReason = "job-completed-with-errors"
                jobRecords[jobID]?.message = "CUPS submission failed."
                jobRecords[jobID]?.completedAt = Date()
                AppLogStore.shared.error("Failed to submit captured job to CUPS queue \(printer.name): \(result.standardError.isEmpty ? result.standardOutput : result.standardError)")
            }
            refreshJobStats()
        }

        let status = result.succeeded ? IPPStatus.successfulOK : IPPStatus.serverErrorInternalError
        let record = await MainActor.run { jobRecords[jobID] }
        let response = IPPMessage.response(
            status: status,
            requestID: requestID,
            printer: printer,
            profile: profile,
            settings: settings,
            printerURI: printerURI,
            message: result.succeeded ? "Job accepted." : "CUPS submission failed.",
            jobID: jobID,
            jobState: record?.state ?? (result.succeeded ? 9 : 9),
            jobStateReason: record?.stateReason ?? (result.succeeded ? "job-completed-successfully" : "job-completed-with-errors"),
            jobName: record?.title ?? title
        )
        sendIPP(response, on: connection)
    }

    nonisolated private func documentFingerprint(_ document: Data, printerName: String) -> String {
        var data = Data(printerName.utf8)
        data.append(document)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func cupsJobID(from output: String) -> Int32? {
        output
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int32($0) }
            .first
    }

    private func refreshJobStats() {
        var updated: [String: PrinterJobStats] = [:]

        for record in jobRecords.values {
            var stats = updated[record.printer.name] ?? PrinterJobStats()
            stats.totalJobs += 1
            stats.totalBytes += record.byteCount
            stats.lastJobTitle = record.title
            stats.lastJobDate = max(stats.lastJobDate, record.completedAt ?? record.createdAt)
            stats.lastCUPSJobID = record.cupsJobID ?? stats.lastCUPSJobID

            if record.stateReason == "job-completed-successfully" {
                stats.completedJobs += 1
            } else if record.stateReason == "job-completed-with-errors" {
                stats.failedJobs += 1
            } else if record.stateReason == "job-canceled-by-user" {
                stats.canceledJobs += 1
            } else {
                stats.activeJobs += 1
            }

            updated[record.printer.name] = stats
        }

        statsByPrinterName = updated
    }

    nonisolated private func sendIPP(_ body: Data, on connection: NWConnection) {
        sendHTTP(status: "200 OK", body: body, on: connection)
    }

    nonisolated private func sendContinue(on connection: NWConnection) {
        let response = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { error in
            if let error {
                Task { @MainActor in
                    AppLogStore.shared.error("Failed to send 100 Continue: \(error.localizedDescription)")
                }
            } else {
                Task { @MainActor in
                    AppLogStore.shared.debug("Sent HTTP 100 Continue.")
                }
            }
        })
    }

    nonisolated private func sendHTTP(status: String, body: Data, on connection: NWConnection) {
        var response = Data()
        response.append("HTTP/1.1 \(status)\r\n".data(using: .utf8)!)
        response.append("Content-Type: application/ipp\r\n".data(using: .utf8)!)
        response.append("Content-Length: \(body.count)\r\n".data(using: .utf8)!)
        response.append("Connection: close\r\n\r\n".data(using: .utf8)!)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct PendingIPPJob {
    let printer: Printer
    let documentFormat: String?
    let title: String?
}

private struct IPPJobRecord {
    let id: Int32
    let printer: Printer
    let title: String
    let documentFormat: String?
    var state: Int32
    var stateReason: String
    var message: String
    var cupsJobID: Int32?
    let fingerprint: String
    let byteCount: Int
    let createdAt: Date
    var completedAt: Date?
}

struct PrinterJobStats: Equatable {
    var totalJobs = 0
    var completedJobs = 0
    var failedJobs = 0
    var canceledJobs = 0
    var activeJobs = 0
    var totalBytes = 0
    var lastJobTitle = ""
    var lastJobDate = Date.distantPast
    var lastCUPSJobID: Int32?

    var hasJobs: Bool {
        totalJobs > 0
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var normalizedPath: String {
        guard let url = URL(string: path), let host = url.host, !host.isEmpty else {
            return path.components(separatedBy: "?").first ?? path
        }
        return url.path
    }

    func printerURI(port: UInt16) -> String {
        if let url = URL(string: path), url.scheme != nil, let host = url.host, !host.isEmpty {
            let portText = ":\(url.port ?? Int(port))"
            return "ipp://\(host)\(portText)\(url.path)"
        }

        let host = headers["host"] ?? "\(Host.current().localizedName ?? "Mac").local"
        let hostWithPort = host.contains(":") ? host : "\(host):\(port)"
        return "ipp://\(hostWithPort)\(normalizedPath)"
    }
}

private struct IPPRoute {
    let printer: Printer
    let profile: AdvertisementProfile
    let settings: PrinterAdvertisementSettings
}

private final class HTTPMessageAccumulator: @unchecked Sendable {
    private var buffer = Data()
    private var didSendContinueResponse = false
    var didLogHeaders = false

    var receivedByteCount: Int {
        buffer.count
    }

    var shouldSendContinue: Bool {
        guard !didSendContinueResponse, let headers else { return false }
        return headers.headers["expect"]?.localizedCaseInsensitiveContains("100-continue") == true
    }

    var headerSummary: String? {
        headers.map { "\($0.method) \($0.path), headers=\($0.headers)" }
    }

    var request: HTTPRequest? {
        guard let parsedHeaders = headers else { return nil }
        let bodyStart = parsedHeaders.bodyStart
        let headers = parsedHeaders.headers

        if headers["transfer-encoding"]?.localizedCaseInsensitiveContains("chunked") == true {
            guard let body = chunkedBody(from: buffer.subdata(in: bodyStart..<buffer.count)) else { return nil }
            return HTTPRequest(method: parsedHeaders.method, path: parsedHeaders.path, headers: headers, body: body)
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: parsedHeaders.method, path: parsedHeaders.path, headers: headers, body: body)
    }

    func append(_ data: Data) {
        buffer.append(data)
    }

    func markContinueSent() {
        didSendContinueResponse = true
    }

    private var headers: ParsedHTTPHeaders? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let range = line.range(of: ":") else { continue }
            let key = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return ParsedHTTPHeaders(method: requestParts[0], path: requestParts[1], headers: headers, bodyStart: headerRange.upperBound)
    }

    private func chunkedBody(from bodyData: Data) -> Data? {
        var offset = 0
        var body = Data()

        while offset < bodyData.count {
            guard let lineRange = bodyData[offset...].range(of: Data("\r\n".utf8)) else { return nil }
            let lineData = bodyData.subdata(in: offset..<lineRange.lowerBound)
            guard let line = String(data: lineData, encoding: .ascii) else { return nil }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }
            offset = lineRange.upperBound

            if size == 0 {
                guard bodyData.count >= offset + 2 else { return nil }
                return body
            }

            guard bodyData.count >= offset + size + 2 else { return nil }
            body.append(bodyData.subdata(in: offset..<(offset + size)))
            offset += size
            guard bodyData[offset..<(offset + 2)] == Data("\r\n".utf8) else { return nil }
            offset += 2
        }

        return nil
    }
}

private struct ParsedHTTPHeaders {
    let method: String
    let path: String
    let headers: [String: String]
    let bodyStart: Int
}
