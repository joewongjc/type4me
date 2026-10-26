import Foundation

/// Where this build keeps its data, split by what the data is (#295).
///
/// Two different kinds of state used to share one hardcoded directory:
///
/// - **Profile** — the user's long-lived data: history, Ask Anything, vocabulary
///   and replacement rules, modes, IntelliSense and Revise settings, the jieba
///   dictionary, credentials and downloaded models. Production and Dev share it
///   on purpose. Dev is a long-running dogfooding channel, and it is only useful
///   if it runs against the same real, accumulated data as the release it will
///   become.
/// - **Runtime** — state that belongs to one running app: update staging, the
///   local ASR server's PID file and debug logs. Dogfooding gains nothing from
///   sharing these, and sharing them lets one build act on the other's
///   processes and files.
///
/// Tests get a directory of their own for both, so the suite can never touch a
/// user's real data.
enum AppDataLocation {

    /// Never changes. Renaming it would make every existing install look like it
    /// had lost its data.
    static let sharedProfileName = "Type4Me"
    /// Matches the marker directory `scripts/migrate-dev-keychain-access.sh`
    /// already writes, so the app and its tooling agree on the location.
    static let devRuntimeName = "Type4Me Dev"
    static let testName = "Type4MeTests"

    static let productionBundleID = "com.type4me.app"
    static let devBundleID = "com.type4me.dev"

    #if DEBUG
    private static let runningUnderXCTest: Bool = {
        let process = ProcessInfo.processInfo
        let processName = process.processName.lowercased()
        return process.environment["XCTestConfigurationFilePath"] != nil
            || processName == "xctest"
            || processName.hasSuffix("packagetests")
            || (CommandLine.arguments.first?.contains(".xctest") == true)
    }()
    #else
    private static let runningUnderXCTest = false
    #endif

    // MARK: - Profile

    /// Deliberately independent of the bundle identifier: every non-test build
    /// shares one profile.
    static func profileDirectoryName(isTesting: Bool = runningUnderXCTest) -> String {
        isTesting ? testName : sharedProfileName
    }

    static var profileDirectoryName: String { profileDirectoryName() }

    /// `~/Library/Application Support/<profile>`, created on demand.
    static var profileDirectory: URL { directory(named: profileDirectoryName) }

    // MARK: - Runtime

    /// Resolved from the bundle identifier at runtime rather than a compile-time
    /// flag: `dev-run.sh` rewrites the identifier while packaging, so both builds
    /// come from the same binary.
    ///
    /// Production's runtime files stay where they have always been, inside the
    /// profile directory. Moving them would strand what existing installs already
    /// have on disk — most importantly the PID file used to stop an orphaned
    /// local ASR server after a crash or an update — for a separation only Dev
    /// needs. An unrecognised identifier is treated as production for the same
    /// reason: it keeps working against the files it already has instead of
    /// silently starting over in an empty directory.
    static func runtimeDirectoryName(
        bundleID: String? = Bundle.main.bundleIdentifier,
        isTesting: Bool = runningUnderXCTest
    ) -> String {
        if isTesting { return testName }
        if bundleID == devBundleID { return devRuntimeName }
        return sharedProfileName
    }

    static var runtimeDirectoryName: String { runtimeDirectoryName() }

    /// `~/Library/Application Support/<runtime>`, created on demand.
    static var runtimeDirectory: URL { directory(named: runtimeDirectoryName) }

    // MARK: - Helpers

    private static func directory(named name: String) -> URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
