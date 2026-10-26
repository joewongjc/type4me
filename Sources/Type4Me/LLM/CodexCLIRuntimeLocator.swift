import AppKit
import Foundation

enum CodexCLIRuntimeLocator {
    // Query desktop identities only: the CLI helper identity can belong to a plugin cache.
    private static let applicationIdentifiers = ["com.openai.codex", "com.openai.chat"]
    private static let applicationNames = ["Codex.app", "ChatGPT.app"]
    private static let embeddedCommandPaths = [
        "Contents/Resources/codex-cli/bin/codex",
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex",
    ]
    static let defaultSystemCommandDirectories = ["/opt/homebrew/bin", "/usr/local/bin"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    private struct PackageManifest: Decodable {
        let layoutVersion: Int
        let entrypoint: String
    }

    /// Finds desktop-bundled or standalone Codex without launching a shell or scanning the disk.
    ///
    /// Args:
    ///   fileManager: Filesystem used to validate candidates.
    ///   homeDirectory: Current user's home for user-scoped installation locations.
    ///   searchPath: Process PATH; GUI launches may expose only system directories.
    ///   applicationDirectories: Conventional app directories when registration is unavailable.
    ///   systemCommandDirectories: Conventional standalone CLI directories.
    ///   applicationLookup: All desktop registrations in the system's preferred launch order.
    /// Returns:
    ///   The first existing executable file, with desktop installations preferred.
    /// Throws:
    ///   CodexCLIError.notInstalled when no executable file is found.
    static func locate(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        applicationDirectories: [URL]? = nil,
        systemCommandDirectories: [URL] = defaultSystemCommandDirectories,
        applicationLookup: (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
    ) throws -> URL {
        let directories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        let applications = unique(applicationIdentifiers.flatMap(applicationLookup) + directories.flatMap { directory in
            applicationNames.map { directory.appendingPathComponent($0, isDirectory: true) }
        }).filter { isSupportedApplication($0, fileManager: fileManager) }

        for candidate in candidates(
            homeDirectory: homeDirectory, applicationURLs: applications, searchPath: searchPath,
            systemCommandDirectories: systemCommandDirectories
        ) where isExecutableFile(candidate, fileManager: fileManager) {
            return candidate
        }
        throw CodexCLIError.notInstalled
    }

    /// Orders declared package entries, compatible desktop layouts, PATH, and conventional CLIs.
    ///
    /// Args:
    ///   homeDirectory: Current user's home directory.
    ///   applicationURLs: Validated desktop applications in preference order.
    ///   searchPath: Colon-separated absolute directories; empty and relative entries are ignored.
    ///   systemCommandDirectories: Conventional standalone CLI directories.
    /// Returns:
    ///   Unique candidate file URLs in lookup order; candidates are not executed.
    static func candidates(
        homeDirectory: URL,
        applicationURLs: [URL] = [],
        searchPath: String? = nil,
        systemCommandDirectories: [URL] = defaultSystemCommandDirectories
    ) -> [URL] {
        var locations = applicationURLs.filter(\.isFileURL).flatMap { application -> [URL] in
            let package = application.appendingPathComponent("Contents/Resources/codex-cli", isDirectory: true)
            let declared = packageEntrypoint(in: package).flatMap {
                containedFile($0, in: application)
            }
            return [declared].compactMap { $0 } + embeddedCommandPaths.compactMap {
                containedFile(application.appendingPathComponent($0), in: application)
            }
        }
        locations.append(contentsOf: (searchPath ?? "").split(separator: ":").compactMap { entry in
            guard entry.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(entry), isDirectory: true).appendingPathComponent("codex")
        })
        locations.append(contentsOf: systemCommandDirectories.map { $0.appendingPathComponent("codex") })
        locations.append(homeDirectory.appendingPathComponent(".local/bin/codex"))
        return unique(locations)
    }

    /// Reads the observed version-1 package format; other formats use compatibility fallbacks.
    ///
    /// Args:
    ///   package: Codex package directory inside a desktop bundle.
    /// Returns:
    ///   A declared entrypoint contained in the package, or nil for unusable metadata.
    private static func packageEntrypoint(in package: URL) -> URL? {
        guard let data = try? Data(contentsOf: package.appendingPathComponent("codex-package.json")),
              let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data),
              manifest.layoutVersion == 1,
              !manifest.entrypoint.isEmpty,
              !manifest.entrypoint.hasPrefix("/"),
              !manifest.entrypoint.contains("\0") else { return nil }
        return containedFile(package.appendingPathComponent(manifest.entrypoint), in: package)
    }

    /// Prevents bundle metadata and embedded symlinks from selecting files outside their root.
    ///
    /// Args:
    ///   file: Candidate file, possibly containing relative components or symlinks.
    ///   root: Directory that must contain the resolved candidate.
    /// Returns:
    ///   The original standardized URL if its resolved target stays inside the root.
    private static func containedFile(_ file: URL, in root: URL) -> URL? {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedFile.hasPrefix(resolvedRoot + "/") else { return nil }
        return file.standardizedFileURL
    }

    /// Validates current bundle metadata rather than trusting names or cached registrations.
    ///
    /// Args:
    ///   application: Candidate desktop bundle.
    ///   fileManager: Filesystem used to validate its main executable.
    /// Returns:
    ///   Whether the bundle has a supported desktop identity and executable.
    private static func isSupportedApplication(_ application: URL, fileManager: FileManager) -> Bool {
        guard application.isFileURL, application.pathExtension.lowercased() == "app",
              let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              applicationIdentifiers.contains(identifier),
              let name = info["CFBundleExecutable"] as? String,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              let executable = containedFile(application.appendingPathComponent("Contents/MacOS/" + name), in: application)
        else { return false }
        return isExecutableFile(executable, fileManager: fileManager)
    }

    /// Rejects missing files, broken links, and executable directories.
    ///
    /// Args:
    ///   url: Candidate executable file.
    ///   fileManager: Filesystem used to check existence and permissions.
    /// Returns:
    ///   Whether the candidate exists as a non-directory executable.
    private static func isExecutableFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return url.isFileURL
            && fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }

    /// Removes duplicate file paths while preserving discovery priority.
    ///
    /// Args:
    ///   urls: Candidate locations in preference order.
    /// Returns:
    ///   Standardized file URLs without duplicate paths.
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }
}
