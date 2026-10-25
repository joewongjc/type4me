import Foundation

/// Diagnostics both processes append to, in the App Group container, so a
/// device test shows what the keyboard and the app each saw in one place.
/// Read it back with `devicectl … --domain-type appGroupDataContainer
/// --source Library/diagnostics.log`.
enum SharedLog {
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let lock = NSLock()

    /// Under Library/, the only part of a group container devicectl can read.
    static var fileURL: URL? {
        guard let library = SharedContainer.url?.appendingPathComponent("Library", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return library.appendingPathComponent("diagnostics.log")
    }

    static func add(_ text: String) {
        guard let fileURL else { return }
        let process = Bundle.main.bundleIdentifier?.replacingOccurrences(of: "com.type4me.ios", with: "app") ?? "?"
        let line = Data("\(stamp.string(from: Date())) [\(process)] \(text)\n".utf8)
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: fileURL)
        }
    }
}
