//
//  VoIPDiagnosticsLog.swift
//  Hivelink
//

import Foundation
import OSLog
import HivecrewShared

enum VoIPDiagnosticsLog {
    private static let logger = Logger(subsystem: "com.pattonium.Hivelink", category: "VoIP")
    private static let queue = DispatchQueue(label: "com.pattonium.Hivelink.voip-log")
    private static let maxLogBytes: Int64 = 512 * 1024

    static let fileURL = AppPaths.logsDirectory.appendingPathComponent("hivelink-voip.log")

    static func log(_ message: String) {
        print(message)
        logger.info("\(message, privacy: .public)")

        let line = "[\(timestamp())] \(message)\n"
        queue.async {
            append(line)
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func append(_ line: String) {
        let data = Data(line.utf8)
        let fm = FileManager.default

        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > maxLogBytes {
            try? Data().write(to: fileURL, options: .atomic)
        }

        if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
