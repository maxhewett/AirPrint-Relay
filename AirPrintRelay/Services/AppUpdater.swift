import Foundation
import SwiftUI

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    enum UpdateChannel: String, CaseIterable, Identifiable {
        case stable
        case beta

        var id: String { rawValue }

        var label: String {
            switch self {
            case .stable:
                return "Stable"
            case .beta:
                return "Beta"
            }
        }
    }

    private static let updateChannelDefaultsKey = "AirPrintRelayUpdateChannel"

    @Published private(set) var isConfigured = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var feedURLString = ""
    @Published private(set) var hasPublicKey = false
    @Published private(set) var selectedChannel: UpdateChannel = .stable
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false

#if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
#endif

    private let stableFeedURL: String
    private let currentShortVersion: String

    init(bundle: Bundle = .main) {
        let persistedChannelRaw = UserDefaults.standard.string(forKey: Self.updateChannelDefaultsKey) ?? UpdateChannel.stable.rawValue
        let persistedChannel = UpdateChannel(rawValue: persistedChannelRaw) ?? .stable

        let feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentShortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        stableFeedURL = feedURL

        super.init()

        selectedChannel = persistedChannel
        feedURLString = Self.resolvedFeedURL(stableFeedURL: feedURL, channel: persistedChannel)
        hasPublicKey = !publicKey.isEmpty
        isConfigured = !feedURL.isEmpty && !publicKey.isEmpty

#if canImport(Sparkle)
        if isConfigured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            automaticallyChecksForUpdates = updaterController?.updater.automaticallyChecksForUpdates ?? false
            automaticallyDownloadsUpdates = updaterController?.updater.automaticallyDownloadsUpdates ?? false
            canCheckForUpdates = true
        } else {
            updaterController = nil
        }
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
#endif
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        guard selectedChannel != channel else { return }
        selectedChannel = channel
        UserDefaults.standard.set(channel.rawValue, forKey: Self.updateChannelDefaultsKey)
        feedURLString = Self.resolvedFeedURL(stableFeedURL: stableFeedURL, channel: channel)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
#if canImport(Sparkle)
        updaterController?.updater.automaticallyChecksForUpdates = enabled
#endif
        automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
#if canImport(Sparkle)
        updaterController?.updater.automaticallyDownloadsUpdates = enabled
#endif
        automaticallyDownloadsUpdates = enabled
    }

    var releaseNotesURL: URL? {
        Self.releaseNotesURL(from: feedURLString, shortVersion: currentShortVersion)
    }

    private static func resolvedFeedURL(stableFeedURL: String, channel: UpdateChannel) -> String {
        switch channel {
        case .stable:
            return stableFeedURL
        case .beta:
            return betaFeedURL(from: stableFeedURL)
        }
    }

    private static func betaFeedURL(from stableFeedURL: String) -> String {
        guard var components = URLComponents(string: stableFeedURL) else {
            return stableFeedURL
        }

        let path = components.path
        if path.hasSuffix("/appcast.xml") {
            components.path = String(path.dropLast("/appcast.xml".count)) + "/beta/appcast.xml"
        } else if path.hasSuffix("appcast.xml") {
            components.path = String(path.dropLast("appcast.xml".count)) + "beta/appcast.xml"
        } else {
            components.path = path.hasSuffix("/") ? path + "beta/appcast.xml" : path + "/beta/appcast.xml"
        }
        return components.url?.absoluteString ?? stableFeedURL
    }

    private static func releaseNotesURL(from feedURLString: String, shortVersion: String) -> URL? {
        guard var components = URLComponents(string: feedURLString) else {
            return nil
        }

        let path = components.path
        if path.hasSuffix("/beta/appcast.xml") {
            components.path = String(path.dropLast("/beta/appcast.xml".count)) + "/release-notes/"
        } else if path.hasSuffix("/appcast.xml") {
            components.path = String(path.dropLast("/appcast.xml".count)) + "/release-notes/"
        } else if path.hasSuffix("appcast.xml") {
            components.path = String(path.dropLast("appcast.xml".count)) + "release-notes/"
        } else {
            components.path = path.hasSuffix("/") ? path + "release-notes/" : path + "/release-notes/"
        }

        if !shortVersion.isEmpty {
            components.path += components.path.hasSuffix("/") ? "\(shortVersion).html" : "/\(shortVersion).html"
        }

        return components.url
    }
}

#if canImport(Sparkle)
extension AppUpdater: @preconcurrency SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLString
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }
}
#endif
