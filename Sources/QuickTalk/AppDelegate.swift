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
    private var startedAt: Date?
    private var isBusy = false
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
        recorder.discard()
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
        guard !isBusy, !recorder.isRecording else { return }

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

        do {
            if settings.mode.usesLive { startLiveSession(smart: settings.mode.liveSmart) }
            try recorder.start(deviceUID: settings.microphoneUID)
            startedAt = Date()
            pill.show(.listening)
            if settings.playSound { NSSound(named: settings.startSound)?.play() }
        } catch {
            live?.cancel()
            live = nil
            Diagnostics.recordError("recorder failed to start: \(error)")
            flash(.failure("Couldn't start the microphone — see Copy Diagnostics"))
        }
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
        guard recorder.isRecording else { return }

        let held = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil

        guard held >= minimumHold else {
            recorder.discard()
            live?.cancel()
            live = nil
            pill.dismiss()
            return
        }

        guard let fileURL = recorder.stop() else {
            live?.cancel()
            live = nil
            pill.dismiss()
            return
        }
        recorder.onPCM = nil

        // Observed peaks: real speech 0.019 and up, silence 0.000–0.002. Below the gate
        // the API would return an empty transcript anyway, so skip the round trip and
        // answer instantly instead of waiting three seconds to say nothing happened.
        if recorder.peakLevel < Self.silenceThreshold {
            Diagnostics.log("skipped upload — peakLevel=\(String(format: "%.3f", recorder.peakLevel)) is silence")
            try? FileManager.default.removeItem(at: fileURL)
            // Close the socket too, or a silent take leaves one open every time.
            live?.cancel()
            live = nil
            pill.update(state: .silent)
            pill.dismiss(after: 1.1)
            return
        }

        if settings.playSound { NSSound(named: "Pop")?.play() }
        pill.update(state: .transcribing)
        isBusy = true

        let transcriber = GeminiTranscriber(apiKey: settings.apiKey)
        let mode = settings.mode
        let session = live
        let instructions = takeInstructions
        live = nil

        Task { [weak self] in
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
                await MainActor.run {
                    guard let self else { return }
                    self.isBusy = false
                    TextInserter.insert(text)
                    self.pill.update(state: .success)
                    self.pill.dismiss(after: 0.6)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isBusy = false
                    if case GeminiTranscriber.TranscribeError.empty = error {
                        Diagnostics.log("no speech in the transcript")
                        self.pill.update(state: .silent)
                        self.pill.dismiss(after: 1.1)
                        return
                    }
                    let message = (error as? LocalizedError)?.errorDescription ?? "Transcription failed"
                    Diagnostics.recordError(message)
                    self.pill.update(state: .failure(message))
                    self.pill.dismiss(after: 2.6)
                }
            }
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
                    self.recorder.onPCM = nil
                }
                session.cancel()
            }
        }
    }

    private func flash(_ state: PillState) {
        pill.show(state)
        pill.dismiss(after: 2.0)
    }
}
