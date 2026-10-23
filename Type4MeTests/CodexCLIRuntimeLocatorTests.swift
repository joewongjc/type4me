import XCTest
@testable import Type4Me

final class CodexCLIRuntimeLocatorTests: XCTestCase {
    /// Finds a moved or renamed desktop app using its declared package entrypoint.
    func testRegisteredApplicationUsesManifestEntrypoint() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("External Disk/Renamed.app"))
            let package = app.appendingPathComponent("Contents/Resources/codex-cli")
            let command = try makeExecutable(package.appendingPathComponent("new-layout/launcher"))
            try writeManifest(in: package, entrypoint: "new-layout/launcher")
            XCTAssertEqual(try locate(in: root, applications: [app]), command)
        }
    }

    /// Falls through stale registrations and desktop copies that have no CLI.
    func testChecksAllRegisteredApplicationsInSystemOrder() throws {
        try withWorkspace { root in
            let empty = try makeApplication(root.appendingPathComponent("Empty.app"))
            let working = try makeApplication(root.appendingPathComponent("Working.app"))
            let command = try makeExecutable(working.appendingPathComponent("Contents/Resources/codex-cli/bin/codex"))
            XCTAssertEqual(try locate(in: root, applications: [root.appendingPathComponent("Missing.app"), empty, working]), command)
        }
    }

    /// Preserves desktop preference even when a different CLI is available on PATH.
    func testDesktopCommandPrecedesSearchPathCommand() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Desktop.app"))
            let command = try makeExecutable(app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex"))
            _ = try makeExecutable(root.appendingPathComponent("bin/codex"))
            XCTAssertEqual(try locate(in: root, applications: [app], searchPath: root.appendingPathComponent("bin").path), command)
        }
    }

    /// Supports existing nested and legacy desktop layouts without a package manifest.
    func testKnownDesktopLayoutsRemainSupported() throws {
        for layout in ["codex-cli/bin/codex", "codex-cli/CodexCLI.app/Contents/MacOS/codex", "CodexCLI.app/Contents/MacOS/codex", "codex"] {
            try withWorkspace { root in
                let app = try makeApplication(root.appendingPathComponent("Desktop.app"), identifier: "com.openai.chat")
                let command = try makeExecutable(app.appendingPathComponent("Contents/Resources/" + layout))
                XCTAssertEqual(try locate(in: root, applications: [app]), command)
            }
        }
    }

    /// Finds a user Applications install before Launch Services has registered it.
    func testUserApplicationsFallback() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Applications/Codex.app"))
            let command = try makeExecutable(app.appendingPathComponent("Contents/Resources/codex"))
            XCTAssertEqual(try locate(in: root), command)
        }
    }

    /// Does not confuse a helper registered by a plugin with the desktop application.
    func testHelperBundleIdentityIsNotADesktopCandidate() throws {
        try withWorkspace { root in
            let helper = try makeApplication(root.appendingPathComponent("Cached.app"), identifier: "com.openai.codex.cli")
            _ = try makeExecutable(helper.appendingPathComponent("Contents/Resources/codex"))
            XCTAssertThrowsError(try locate(in: root, applications: [helper]))
        }
    }

    /// Rejects a folder named like Codex when its bundle identity does not match.
    func testWrongBundleIdentifierIsIgnored() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Applications/Codex.app"), identifier: "example.other")
            _ = try makeExecutable(app.appendingPathComponent("Contents/Resources/codex"))
            XCTAssertThrowsError(try locate(in: root))
        }
    }

    /// Finds CLI-only installations on an absolute PATH without reading shell startup files.
    func testCustomSearchPathAndSymlink() throws {
        try withWorkspace { root in
            let command = try makeExecutable(root.appendingPathComponent("tools/real-codex"))
            let link = root.appendingPathComponent("tools/codex")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: command)
            XCTAssertEqual(try locate(in: root, searchPath: link.deletingLastPathComponent().path), link)
        }
    }

    /// Keeps the existing local-bin fallback for standalone installations.
    func testLocalBinFallback() throws {
        try withWorkspace { root in
            let command = try makeExecutable(root.appendingPathComponent(".local/bin/codex"))
            XCTAssertEqual(try locate(in: root), command)
        }
    }

    /// Skips executable directories, non-executable files, and broken links.
    func testInvalidFilesDoNotHideAWorkingCommand() throws {
        try withWorkspace { root in
            let bins = ["directory", "plain", "broken", "valid"].map { root.appendingPathComponent($0) }
            for bin in bins { try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true) }
            try FileManager.default.createDirectory(at: bins[0].appendingPathComponent("codex"), withIntermediateDirectories: true)
            try Data().write(to: bins[1].appendingPathComponent("codex"))
            try FileManager.default.createSymbolicLink(at: bins[2].appendingPathComponent("codex"), withDestinationURL: root.appendingPathComponent("missing"))
            let command = try makeExecutable(bins[3].appendingPathComponent("codex"))
            XCTAssertEqual(try locate(in: root, searchPath: bins.map(\.path).joined(separator: ":")), command)
        }
    }

    /// Rejects manifest entries that escape the package through absolute paths or traversal.
    func testManifestCannotSelectAnExternalExecutable() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Desktop.app"))
            let package = app.appendingPathComponent("Contents/Resources/codex-cli")
            let outside = try makeExecutable(app.appendingPathComponent("Contents/Resources/outside"))
            for entrypoint in [outside.path, "../outside", "", "bin/\0codex"] {
                try writeManifest(in: package, entrypoint: entrypoint)
                XCTAssertThrowsError(try locate(in: root, applications: [app]), entrypoint)
            }
        }
    }

    /// Applies containment checks after resolving symlinks in a declared entrypoint.
    func testManifestSymlinkCannotEscapePackage() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Desktop.app"))
            let package = app.appendingPathComponent("Contents/Resources/codex-cli")
            let outside = try makeExecutable(root.appendingPathComponent("outside"))
            try writeManifest(in: package, entrypoint: "launcher")
            try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("launcher"), withDestinationURL: outside)
            XCTAssertThrowsError(try locate(in: root, applications: [app]))
        }
    }

    /// Known-layout links must also stay inside the desktop bundle before CLI fallback.
    func testKnownLayoutSymlinkCannotEscapeApplication() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Desktop.app"))
            let outside = try makeExecutable(root.appendingPathComponent("outside"))
            let resources = app.appendingPathComponent("Contents/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: resources.appendingPathComponent("codex"), withDestinationURL: outside)
            let fallback = try makeExecutable(root.appendingPathComponent(".local/bin/codex"))
            XCTAssertEqual(try locate(in: root, applications: [app]), fallback)
        }
    }

    /// Unknown, invalid, or stale metadata cannot disable the known-layout fallbacks.
    func testUnusableManifestFallsBackToKnownLayout() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Desktop.app"))
            let package = app.appendingPathComponent("Contents/Resources/codex-cli")
            let command = try makeExecutable(package.appendingPathComponent("bin/codex"))
            let alternative = try makeExecutable(package.appendingPathComponent("other"))
            try writeManifest(in: package, entrypoint: "other", layoutVersion: 99)
            XCTAssertEqual(try locate(in: root, applications: [app]), command)
            XCTAssertNotEqual(command, alternative)
            try Data("invalid json".utf8).write(to: package.appendingPathComponent("codex-package.json"))
            XCTAssertEqual(try locate(in: root, applications: [app]), command)
            try writeManifest(in: package, entrypoint: "missing")
            XCTAssertEqual(try locate(in: root, applications: [app]), command)
        }
    }

    /// Does not cache a removed installation across later lookups.
    func testRemovedDesktopFallsBackOnNextLookup() throws {
        try withWorkspace { root in
            let app = try makeApplication(root.appendingPathComponent("Desktop.app"))
            let command = try makeExecutable(app.appendingPathComponent("Contents/Resources/codex"))
            let fallback = try makeExecutable(root.appendingPathComponent(".local/bin/codex"))
            XCTAssertEqual(try locate(in: root, applications: [app]), command)
            try FileManager.default.removeItem(at: app)
            XCTAssertEqual(try locate(in: root, applications: [app]), fallback)
        }
    }

    /// Relative PATH entries must not cause execution from the working directory.
    func testCandidatesIgnoreRelativePathsAndDuplicates() {
        let candidates = CodexCLIRuntimeLocator.candidates(
            homeDirectory: URL(fileURLWithPath: "/Users/tester"), searchPath: ":.:relative/bin:/tools:/tools",
            systemCommandDirectories: []
        )
        XCTAssertEqual(candidates.map(\.path), ["/tools/codex", "/Users/tester/.local/bin/codex"])
    }

    /// Keeps all discovery inputs isolated from the machine running the tests.
    ///
    /// Args:
    ///   root: Temporary home directory.
    ///   applications: Simulated desktop registrations in system preference order.
    ///   searchPath: Simulated process PATH.
    /// Returns:
    ///   The discovered executable URL.
    private func locate(in root: URL, applications: [URL] = [], searchPath: String = "") throws -> URL {
        try CodexCLIRuntimeLocator.locate(
            homeDirectory: root, searchPath: searchPath,
            applicationDirectories: [root.appendingPathComponent("Applications")], systemCommandDirectories: [],
            applicationLookup: { identifier in
                XCTAssertTrue(["com.openai.codex", "com.openai.chat"].contains(identifier))
                return identifier == "com.openai.codex" ? applications : []
            }
        )
    }

    /// Provides a temporary filesystem that is removed even when an assertion throws.
    ///
    /// Args:
    ///   body: Checks to run against the temporary home directory.
    private func withWorkspace(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// Creates an executable fixture that discovery never launches.
    ///
    /// Args:
    ///   url: Location inside the temporary workspace.
    /// Returns:
    ///   The fixture URL.
    private func makeExecutable(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Creates a supported bundle with a valid main executable.
    ///
    /// Args:
    ///   url: Application bundle location.
    ///   identifier: Bundle identity for discovery validation.
    /// Returns:
    ///   The application URL.
    private func makeApplication(_ url: URL, identifier: String = "com.openai.codex") throws -> URL {
        _ = try makeExecutable(url.appendingPathComponent("Contents/MacOS/Desktop"))
        let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Desktop"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    /// Writes only the package metadata consumed by the locator.
    ///
    /// Args:
    ///   package: Package directory inside the test bundle.
    ///   entrypoint: Relative executable path, including malformed fixtures.
    ///   layoutVersion: Package layout version declared by the fixture.
    private func writeManifest(in package: URL, entrypoint: String, layoutVersion: Int = 1) throws {
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["layoutVersion": layoutVersion, "entrypoint": entrypoint])
            .write(to: package.appendingPathComponent("codex-package.json"))
    }
}
