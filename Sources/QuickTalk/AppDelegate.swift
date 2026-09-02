import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let recorder = AudioRecorder()
    private let pill = PillHUD()

    private let frontmost = FrontmostAppTracker()

    private var statusItem: NSStatusItem?
    private var hotkey: HotkeyMonitor?
    private var settingsWindow: SettingsWindowController?
    private var appRulesWindow: AppRulesWindowController?

    /// Below this, a press was a tap on the modifier rather than an attempt to dictate.
    private let minimumHold: TimeInterval = 0.25
    /// Below this peak level a take is silence — see the note where it is used.
    private static let silenceThreshold: Float = 0.006
    /// Longest a take may sit in transcription before the app gives up on it.
    ///
    /// Generous on purpose: a batch request allows 30s and the formatting pass another 15,
    /// and cutting a slow-but-working request short would throw the dictation away. This
    /// is not a timeout, it is the guarantee that a stuck pill cannot outlive one take.
    private static let transcriptionCeiling: TimeInterval = 60

    /// Where the current dictation is.
    ///
    /// Tracked here rather than asked of the recorder, because the microphone now opens
    /// asynchronously: between the key going down and the device answering there is no
    /// useful answer to "are we recording?" — and that window is exactly where a key
    /// release used to be dropped on the floor.
    private enum Phase {
        case idle
        /// Key down, microphone still opening.
        case opening
        /// Key down, capturing.
        case recording
        /// Key up, transcription in flight.
        case transcribing
    }

    private var startedAt: Date?
    private var phase: Phase = .idle
    /// Identifies the current dictation, so a callback belonging to an abandoned one is
    /// ignored instead of acted on. Bumped once per key-down and never in between.
    private var takeID = 0
    /// Set when the key came back up before the microphone finished opening.
    private var stopRequested = false
    private var transcription: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var trustWatcher: Timer?
    private var live: LiveTranscriber?

    /// The instructions for the app that was frontmost when the key went down, captured
    /// at the *start* of the take. By the time the transcript comes back the user may
    /// well have switched windows; the app they were in when they started talking is the
    /// one they meant.
    private var takeInstructions = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        appRulesWindow = AppRulesWindowController(
            store: settings.appRules,
            settings: settings,
            frontmost: frontmost
        )

        settingsWindow = SettingsWindowController(
            settings: settings,
            onHotkeyChange: { [weak self] key in self?.hotkey?.key = key },
            onManageApps: { [weak self] in self?.appRulesWindow?.show() }
        )

        recorder.onLevel = { [weak self] level in
            self?.pill.update(level: level)
        }

        startHotkey()

        // First run: nothing works without a key and permissions, so say so up front
        // rather than failing silently on the first press.
        if !settings.hasAPIKey || !HotkeyMonitor.canObserveKeys {
            settingsWindow?.show()
        }
    }

    /// Coming back to the app is a good moment to notice a permission granted in
    /// System Settings while we were in the background.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard HotkeyMonitor.canObserveKeys, let hotkey else { return }
        hotkey.stop()
        _ = hotkey.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        // Blocking here is fine and `discard()` no longer does: it became fire-and-forget
        // when capture moved off the main thread, which on quit means the process can exit
        // before the take is cleaned up.
        recorder.discardAndWait()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "QuickTalk"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Hold \(settings.hotkey.label) to dictate", action: nil, keyEquivalent: "")
        menu.items.first?.isEnabled = false

        // Which app the next dictation would land in, and whether it has instructions.
        // Both are refreshed in menuWillOpen; the title here is only a placeholder.
        menu.addItem(.separator())
        let target = NSMenuItem(title: "Dictating into…", action: #selector(openAppRules(_:)), keyEquivalent: "")
        target.target = self
        target.identifier = Self.targetItemID
        menu.addItem(target)

        // Formatting is the one setting worth changing mid-flow — which mode suits the
        // next thing you dictate changes constantly — so it lives here rather than only
        // behind the Settings window.
        menu.addItem(.separator())
        let heading = NSMenuItem(title: "Formatting", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        for mode in TranscriptionMode.allCases {
            let entry = NSMenuItem(
                title: mode.label,
                action: #selector(selectMode(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = (mode == settings.mode) ? .on : .off
            // Indented so the checkmarks read as a group under the heading.
            entry.indentationLevel = 1
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "App Instructions…", action: #selector(openAppRules(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit QuickTalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        item.menu = menu

        statusItem = item
    }

    /// Refreshed on open rather than pushed from elsewhere: this keeps the checkmarks
    /// and the permission warning correct no matter where a change came from.
    func menuWillOpen(_ menu: NSMenu) {
        refreshModeChecks()
        refreshStatusTitle()
        refreshTargetItem()
    }

    private static let targetItemID = NSUserInterfaceItemIdentifier("targetApp")

    /// Shows the app the hotkey would dictate into, and turns into a shortcut to its
    /// rule. Reading it here rather than tracking it live is the same trade the mode
    /// checkmarks make: the answer only has to be right while the menu is on screen.
    private func refreshTargetItem() {
        guard let item = statusItem?.menu?.items.first(where: { $0.identifier == Self.targetItemID })
        else { return }

        guard let app = frontmost.refresh() else {
            item.title = "App Instructions…"
            return
        }

        let rule = settings.appRules.rule(for: app.bundleID)
        item.title = rule?.isActive == true
            ? "\(app.name) — instructions on"
            : "Add instructions for \(app.name)…"
        // A rule that exists but is switched off or still blank is neither of the above.
        if let rule, !rule.isActive {
            item.title = "\(app.name) — instructions \(rule.isEnabled ? "empty" : "off")"
        }
    }

    /// Opens the rules window, on the frontmost app's own rule when there is one to show.
    @objc private func openAppRules(_ sender: NSMenuItem) {
        // Only the "Dictating into" row carries a bundle ID; the plain menu entry opens
        // the window as-is rather than silently adding whatever was in front.
        let app = (sender.identifier == Self.targetItemID) ? frontmost.current : nil
        appRulesWindow?.show(selecting: app)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TranscriptionMode(rawValue: raw)
        else { return }

        settings.mode = mode
        refreshModeChecks()

        // The Settings window reads the mode once when it is built, so it would show a
        // stale selection after a change made here.
        settingsWindow?.reloadIfVisible()
    }

    private func refreshModeChecks() {
        guard let items = statusItem?.menu?.items else { return }
        for item in items {
            guard let raw = item.representedObject as? String,
                  let mode = TranscriptionMode(rawValue: raw)
            else { continue }
            item.state = (mode == settings.mode) ? .on : .off
        }
    }

    @objc private func openSettings() {
        settingsWindow?.show()
    }

    /// Puts the recent log on the clipboard — the fastest way to find out what actually
    /// failed, since the pill only has room for a sentence.
    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
        flash(.success)
    }

    private func refreshStatusTitle() {
        let title: String
        if !HotkeyMonitor.hasInputMonitoringPermission {
            title = "⚠︎ Input Monitoring not granted — hotkey inactive"
        } else if !HotkeyMonitor.hasAccessibilityPermission {
            title = "⚠︎ Accessibility not granted — can't paste"
        } else {
            title = "Hold \(settings.hotkey.label) to dictate"
        }
        statusItem?.menu?.items.first?.title = title
    }

    // MARK: - Hotkey

    private func startHotkey() {
        let monitor = HotkeyMonitor(
            key: settings.hotkey,
            onDown: { [weak self] in self?.beginRecording() },
            onUp: { [weak self] in self?.endRecording() }
        )

        if !monitor.start() {
            HotkeyMonitor.requestAccessibilityPermission()
        }
        hotkey = monitor
        refreshStatusTitle()

        if !HotkeyMonitor.canObserveKeys {
            HotkeyMonitor.requestInputMonitoringPermission()
            watchForTrust()
        }
    }

    /// An event tap created before the app is trusted for Accessibility is not an error —
    /// it just quietly only ever receives this app's *own* events, which looks exactly
    /// like "the hotkey works, but only while QuickTalk is frontmost". Granting permission
    /// does not upgrade a tap that already exists, so the tap has to be rebuilt once trust
    /// arrives. Polling stops the moment it does.
    private func watchForTrust() {
        trustWatcher?.invalidate()
        trustWatcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard HotkeyMonitor.canObserveKeys else { return }
            timer.invalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                self.trustWatcher = nil
                Diagnostics.log("permissions granted — rebuilding event tap")
                self.hotkey?.stop()
                _ = self.hotkey?.start()
            }
        }
    }

    // MARK: - Dictation

    private func beginRecording() {
        guard case .idle = phase else {
            // Almost always a second press while the previous take is still transcribing.
            // Recorded rather than silently dropped, because "I pressed it and nothing
            // happened" is otherwise indistinguishable from a dead hotkey.
            Diagnostics.log("press ignored — take \(takeID) is still \(phase)")
            return
        }

        guard AudioRecorder.hasMicrophoneAccess else {
            AudioRecorder.requestMicrophoneAccess { [weak self] granted in
                if !granted { self?.flash(.failure("Microphone access needed")) }
            }
            return
        }

        guard settings.hasAPIKey else {
            flash(.failure("Add your Gemini API key"))
            settingsWindow?.show()
            return
        }

        captureTarget()

        takeID &+= 1
        let take = takeID
        phase = .opening
        stopRequested = false
        startedAt = Date()

        // Feedback first, hardware second. Opening a microphone is neither quick nor
        // bounded — measured at up to three seconds with Bluetooth headphones connected —
        // and the pill used to wait behind it, which is what made dictation feel like it
        // had not started at all. The hold is timed from here, so a slow device costs
        // audio but never costs the press.
        pill.show(.listening)
        if settings.playSound { NSSound(named: settings.startSound)?.play() }

        if settings.mode.usesLive { startLiveSession(smart: settings.mode.liveSmart) }

        let recorder = self.recorder
        let uid = settings.microphoneUID
        Task { [weak self] in
            do {
                try await recorder.start(deviceUID: uid)
                self?.microphoneOpened(take: take)
            } catch {
                self?.microphoneFailed(take: take, error: error)
            }
        }
    }

    /// The microphone answered.
    private func microphoneOpened(take: Int) {
        guard take == takeID, case .opening = phase else {
            // The take was abandoned while the device was opening, so capture is now
            // running for a dictation nobody is waiting for. `onPCM` is left alone — a
            // newer take may already own it, and the closure holds its session weakly.
            recorder.discard()
            return
        }
        phase = .recording
        // The release arrived during the wait. Honouring it here rather than dropping it
        // is the difference between a short take and a recorder that never stops.
        if stopRequested { finishTake() }
    }

    private func microphoneFailed(take: Int, error: Error) {
        guard take == takeID else { return }
        phase = .idle
        stopRequested = false
        startedAt = nil
        // Capture never started, but the live session set a PCM callback that has to go.
        recorder.discard()
        live?.cancel()
        live = nil
        Diagnostics.recordError("recorder failed to start: \(error)")
        flash(.failure("Couldn't start the microphone — see Copy Diagnostics"))
    }

    /// Notes which app this take is for, and the instructions that go with it.
    ///
    /// Only Smart mode has a formatting pass to feed them into — the live socket and the
    /// batch transcribe endpoint both ignore prompts entirely — so in the other modes
    /// there is nothing to carry and the rule is deliberately not read.
    private func captureTarget() {
        let app = frontmost.refresh()
        takeInstructions = settings.mode.needsFormattingPass
            ? settings.appRules.instructions(for: app?.bundleID)
            : ""

        // Length only, never the text: the log goes on the clipboard via Copy Diagnostics.
        Diagnostics.log(
            "target app \(app?.bundleID ?? "unknown") instructions=\(takeInstructions.isEmpty ? "none" : "\(takeInstructions.count) chars")"
        )
    }

    private func endRecording() {
        switch phase {
        case .idle, .transcribing:
            return
        case .opening:
            // The key is already back up and the device has not answered yet. Remember it;
            // `microphoneOpened` acts on it the moment capture actually exists.
            stopRequested = true
        case .recording:
            finishTake()
        }
    }

    private func finishTake() {
        let held = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        stopRequested = false

        guard held >= minimumHold else {
            phase = .idle
            // `discard` drops the PCM callback too, on the queue where that is safe.
            recorder.discard()
            live?.cancel()
            live = nil
            pill.dismiss()
            return
        }

        // Claimed now, before the file is closed, so a press landing in that gap is turned
        // away by `beginRecording` rather than starting a second overlapping take.
        phase = .transcribing
        let take = takeID
        // Armed here rather than once the upload starts, so that every route out of
        // `.transcribing` — closing the file included — is covered by it.
        armWatchdog(for: take)

        let recorder = self.recorder
        Task { [weak self] in
            let recorded = await recorder.stop()
            self?.recordingClosed(take: take, recorded: recorded)
        }
    }

    private func recordingClosed(take: Int, recorded: AudioRecorder.Take?) {
        guard take == takeID, case .transcribing = phase else { return }

        let session = live
        live = nil

        guard let recorded else {
            session?.cancel()
            endTranscription(take)
            pill.dismiss()
            return
        }

        // Observed peaks: real speech 0.019 and up, silence 0.000–0.002. Below the gate
        // the API would return an empty transcript anyway, so skip the round trip and
        // answer instantly instead of waiting three seconds to say nothing happened.
        if recorded.peakLevel < Self.silenceThreshold {
            Diagnostics.log("skipped upload — peakLevel=\(String(format: "%.3f", recorded.peakLevel)) is silence")
            try? FileManager.default.removeItem(at: recorded.fileURL)
            // Close the socket too, or a silent take leaves one open every time.
            session?.cancel()
            endTranscription(take)
            pill.update(state: .silent)
            pill.dismiss(after: 1.1)
            return
        }

        if settings.playSound { NSSound(named: "Pop")?.play() }
        pill.update(state: .transcribing)

        let transcriber = GeminiTranscriber(apiKey: settings.apiKey)
        let mode = settings.mode
        let instructions = takeInstructions
        let fileURL = recorded.fileURL

        transcription = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                // Live first when it is running: most of the audio is already transcribed
                // by the time the key comes up. The recorded file is still on disk, so a
                // socket that failed costs latency, never words.
                var text: String
                if let session {
                    do {
                        text = try await session.finish()
                        Diagnostics.log("live transcript \(text.count) chars")
                        // The whole point of streaming: the transcript is already in hand
                        // at key-up, so the formatting model starts now rather than after
                        // a batch round trip.
                        if mode.needsFormattingPass {
                            text = await transcriber.applyFormatting(text, instructions: instructions)
                        }
                    } catch {
                        Diagnostics.log("live failed (\(error.localizedDescription)) — falling back to batch")
                        text = try await transcriber.transcribe(
                            fileURL: fileURL,
                            smart: mode.batchSmart,
                            format: mode.needsFormattingPass,
                            instructions: instructions
                        )
                    }
                } else {
                    text = try await transcriber.transcribe(
                        fileURL: fileURL,
                        smart: mode.batchSmart,
                        format: mode.needsFormattingPass,
                        instructions: instructions
                    )
                }
                self?.takeSucceeded(take: take, text: text)
            } catch {
                self?.takeFailed(take: take, error: error)
            }
        }
    }

    private func takeSucceeded(take: Int, text: String) {
        guard endTranscription(take) else { return }
        TextInserter.insert(text)
        pill.update(state: .success)
        pill.dismiss(after: 0.6)
    }

    private func takeFailed(take: Int, error: Error) {
        guard endTranscription(take) else { return }

        if case GeminiTranscriber.TranscribeError.empty = error {
            Diagnostics.log("no speech in the transcript")
            pill.update(state: .silent)
            pill.dismiss(after: 1.1)
            return
        }
        let message = (error as? LocalizedError)?.errorDescription ?? "Transcription failed"
        Diagnostics.recordError(message)
        pill.update(state: .failure(message))
        pill.dismiss(after: 2.6)
    }

    /// Returns the app to idle if `take` is still the one in flight. False means the
    /// answer belongs to a take that was already abandoned, and must not touch the pill.
    @discardableResult
    private func endTranscription(_ take: Int) -> Bool {
        guard take == takeID, case .transcribing = phase else { return false }
        watchdog?.cancel()
        watchdog = nil
        transcription = nil
        phase = .idle
        return true
    }

    /// The backstop that makes a permanently stuck pill impossible.
    ///
    /// Every network path already has its own deadline, and the live socket's deadlock —
    /// which is what actually stranded takes on "Transcribing…" — is fixed at the source
    /// in `LiveTranscriber`. This exists so that the *next* hang, wherever it comes from,
    /// costs one dictation instead of requiring a relaunch.
    private func armWatchdog(for take: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.transcriptionCeiling * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard take == self.takeID, case .transcribing = self.phase else { return }

            self.transcription?.cancel()
            self.transcription = nil
            self.watchdog = nil
            self.live?.cancel()
            self.live = nil
            self.phase = .idle
            Diagnostics.recordError("gave up on the transcript after \(Int(Self.transcriptionCeiling))s")
            self.pill.update(state: .failure("Transcription gave up. Press again to retry."))
            self.pill.dismiss(after: 2.6)
        }
    }

    /// Opens the socket while the user is still pressing the key. Setup takes a moment,
    /// and audio recorded before it completes is buffered rather than dropped.
    private func startLiveSession(smart: Bool) {
        let session = LiveTranscriber(apiKey: settings.apiKey, smart: smart)
        live = session
        recorder.onPCM = { [weak session] pcm in session?.append(pcm) }

        Task { [weak self] in
            do {
                try await session.start()
                Diagnostics.log("live session ready")
            } catch {
                Diagnostics.log("live setup failed (\(error.localizedDescription)) — batch will be used")
                await MainActor.run {
                    guard let self, self.live === session else { return }
                    self.live = nil
                }
                // The callback is left in place: capture may well still be running, and
                // clearing it from here would race the audio thread. It holds the session
                // weakly and `close()` drops it, so a dead session costs nothing.
                session.cancel()
            }
        }
    }

    private func flash(_ state: PillState) {
        pill.show(state)
        pill.dismiss(after: 2.0)
    }
}
