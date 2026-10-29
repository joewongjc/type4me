import Darwin
import Foundation
import os

/// Diagnostics both processes append to, in the App Group container, so a
/// device test shows what the keyboard and the app each saw in one place.
/// Settings › Diagnostics shows it on the phone; with a cable, read it back
/// with `devicectl … --domain-type appGroupDataContainer
/// --source Library/diagnostics.log`.
enum SharedLog {
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Writes leave the caller's thread, so the keyboard never waits on the
    /// disk; a serial queue keeps both processes' lines in order.
    private static let queue = DispatchQueue(label: "com.type4me.sharedlog", qos: .utility)

    /// Once the log passes this, it moves to `diagnostics.old.log` and a new
    /// one starts, so the two together stay under twice this.
    private static let rotateBytes: UInt64 = 512 * 1024

    static let process = Bundle.main.bundleIdentifier?.hasSuffix(".keyboard") == true ? "keyboard" : "app"

    /// Under Library/, the only part of a group container devicectl can read.
    static var fileURL: URL? {
        guard let library = SharedContainer.url?.appendingPathComponent("Library", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return library.appendingPathComponent("diagnostics.log")
    }

    static var oldFileURL: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent("diagnostics.old.log")
    }

    static func add(_ text: String) {
        let line = Data("\(stamp.string(from: Date())) [\(process)] \(text)\n".utf8)
        queue.async { append(line) }
    }

    /// Waits for every line added so far to reach the file.
    static func flush() {
        queue.sync {}
    }

    private static func append(_ line: Data) {
        guard let fileURL else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            let size = handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
            if size + UInt64(line.count) > rotateBytes, let oldFileURL {
                try? FileManager.default.removeItem(at: oldFileURL)
                try? FileManager.default.moveItem(at: fileURL, to: oldFileURL)
            }
        } else {
            try? line.write(to: fileURL)
        }
    }

    /// Both files, oldest line first.
    static func readAll() -> String {
        flush()
        let parts = [oldFileURL, fileURL].compactMap { url -> String? in
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return parts.joined()
    }

    static func clear() {
        queue.sync {
            [fileURL, oldFileURL].compactMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    // MARK: Memory

    /// This process's footprint, the figure jetsam compares with its limit.
    static var footprintMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// How much more this process may use before jetsam ends it.
    static var availableMB: Double {
        Double(os_proc_available_memory()) / 1_048_576
    }

    /// "memory 31.2 MB, 28.4 MB left", for a log line.
    static var memorySummary: String {
        let used = footprintMB.map { String(format: "%.1f MB", $0) } ?? "?"
        let left = String(format: "%.1f MB", availableMB)
        return L("内存 \(used)，剩余 \(left)", "memory \(used), \(left) left")
    }
}
