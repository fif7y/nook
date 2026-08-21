// NookLog.swift
// Dead-simple file logger: ~/Library/Logs/Nook/nook.log. Exists because
// os.Logger output from this app never reaches the unified log store on the
// current macOS 27 beta — debugging blind is worse than a plain file.

import Foundation

public enum NookLog {
    private static let queue = DispatchQueue(label: "nook.log", qos: .utility)
    private static let dir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Nook")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let url = dir.appendingPathComponent("nook.log")

    /// Rotate at 5 MB into one `.old` generation — a 24/7 agent otherwise
    /// grows the file forever (and it rides backups).
    private static let rotateBytes = 5 * 1024 * 1024

    /// One open handle for the process (per-line open/seek/close was three
    /// syscalls of pure overhead per line). Written only on `queue`.
    private static let handle: FileHandle? = {
        rotateIfNeeded()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size > rotateBytes else { return }
        let old = dir.appendingPathComponent("nook.log.old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static func log(_ message: String) {
        // Strip control characters: AX-derived strings (third-party status
        // item titles) flow into log lines, and an embedded newline could
        // forge entries.
        let clean = message.unicodeScalars
            .map { $0 == "\n" || $0.properties.generalCategory == .control ? " " : Character($0) }
        let line = "\(stamp.string(from: Date())) \(String(clean))\n"
        queue.async {
            handle?.write(Data(line.utf8))
        }
    }
}
