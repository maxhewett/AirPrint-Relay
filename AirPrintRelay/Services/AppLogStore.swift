import AppKit
import Foundation

struct AppLogEntry: Identifiable, Equatable {
    enum Level: String, Equatable {
        case debug = "Debug"
        case info = "Info"
        case warning = "Warning"
        case error = "Error"
    }

    let id = UUID()
    let date: Date
    let level: Level
    let message: String
}

@MainActor
final class AppLogStore: ObservableObject {
    static let shared = AppLogStore()

    @Published private(set) var entries: [AppLogEntry] = []

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    func debug(_ message: String) {
        append(.debug, message)
    }

    func info(_ message: String) {
        append(.info, message)
    }

    func warning(_ message: String) {
        append(.warning, message)
    }

    func error(_ message: String) {
        append(.error, message)
    }

    func clear() {
        entries.removeAll()
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText, forType: .string)
    }

    var exportText: String {
        entries
            .map { "[\(formatter.string(from: $0.date))] \($0.level.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }

    private func append(_ level: AppLogEntry.Level, _ message: String) {
        entries.append(AppLogEntry(date: Date(), level: level, message: message))
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }
}
