import AppKit
import Foundation

struct OpenAppAction: MacAction {
    let name = "open_app"
    let description = "Open a macOS application by name (e.g. Safari, Notes, Terminal)."
    let parametersSchema: [String: String] = [
        "app": "Application name (without .app), e.g. \"Safari\" or \"Visual Studio Code\""
    ]

    func execute(args: [String: Any]) async -> MacActionResult {
        guard let appName = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appName.isEmpty
        else {
            return .failure(L("缺少应用名称", "Missing app name"))
        }

        let workspace = NSWorkspace.shared
        guard let url = Self.applicationURL(named: appName, workspace: workspace) else {
            return .failure(L("找不到应用：\(appName)", "App not found: \(appName)"))
        }

        return await withCheckedContinuation { continuation in
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    continuation.resume(returning: .failure(error.localizedDescription))
                } else {
                    continuation.resume(returning: .ok(L("已打开 \(appName)", "Opened \(appName)")))
                }
            }
        }
    }

    private static func applicationURL(named appName: String, workspace: NSWorkspace) -> URL? {
        if appName.contains("."),
           let url = workspace.urlForApplication(withBundleIdentifier: appName) {
            return url
        }

        let wantedNames = [
            appName,
            appName.capitalized,
            appName.hasSuffix(".app") ? appName : "\(appName).app",
            appName.capitalized.hasSuffix(".app") ? appName.capitalized : "\(appName.capitalized).app"
        ].map { $0.lowercased() }

        let searchRoots = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]

        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "app" else { continue }
                if wantedNames.contains(url.lastPathComponent.lowercased())
                    || wantedNames.contains(url.deletingPathExtension().lastPathComponent.lowercased()) {
                    return url
                }
                if let bundle = Bundle(url: url),
                   let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                   wantedNames.contains(displayName.lowercased()) {
                    return url
                }
            }
        }

        return nil
    }
}
