// Persistent line-oriented log file. On in debug builds, and in Release
// when verbose logging is on. macOS never
// persists os_log `.debug` lines, so after a bug the only thing left in
// `log show` is `.notice` and above — the interesting trace evidence is
// already gone. This file takes every `hyprLog` call at every level and
// category so the evidence survives.

import Foundation
import os

/// Append-only text log under `~/Library/Logs/HyprMac/`.
///
/// One line per `hyprLog` call:
/// `2026-09-12T19:41:02.123-0500 [notice] [discovery] message`
///
/// Writes go through a private serial queue with a kept-open
/// `FileHandle`. The file rotates to `<name>.log.1` once it grows past
/// `maxBytes`, replacing any previous archive — so at most two files,
/// bounded at roughly `2 * maxBytes`.
///
/// Construction never throws and never traps: if the directory or the
/// file cannot be created the instance reports `isAvailable == false`,
/// every `append` is a no-op, and one `.notice` goes out through os_log
/// saying so.
final class DebugLogFile {

    /// Process-wide instance used by `hyprLog`. Created on first use, so
    /// nothing touches the filesystem until something actually logs.
    static let shared = DebugLogFile()

    /// Ceiling before rotation. 20 MB holds hours of trace logging.
    static let defaultMaxBytes: UInt64 = 20 * 1024 * 1024

    /// Destination file. Valid to read even when the log is disabled —
    /// startup logs the path either way.
    let fileURL: URL

    /// False when the directory or file could not be opened. Fixed at
    /// construction; `append` and `flush` become no-ops.
    let isAvailable: Bool

    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "com.zachgray.HyprMac.debuglogfile")
    private let stamp: DateFormatter

    // queue-confined
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0

    /// Default location: `~/Library/Logs/HyprMac/<bundle id>.log`.
    /// Falls back to the release bundle id when there is none (tests).
    convenience init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.zachgray.HyprMac"
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/HyprMac", isDirectory: true)
        self.init(directory: directory, fileName: "\(bundleID).log")
    }

    init(directory: URL, fileName: String, maxBytes: UInt64 = DebugLogFile.defaultMaxBytes) {
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        self.maxBytes = maxBytes

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        self.stamp = stamp

        let fm = FileManager.default
        var opened: FileHandle?
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            opened = try FileHandle(forWritingTo: fileURL)
        } catch {
            opened = nil
        }
        handle = opened
        isAvailable = opened != nil
        bytesWritten = ((try? opened?.seekToEnd()) ?? nil) ?? 0

        if !isAvailable {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.zachgray.HyprMac",
                   category: LogCategory.lifecycle.rawValue)
                .notice("file log unavailable at \(self.fileURL.path, privacy: .public)")
        }
    }

    /// Queue one line. Cheap on the caller's thread: the timestamp is
    /// taken here so ordering is honest, the formatting and the write
    /// happen on the serial queue.
    func append(level: LogLevel, category: LogCategory, message: String, date: Date = Date()) {
        guard isAvailable else { return }
        queue.async { [self] in
            write("\(stamp.string(from: date)) [\(level.label)] [\(category.rawValue)] \(message)\n")
        }
    }

    /// Drain the queue and sync the handle. Tests read the file right
    /// after; a crash-time flush is not needed because each `write`
    /// already hits the file descriptor.
    func flush() {
        guard isAvailable else { return }
        queue.sync { try? handle?.synchronize() }
    }

    // MARK: - queue-confined

    private func write(_ line: String) {
        guard let handle, let data = line.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // a dead descriptor stays dead — stop trying rather than
            // throwing an error per log line for the rest of the session.
            self.handle = nil
            return
        }
        bytesWritten += UInt64(data.count)
        if bytesWritten > maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        bytesWritten = 0

        let archive = fileURL.appendingPathExtension("1")
        let fm = FileManager.default
        try? fm.removeItem(at: archive)
        do {
            try fm.moveItem(at: fileURL, to: archive)
            fm.createFile(atPath: fileURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            handle = nil
        }
    }
}
