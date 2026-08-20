// NookLog.swift
// Dead-simple file logger: ~/Library/Logs/Nook/nook.log. Exists because
// os.Logger output from this app never reaches the unified log store on the
// current macOS 27 beta — debugging blind is worse than a plain file.

import Foundation

public enum NookLog {
    private static let queue = DispatchQueue(label: "nook.log", qos: .utility)
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Nook")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nook.log")
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static func log(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
