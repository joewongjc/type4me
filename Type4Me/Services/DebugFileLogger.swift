import Foundation

enum DebugFileLogger {

    private static let queue = DispatchQueue(label: "com.type4me.debug-file-logger")

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Type4Me", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
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
              size.intValue > 256 * 1024
        else { return }

        try? FileManager.default.removeItem(at: logURL)
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
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(lines.suffix(n))
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
