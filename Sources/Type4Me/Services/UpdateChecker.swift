import Foundation

// MARK: - Models

struct UpdateInfo: Codable, Identifiable {
    let version: String
    let date: String
    let notes: String
    let cloudDmgURL: String?
    let cloudDmgSize: Int64?
    let cloudDmgSHA256: String?
    let localDmgURL: String?
    let localDmgSize: Int64?
    let localDmgSHA256: String?

    var id: String { version }

    enum CodingKeys: String, CodingKey {
        case version, date, notes
        case cloudDmgURL = "cloud_dmg_url"
        case cloudDmgSize = "cloud_dmg_size"
        case cloudDmgSHA256 = "cloud_dmg_sha256"
        case localDmgURL = "local_dmg_url"
        case localDmgSize = "local_dmg_size"
        case localDmgSHA256 = "local_dmg_sha256"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        date = try c.decode(String.self, forKey: .date)
        notes = try c.decode(String.self, forKey: .notes)
        cloudDmgURL = try c.decodeIfPresent(String.self, forKey: .cloudDmgURL)
        cloudDmgSize = try c.decodeIfPresent(Int64.self, forKey: .cloudDmgSize)
        cloudDmgSHA256 = try c.decodeIfPresent(String.self, forKey: .cloudDmgSHA256)
        localDmgURL = try c.decodeIfPresent(String.self, forKey: .localDmgURL)
        localDmgSize = try c.decodeIfPresent(Int64.self, forKey: .localDmgSize)
        localDmgSHA256 = try c.decodeIfPresent(String.self, forKey: .localDmgSHA256)
    }

    /// Resolved cloud DMG download URL (explicit or fallback from version).
    var resolvedDmgURL: URL {
        downloadURL(isLocalInstallation: false)
    }

    func downloadURL(isLocalInstallation: Bool) -> URL {
        if isLocalInstallation {
            if let urlStr = localDmgURL, let url = URL(string: urlStr) { return url }
            return Self.releaseAssetURL(version: version, suffix: "local-apple-silicon")
        }
        if let urlStr = cloudDmgURL, let url = URL(string: urlStr) { return url }
        return Self.releaseAssetURL(version: version, suffix: "cloud")
    }

    func dmgSHA256(isLocalInstallation: Bool) -> String? {
        isLocalInstallation ? localDmgSHA256 : cloudDmgSHA256
    }

    func dmgSize(isLocalInstallation: Bool) -> Int64? {
        isLocalInstallation ? localDmgSize : cloudDmgSize
    }

    /// Human-readable download size (e.g. "23.5 MB")
    var formattedSize: String? {
        formattedSize(isLocalInstallation: false)
    }

    func formattedSize(isLocalInstallation: Bool) -> String? {
        let size = dmgSize(isLocalInstallation: isLocalInstallation)
        guard let size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private static func releaseAssetURL(version: String, suffix: String) -> URL {
        URL(string: "https://github.com/joewongjc/type4me/releases/download/v\(version)/Type4Me-v\(version)-\(suffix).dmg")!
    }
}

struct UpdateManifest: Codable {
    let latest: String
    let releases: [UpdateInfo]
}

// MARK: - Update Checker

@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    private let url = URL(string: "https://raw.githubusercontent.com/joewongjc/type4me/main/updates.json")!
    private let checkIntervalKey = "tf_lastUpdateCheck"
    private let seenVersionKey = "tf_lastSeenVersion"
    private let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private var timer: Timer?

    private init() {}

    // MARK: - Public

    /// Start periodic checking: immediate check + 24h timer.
    func startPeriodicChecking(appState: AppState) {
        Task {
            await check(appState: appState)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.check(appState: appState)
            }
        }
    }

    /// Manual check (always fetches, ignores cooldown).
    func checkNow(appState: AppState) async {
        await fetch(appState: appState)
    }

    /// Mark the latest available version as "seen" so the red badge clears.
    func markAsSeen(appState: AppState) {
        guard let latest = appState.availableUpdates.first else { return }
        UserDefaults.standard.set(latest.version, forKey: seenVersionKey)
        appState.hasUnseenUpdate = false
    }

    var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: seenVersionKey) ?? currentVersion
    }

    // MARK: - Private

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check with 24h cooldown.
    private func check(appState: AppState) async {
        let lastCheck = UserDefaults.standard.double(forKey: checkIntervalKey)
        let now = Date().timeIntervalSince1970
        if lastCheck > 0 && (now - lastCheck) < checkInterval {
            return
        }
        await fetch(appState: appState)
    }

    private func fetch(appState: AppState) async {
        appState.isCheckingUpdate = true
        defer { appState.isCheckingUpdate = false }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: checkIntervalKey)

            let current = currentVersion
            let newer = manifest.releases
                .filter { compareVersions($0.version, isGreaterThan: current) }
                .sorted { compareVersions($0.version, isGreaterThan: $1.version) }

            appState.availableUpdates = newer
            appState.lastUpdateCheck = Date()

            if let latest = newer.first {
                appState.hasUnseenUpdate = compareVersions(latest.version, isGreaterThan: lastSeenVersion)
            } else {
                appState.hasUnseenUpdate = false
            }
        } catch {
            NSLog("[UpdateChecker] fetch failed: \(error)")
        }
    }

    /// Semantic version comparison: "1.2.0" > "1.1.0"
    private func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}
