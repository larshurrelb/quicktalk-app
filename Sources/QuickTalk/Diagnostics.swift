import Foundation

/// A small append-only log, so a failure can be inspected instead of guessed at.
///
/// Writes only while dictating — nothing is logged when the app is idle. The API key is
/// never passed in here, and transcript text is recorded by length only, not content.
enum Diagnostics {
    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("QuickTalk.log")
    }()

    private static let queue = DispatchQueue(label: "com.quicktalk.QuickTalk.diagnostics")
    private static var lastErrorText: String?

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(redacting(message))\n"

        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    static func recordError(_ message: String) {
        queue.sync { lastErrorText = redacting(message) }
        log("ERROR \(message)")
    }

    /// Last-ditch guard against a credential reaching the log.
    ///
    /// Nothing is supposed to pass the key in here — `KeyStore` logs failures only, and
    /// the transcribers put it in a header, never a logged string. This exists because
    /// `Copy Diagnostics` puts the log on the clipboard, so a single careless
    /// `Diagnostics.log("\(request)")` added later would be a credential in a pasted bug
    /// report.
    ///
    /// Both Google key formats are covered: the older `AIza…` and the current `AQ.…`.
    /// Missing the second one would have made this guard useless for every key issued
    /// today, so add a pattern here rather than assuming one shape.
    static func redacting(_ message: String) -> String {
        var text = message
        for pattern in ["AIza[0-9A-Za-z_\\-]{10,}", "AQ\\.[0-9A-Za-z_\\-.]{10,}"] {
            text = text.replacingOccurrences(
                of: pattern,
                with: "…redacted…",
                options: .regularExpression
            )
        }
        return text
    }

    static var lastError: String? {
        queue.sync { lastErrorText }
    }

    /// Everything needed to diagnose a failure, minus anything secret.
    static func report() -> String {
        let tail = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n")
            .suffix(40)
            .joined(separator: "\n") ?? "(no log yet)"

        return """
        QuickTalk diagnostics
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Last error: \(lastError ?? "none")

        Recent log:
        \(tail)
        """
    }
}
