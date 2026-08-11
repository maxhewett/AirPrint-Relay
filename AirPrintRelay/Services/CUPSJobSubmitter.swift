import Foundation
import CUPS

enum CUPSJobSubmitter {
    static func submit(document: Data, to printer: Printer, documentFormat: String?, title: String?) async -> ShellResult {
        await Task.detached(priority: .utility) {
            let jobsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AirPrintRelayJobs", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
                let fileURL = jobsDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fileExtension(for: documentFormat))
                try document.write(to: fileURL, options: .atomic)

                var optionsCount: Int32 = 0
                var options: UnsafeMutablePointer<cups_option_t>?
                if let documentFormat, !documentFormat.isEmpty {
                    optionsCount = cupsAddOption("document-format", documentFormat, optionsCount, &options)
                }

                let jobID = cupsPrintFile(
                    printer.name,
                    fileURL.path,
                    title ?? "AirPrint Relay Job",
                    optionsCount,
                    options
                )

                cupsFreeOptions(optionsCount, options)
                try? FileManager.default.removeItem(at: fileURL)

                if jobID > 0 {
                    return ShellResult(
                        standardOutput: "CUPS job \(jobID)",
                        standardError: "",
                        terminationStatus: 0
                    )
                }

                let error = cupsLastErrorString().map { String(cString: $0) } ?? "Unknown CUPS error"
                return ShellResult(
                    standardOutput: "",
                    standardError: error,
                    terminationStatus: 1
                )
            } catch {
                return ShellResult(
                    standardOutput: "",
                    standardError: error.localizedDescription,
                    terminationStatus: 1
                )
            }
        }.value
    }

    private static func fileExtension(for documentFormat: String?) -> String {
        switch documentFormat?.lowercased() {
        case "application/pdf":
            return "pdf"
        case "image/jpeg":
            return "jpg"
        case "image/urf":
            return "urf"
        case "image/pwg-raster":
            return "pwg"
        default:
            return "bin"
        }
    }
}
