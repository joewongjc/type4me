import Foundation

enum DebugFileLogger {

    private static let queue = DispatchQueue(label: "com.type4me.debug-file-logger")
    private static let maximumLogSize = 256 * 1024

    static var logURL: URL {
        let dir = AppDataLocation.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }

    private static var previousLogURL: URL {
        logURL.deletingLastPathComponent().appendingPathComponent("debug.log.1")
    }

    static func startSession() {
        queue.async {
            rotateIfNeeded()
            append("--- session \(timestamp()) ---")
        }
    }

    static func log(_ message: String) {
        queue.async {
            append("[\(timestamp())] \(message)")
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue > maximumLogSize
        else { return }

        try? FileManager.default.removeItem(at: previousLogURL)
        try? FileManager.default.moveItem(at: logURL, to: previousLogURL)
    }

    private static func append(_ line: String) {
        let entry = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: entry)
                try? handle.close()
            }
        } else {
            try? entry.write(to: logURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logURL.path
            )
        }
    }

    /// Return the last `n` lines from the debug log (synchronous read).
    static func recentLines(_ n: Int) -> [String] {
        queue.sync {
            guard let data = try? Data(contentsOf: logURL),
                  let text = String(data: data, encoding: .utf8)
            else { return [] }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Array(lines.suffix(n))
        }
    }

    /// Return the most recent log text, including the previous rotated file.
    /// The result is capped so a copied GitHub report stays within practical limits.
    static func reportContents(maxCharacters: Int) -> String {
        queue.sync {
            let text = [previousLogURL, logURL]
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n--- rotated log boundary ---\n")

            guard text.count > maxCharacters else { return text }
            return "[earlier log entries omitted]\n" + String(text.suffix(maxCharacters))
        }
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
