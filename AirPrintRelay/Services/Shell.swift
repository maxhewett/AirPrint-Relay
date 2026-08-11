import Foundation

struct ShellResult {
    let standardOutput: String
    let standardError: String
    let terminationStatus: Int32

    var succeeded: Bool {
        terminationStatus == 0
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String] = []) async -> ShellResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ShellResult(
                    standardOutput: "",
                    standardError: error.localizedDescription,
                    terminationStatus: 127
                )
            }

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ShellResult(
                standardOutput: output.trimmingCharacters(in: .whitespacesAndNewlines),
                standardError: error.trimmingCharacters(in: .whitespacesAndNewlines),
                terminationStatus: process.terminationStatus
            )
        }.value
    }

    static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
