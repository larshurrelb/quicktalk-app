import Foundation

/// Finds and installs the external whisper.cpp command-line engine.
///
/// QuickTalk deliberately does not link whisper.cpp. Homebrew owns the executable and
/// all of its libraries, which keeps the app bundle dependency-free and lets the model
/// remain downloadable data rather than something shipped in the app.
enum WhisperEngine {
    static let installCommand = "brew install whisper-cpp"

    private static let lock = NSLock()
    private static var didResolve = false
    private static var cachedBinary: URL?

    /// GUI apps do not inherit a useful shell PATH. The two Homebrew prefixes are the
    /// real lookup; PATH is only a courtesy for a manually installed compatible binary.
    static var binaryURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        if didResolve { return cachedBinary }

        let manager = FileManager.default
        let fixed = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
        if let path = fixed.first(where: { manager.isExecutableFile(atPath: $0) }) {
            cachedBinary = URL(fileURLWithPath: path)
        } else {
            cachedBinary = ProcessInfo.processInfo.environment["PATH"]?
                .split(separator: ":")
                .map(String.init)
                .map { URL(fileURLWithPath: $0).appendingPathComponent("whisper-cli") }
                .first(where: { manager.isExecutableFile(atPath: $0.path) })
        }
        didResolve = true
        return cachedBinary
    }

    static func invalidateBinaryCache() {
        lock.lock()
        didResolve = false
        cachedBinary = nil
        lock.unlock()
    }

    /// The 1.9.2 Homebrew build prints its version from `--version`; its `-h` first line
    /// is backend noise, so retain help as a compatibility fallback rather than showing
    /// a Metal library path as the version in Settings.
    static func version() -> String? {
        guard let binaryURL else { return nil }
        for argument in ["--version", "-h"] {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = binaryURL
            process.arguments = [argument]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(decoding: data, as: UTF8.self)
                if let match = output.range(
                    of: #"whisper(?:\.cpp)?\s+version:\s*([^\s]+)"#,
                    options: .regularExpression
                ) {
                    let line = String(output[match])
                    if let value = line.split(separator: ":", maxSplits: 1).last {
                        return "whisper-cli \(value.trimmingCharacters(in: .whitespaces))"
                    }
                }
            } catch {
                continue
            }
        }
        return "whisper-cli"
    }

    /// Installs through an explicitly located Homebrew with an explicitly useful GUI
    /// environment. No shell is involved and therefore no quoting or profile loading is
    /// required. `update` receives the latest non-empty output line for Settings.
    static func install(update: @escaping @Sendable (String) -> Void) async throws {
        let manager = FileManager.default
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = candidates.first(where: { manager.isExecutableFile(atPath: $0) }) else {
            throw EngineError.homebrewMissing
        }

        let process = Process()
        let pipe = Pipe()
        let output = LockedOutput()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "whisper-cpp"]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(data)
            if let line = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \Character.isNewline)
                .last {
                update(String(line))
            }
        }

        let status = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            if process.isRunning { process.terminate() }
        })

        guard status == 0 else {
            throw EngineError.installFailed(output.lastLine ?? "Homebrew exited with status \(status).")
        }
        invalidateBinaryCache()
    }

    enum EngineError: LocalizedError {
        case homebrewMissing
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .homebrewMissing:
                return "Homebrew wasn't found. Copy the command and run it in Terminal."
            case .installFailed(let detail):
                return "Couldn't install whisper-cpp: \(detail)"
            }
        }
    }
}

private final class LockedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var lastLine: String? {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .last
            .map(String.init)
    }
}
