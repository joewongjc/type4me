import Foundation
import AppKit

enum MagpieInstallation {
    static let bundleID = "com.yetone.magpie"
    static let agentPluginInstallCommand = "magpie plugin add @magpie-community/agent-type4me"
    static let cliCandidates = [
        "~/.local/bin/magpie",
        "/opt/homebrew/bin/magpie",
        "/usr/local/bin/magpie",
    ]

    static func cliURL() -> URL? {
        for candidate in cliCandidates {
            let expanded: String
            if candidate.hasPrefix("~") {
                expanded = NSString(string: candidate).expandingTildeInPath
            } else {
                expanded = candidate
            }
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    static func isInstalled() -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return true
        }
        return cliURL() != nil
    }

    static func openApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in }
        } else if let cli = cliURL() {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["panel"]
            try? process.run()
        }
    }
}
