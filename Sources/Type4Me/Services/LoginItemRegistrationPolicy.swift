import Foundation

enum LoginItemRegistrationPolicy {
    static var supportsCurrentProcess: Bool {
        supportsRegistration(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            executableURL: Bundle.main.executableURL
        )
    }

    static func supportsRegistration(
        bundleURL: URL,
        bundleIdentifier: String?,
        executableURL: URL?
    ) -> Bool {
        guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty,
              let executableURL
        else {
            return false
        }

        let executableDirectory = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        return executable.deletingLastPathComponent() == executableDirectory
    }
}
