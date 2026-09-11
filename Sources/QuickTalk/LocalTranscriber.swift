import Foundation

/// One whisper-cli process per take. Nothing remains resident after `finish` or `cancel`.
///
/// Homebrew whisper-cpp 1.9.2 does read a WAV from stdin, but its CLI then treats the
/// input name `-` as an output name and suppresses every transcript segment. That was
/// verified before this implementation was written. The documented contingency is in
/// use here: `start()` validates and records key-down, while `finish` launches with the
/// completed WAV path at key-up. A future CLI that fixes stdin can move the launch back
/// into `start` without changing AppDelegate's lifecycle.
final class LocalTranscriber: @unchecked Sendable {
    enum LocalError: LocalizedError {
        case engineMissing
        case modelMissing
        case failed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .engineMissing:
                return "Install the Whisper engine in Settings."
            case .modelMissing:
                return "Download the Whisper model in Settings."
            case .failed(let detail):
                let brief = detail.count > 110 ? String(detail.prefix(107)) + "…" : detail
                return "Local transcription failed. \(brief)"
            case .empty:
                return "No speech"
            }
        }
    }

    private static let deadline: TimeInterval = 55

    let model: WhisperModel
    let threads: Int

    private let lock = NSLock()
    private var process: Process?
    private var runState: ProcessRunState?
    private var keyDown = DispatchTime.now()

    init(model: WhisperModel) {
        self.model = model
        threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    /// See the class comment: this is intentionally a no-op in the verified 1.9.2
    /// fallback, apart from failing early if Settings became stale between checks.
    func start() throws {
        guard WhisperEngine.binaryURL != nil else { throw LocalError.engineMissing }
        guard model.isInstalled else { throw LocalError.modelMissing }
        keyDown = .now()
        Diagnostics.log("local engine armed model=\(model.fileURL.path) input=file-fallback")
    }

    func finish(wav: URL) async throws -> String {
        guard let binary = WhisperEngine.binaryURL else { throw LocalError.engineMissing }
        guard model.isInstalled else { throw LocalError.modelMissing }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let state = ProcessRunState()
        let spawned = DispatchTime.now()

        process.executableURL = binary
        // `-l auto` is mandatory: whisper-cli defaults to English, which silently breaks
        // German. `-tr` must never appear; it translates German dictation into English.
        //
        // We intentionally do not pass `-np` in the 1.9.2 file fallback. With separate
        // pipes stdout is still transcript-only, while stderr retains whisper's load and
        // total timings for diagnostics; `-np` suppresses those timings in this build.
        process.arguments = [
            "-m", model.fileURL.path,
            "-f", wav.path,
            "-l", "auto",
            "-nt",
            "-t", String(threads),
            "--suppress-nst",
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.appendStdout(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            state.appendStderr(handle.availableData)
        }

        setActive(process: process, state: state)
        defer { clear(process: process, state: state) }

        let result: ProcessRunResult = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ProcessRunResult, Error>) in
                state.install(continuation)
                process.terminationHandler = { finished in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    state.appendStdout(stdout.fileHandleForReading.readDataToEndOfFile())
                    state.appendStderr(stderr.fileHandleForReading.readDataToEndOfFile())
                    state.complete(status: finished.terminationStatus)
                }

                guard !Task.isCancelled else {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    state.fail(CancellationError())
                    return
                }
                do {
                    try process.run()
                    Diagnostics.log(
                        "local engine spawn pid=\(process.processIdentifier) "
                        + "model=\(model.fileURL.path) threads=\(threads) input=file-fallback"
                    )
                    let deadline = DispatchWorkItem { [weak process, weak state] in
                        if process?.isRunning == true { process?.terminate() }
                        state?.fail(LocalError.failed("The local engine timed out."))
                    }
                    state.install(deadline)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + Self.deadline,
                        execute: deadline
                    )
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    state.fail(LocalError.failed(error.localizedDescription))
                }
            }
        }, onCancel: { [weak process, weak state] in
            if process?.isRunning == true { process?.terminate() }
            state?.fail(CancellationError())
        })

        let ended = DispatchTime.now()
        guard result.status == 0 else {
            let detail = Self.lastUsefulLine(result.stderr)
                ?? "whisper-cli exited with status \(result.status)."
            throw LocalError.failed(detail)
        }

        let text = Self.clean(result.stdout)
        guard !text.isEmpty else { throw LocalError.empty }

        Diagnostics.log(
            "local transcript chars=\(text.count) "
            + "key-down→spawn=\(Self.ms(keyDown, spawned))ms "
            + "spawn→text=\(Self.ms(spawned, ended))ms exit=\(result.status)"
        )
        if Self.ms(spawned, ended) >= 1_000 {
            for line in result.stderr.split(separator: "\n") {
                if line.contains("load time") || line.contains("total time") {
                    Diagnostics.log(String(line).trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return text
    }

    func cancel() {
        lock.lock()
        let process = self.process
        let state = runState
        self.process = nil
        runState = nil
        lock.unlock()

        if process?.isRunning == true { process?.terminate() }
        state?.fail(CancellationError())
    }

    private func setActive(process: Process, state: ProcessRunState) {
        lock.lock()
        self.process = process
        runState = state
        lock.unlock()
    }

    private func clear(process: Process, state: ProcessRunState) {
        lock.lock()
        if self.process === process { self.process = nil }
        if runState === state { runState = nil }
        lock.unlock()
    }

    private static func clean(_ output: String) -> String {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isBracketedArtifact($0) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBracketedArtifact(_ line: String) -> Bool {
        guard let first = line.first, let last = line.last else { return false }
        return (first == "[" && last == "]") || (first == "(" && last == ")")
    }

    private static func lastUsefulLine(_ stderr: String) -> String? {
        stderr
            .split(whereSeparator: \Character.isNewline)
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func ms(_ from: DispatchTime, _ to: DispatchTime) -> Int {
        Int((to.uptimeNanoseconds &- from.uptimeNanoseconds) / 1_000_000)
    }
}

private struct ProcessRunResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Owns the one checked continuation and its DispatchWorkItem deadline. The process exit,
/// cancellation and deadline may arrive on different queues; the lock makes exactly one
/// of them the resume path, and every path cancels the deadline before resuming.
private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var continuation: CheckedContinuation<ProcessRunResult, Error>?
    private var deadline: DispatchWorkItem?
    private var completed = false

    func install(_ continuation: CheckedContinuation<ProcessRunResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func install(_ deadline: DispatchWorkItem) {
        lock.lock()
        if completed {
            lock.unlock()
            deadline.cancel()
            return
        }
        self.deadline = deadline
        lock.unlock()
    }

    func appendStdout(_ data: Data) { append(data, toStdout: true) }
    func appendStderr(_ data: Data) { append(data, toStdout: false) }

    private func append(_ data: Data, toStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if toStdout { stdout.append(data) } else { stderr.append(data) }
        lock.unlock()
    }

    func complete(status: Int32) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        deadline?.cancel()
        self.continuation = nil
        let result = ProcessRunResult(
            status: status,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        lock.unlock()
        continuation.resume(returning: result)
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        deadline?.cancel()
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
