import Foundation

/// Streaming transcription over the Gemini Live socket.
///
/// The batch path pays a fixed ~2.9s after you let go of the key — measured across real
/// dictations, and almost independent of how long you spoke. This sends audio *while*
/// you speak, so by key-up only the tail is outstanding.
///
/// It is deliberately failure-tolerant: every error path is recoverable, because the
/// caller still holds the recorded WAV and can fall back to the batch request. Losing
/// words is never acceptable; being slow is.
final class LiveTranscriber {
    enum LiveError: LocalizedError {
        case setupTimeout
        case socket(String)
        case noTranscript

        var errorDescription: String? {
            switch self {
            case .setupTimeout: return "live setup timed out"
            case let .socket(detail): return "live socket failed: \(detail)"
            case .noTranscript: return "live returned no transcript"
            }
        }
    }

    /// The credential goes in the header, never in the query string — a `?key=` lands in
    /// proxy and crash logs verbatim.
    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private static let model = "gemini-3.5-transcribe-live"
    private static let audioMIME = "audio/pcm;rate=16000"

    private let apiKey: String
    private let smart: Bool
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    /// All frames go out through one serial queue. `URLSessionWebSocketTask` preserves
    /// the order of queued sends, so this is also what guarantees `activityEnd` cannot
    /// overtake the audio in front of it — the server finalises on what it has received,
    /// and an end signal that jumps the queue truncates the last words.
    private let sendQueue = DispatchQueue(label: "com.quicktalk.QuickTalk.live.send")

    private let lock = NSLock()
    private var setupDone = false
    private var buffered: [Data] = []
    private var finals: [String] = []
    private var latestPartial = ""
    private var setupWaiter: CheckedContinuation<Void, Error>?
    private var finishWaiter: CheckedContinuation<String, Error>?
    private var terminated = false

    /// Interim text, for showing progress while the user is still talking.
    var onPartial: ((String) -> Void)?

