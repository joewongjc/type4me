import Foundation
import StoreKit
import UIKit

/// Tells the user when a newer build is out and where to get it. TestFlight
/// and the App Store update the app themselves; this only covers people with
/// automatic updates off. Reads `updates-ios.json` from the GitHub repo, the
/// way the Mac reads `updates.json`, and never downloads anything itself.
@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    static let manifestURL = URL(string: "https://raw.githubusercontent.com/joewongjc/type4me/main/updates-ios.json")!

    enum Channel: String { case testFlight, appStore, development }

    struct Available: Equatable {
        let version: String
        let build: Int
        let notes: String?
        let url: URL
    }

    /// Set when the channel this copy came from has a newer build.
    @Published private(set) var available: Available?

    private var lastCheck: Date?
    private static let interval: TimeInterval = 6 * 60 * 60

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    /// Called whenever the app comes to the front; checks at most every 6 hours.
    func checkIfDue() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        lastCheck = Date()
        Task { await check() }
    }

    func dismiss() {
        if let available { AppSettings.dismissedUpdateBuild = "\(available.version)(\(available.build))" }
        self.available = nil
    }

    private func check() async {
        let channel = await Self.channel()
        guard channel != .development,
              let manifest = await Self.fetchManifest(),
              let release = channel == .testFlight ? manifest.testflight : manifest.appStore,
              let url = URL(string: release.url)
        else { return }
        let newer = Self.compare(release.version, currentVersion)
        let isNewer = newer == .orderedDescending
            || (newer == .orderedSame && (release.build ?? 0) > currentBuild)
        let key = "\(release.version)(\(release.build ?? 0))"
        guard isNewer, AppSettings.dismissedUpdateBuild != key else {
            available = nil
            return
        }
        let zh = AppLanguage.current == .zh
        available = Available(version: release.version, build: release.build ?? 0, notes: zh ? release.notesZh : release.notesEn, url: url)
    }

    // MARK: - Pieces

    struct Manifest: Decodable {
        struct Release: Decodable {
            let version: String
            let build: Int?
            let url: String
            let notesZh: String?
            let notesEn: String?
        }
        let testflight: Release?
        let appStore: Release?
    }

    private static func fetchManifest() async -> Manifest? {
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Where this copy was installed from, as StoreKit reports it.
    static func channel() async -> Channel {
        if case .verified(let transaction) = try? await AppTransaction.shared {
            switch transaction.environment {
            case .production: return .appStore
            case .sandbox: return .testFlight
            default: return .development
            }
        }
        // No signed app transaction (offline on first launch): TestFlight
        // installs carry a sandbox receipt.
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? .testFlight : .development
    }

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }
}
