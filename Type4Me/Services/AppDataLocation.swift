import Foundation

/// The Application Support subdirectory this build owns.
///
/// The name used to be a literal repeated across every store, which meant the
/// Dev app built by `scripts/dev-run.sh` read and wrote the production user's
/// history, vocabulary, modes and credentials despite having its own bundle id,
/// URL scheme and signing identity (#295). The app is not sandboxed, so nothing
/// else separated them.
enum AppDataLocation {

    /// Never changes. Renaming this would make every existing install look like
    /// it had lost its data, which is the failure this is meant to prevent.
    static let productionDirectoryName = "Type4Me"
    static let devDirectoryName = "Type4Me Dev"
    static let testDirectoryName = "Type4MeTests"

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

    /// Resolved from the bundle identifier at runtime, not a compile-time flag:
    /// `dev-run.sh` rewrites the identifier while packaging, so both builds come
    /// from the same binary.
    ///
    /// Only identifiers known to be non-production are moved aside. An
    /// unrecognised build keeps the production directory on purpose — polluting
    /// it is recoverable, while sending a renamed production build to a fresh
    /// directory would silently hide every user's data.
    static func directoryName(
        bundleID: String? = Bundle.main.bundleIdentifier,
        isTesting: Bool = runningUnderXCTest
    ) -> String {
        if isTesting { return testDirectoryName }
        if bundleID == devBundleID { return devDirectoryName }
        return productionDirectoryName
    }

    static var directoryName: String { directoryName() }

    /// `~/Library/Application Support/<name>`, created on demand.
    static var directory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Same parent as `directory`, never a child of it: a backup kept inside the
    /// data directory would be taken by the same loss it exists to survive.
    static var backupDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("\(directoryName) Backups", isDirectory: true)
    }
}