    init(apiKey: String, smart: Bool) {
        self.apiKey = apiKey
        self.smart = smart

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Lifecycle

    /// Connects and waits for the server to acknowledge setup. Audio may be appended
    /// before this returns — it is buffered and flushed in order.
    func start(setupDeadline: TimeInterval = 5) async throws {
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receiveLoop()

        send(Self.setupFrame(smart: smart))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { continuation in
                    guard let self else { return continuation.resume() }
                    self.lock.lock()
                    if self.setupDone {
                        self.lock.unlock()
                        continuation.resume()
                    } else {
                        self.setupWaiter = continuation
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(setupDeadline * 1_000_000_000))
                throw LiveError.setupTimeout
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Safe to call from the audio thread.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        let frame = Self.audioFrame(pcm)

        lock.lock()
        if !setupDone {
            buffered.append(frame)
            lock.unlock()
            return
        }
        lock.unlock()
        send(frame)
    }

    /// Ends the turn and waits for the server's final transcript.
    func finish(deadline: TimeInterval = 6) async throws -> String {
        // Queued behind every audio frame already sent, by construction.
        send(Self.activityEndFrame())

        let text = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { continuation in
                    guard let self else { return continuation.resume(throwing: LiveError.noTranscript) }
                    self.lock.lock()
                    if !self.finals.isEmpty {
                        let joined = self.finals.joined(separator: " ")
                        self.lock.unlock()
                        continuation.resume(returning: joined)
                    } else {
                        self.finishWaiter = continuation
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                throw LiveError.noTranscript
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LiveError.noTranscript }
        return trimmed
    }

    func cancel() {
        lock.lock()
        terminated = true
        let waiters = (setupWaiter, finishWaiter)
        setupWaiter = nil
        finishWaiter = nil
        lock.unlock()

        waiters.0?.resume(throwing: LiveError.socket("cancelled"))
        waiters.1?.resume(throwing: LiveError.noTranscript)

        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Socket plumbing

    private func send(_ frame: Data) {
        sendQueue.async { [weak self] in
            self?.task?.send(.data(frame)) { _ in }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .data(data): self.handle(data)
                case let .string(text): self.handle(Data(text.utf8))
                @unknown default: break
                }
                self.receiveLoop()
            case let .failure(error):
                self.fail(error.localizedDescription)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        if root["setupComplete"] != nil || root["setup_complete"] != nil {
            completeSetup()
            return
        }

        if let error = root["error"] as? [String: Any] {
            fail(error["message"] as? String ?? "unknown live error")
            return
        }

        let content = (root["serverContent"] ?? root["server_content"]) as? [String: Any]
        guard let content else { return }

        if content["goAway"] != nil || content["go_away"] != nil {
            fail("server sent goAway")
            return
        }

        // Interim is checked first: a frame can carry both, and treating an interim as
        // final is what puts speculative text on the user's cursor.
        if let text = Self.transcript(content, "interimInputTranscription", "interim_input_transcription") {
            lock.lock(); latestPartial = text; lock.unlock()
            let partial = text
            DispatchQueue.main.async { [onPartial] in onPartial?(partial) }
            return
        }

        if let text = Self.transcript(content, "inputTranscription", "input_transcription") {
            lock.lock()
            finals.append(text)
            let waiter = finishWaiter
            finishWaiter = nil
            let joined = finals.joined(separator: " ")
            lock.unlock()
            waiter?.resume(returning: joined)
        }
    }

    private func completeSetup() {
        lock.lock()
        guard !setupDone else { return lock.unlock() }
        setupDone = true
        let pending = buffered
        buffered = []
        let waiter = setupWaiter
        setupWaiter = nil
        lock.unlock()

        // The turn opens explicitly: automatic voice detection is disabled, because the
        // hotkey decides where turns begin and end. Server-side VAD would cut the turn
        // whenever the speaker paused to think.
        send(Self.activityStartFrame())
        for frame in pending { send(frame) }

        waiter?.resume()
    }

    private func fail(_ detail: String) {
        lock.lock()
        guard !terminated else { return lock.unlock() }
        terminated = true
        let setup = setupWaiter
        let finish = finishWaiter
        setupWaiter = nil
        finishWaiter = nil
        let collected = finals.joined(separator: " ")
        lock.unlock()

        setup?.resume(throwing: LiveError.socket(detail))
        // A drop after some text arrived still has words worth keeping.
        if collected.isEmpty {
            finish?.resume(throwing: LiveError.socket(detail))
        } else {
            finish?.resume(returning: collected)
        }
    }

    // MARK: - Frames

    /// **Never add `languageCodes` here.** On the batch endpoint, pairing it with smart
    /// mode silently returns verbatim output with no error of any kind; the live socket
    /// accepts both fields in the same object and the published example pairs them, which
    /// is exactly how that bug would ship a second time. Omitting it is also what gives
    /// automatic language detection.
    private static func setupFrame(smart: Bool) -> Data {
        let frame: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": ["mode": smart ? "SMART" : "VERBATIM"],
                "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    private static func audioFrame(_ pcm: Data) -> Data {
        let frame: [String: Any] = [
            "realtimeInput": ["audio": ["data": pcm.base64EncodedString(), "mimeType": audioMIME]],
        ]
        return (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
    }

    private static func activityStartFrame() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["realtimeInput": ["activityStart": [String: Any]()]])) ?? Data()
    }

    private static func activityEndFrame() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["realtimeInput": ["activityEnd": [String: Any]()]])) ?? Data()
    }

    /// Both spellings are accepted because the documented clients disagree about which
    /// the socket speaks, and guessing wrong looks identical to a model that transcribes
    /// nothing.
    private static func transcript(_ content: [String: Any], _ camel: String, _ snake: String) -> String? {
        guard let node = (content[camel] ?? content[snake]) as? [String: Any],
              let text = node["text"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }
}
