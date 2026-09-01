import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings
    private let onHotkeyChange: (HotkeyKey) -> Void
    private let onManageApps: () -> Void

    init(
        settings: AppSettings,
        onHotkeyChange: @escaping (HotkeyKey) -> Void,
        onManageApps: @escaping () -> Void
    ) {
        self.settings = settings
        self.onHotkeyChange = onHotkeyChange
        self.onManageApps = onManageApps
    }

    /// The SwiftUI view seeds its @State from settings once, at construction — so after
    /// the mode is changed from the menu bar, an open window would still show the old
    /// selection. Rebuilding it is simpler than threading a binding through.
    func reloadIfVisible() {
        guard let window, window.isVisible else { return }
        window.contentView = NSHostingView(rootView: makeView())
    }

    private func makeView() -> SettingsView {
        SettingsView(settings: settings, onHotkeyChange: onHotkeyChange, onManageApps: onManageApps)
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = makeView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickTalk"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// Shared by the window and the view's own frame — they have to agree, or the
    /// content is either clipped or floating in dead space. Only the header and the
    /// bottom note are pinned; the cards between them scroll, so the rows that appear
    /// conditionally (a microphone warning, the three permission rows) can grow past
    /// this without being cut off. Sized so the settled state — permissions granted,
    /// no warning — needs no scrolling at all.
    static let width: CGFloat = 480
    static let height: CGFloat = 720
}


private struct SettingsView: View {
    let settings: AppSettings
    let onHotkeyChange: (HotkeyKey) -> Void
    let onManageApps: () -> Void

    @State private var apiKey: String
    @State private var hasKey: Bool
    @State private var mode: TranscriptionMode
    @State private var hotkey: HotkeyKey
    @State private var playSound: Bool
    @State private var startSound: String
    @State private var micGranted: Bool
    @State private var axGranted: Bool
    @State private var inputGranted: Bool
    @State private var microphoneUID: String
    @State private var devices: [AudioInputDevice]

    @ObservedObject private var appRules: AppRuleStore

    init(
        settings: AppSettings,
        onHotkeyChange: @escaping (HotkeyKey) -> Void,
        onManageApps: @escaping () -> Void
    ) {
        self.settings = settings
        self.onHotkeyChange = onHotkeyChange
        self.onManageApps = onManageApps
        self.appRules = settings.appRules
        // Deliberately not prefilled: reading it here would prompt for the Keychain
        // every time Settings opens. Empty means "leave whatever is stored alone".
        _apiKey = State(initialValue: "")
        _hasKey = State(initialValue: settings.hasAPIKey)
        _mode = State(initialValue: settings.mode)
        _hotkey = State(initialValue: settings.hotkey)
        _playSound = State(initialValue: settings.playSound)
        _startSound = State(initialValue: settings.startSound)
        _micGranted = State(initialValue: AudioRecorder.hasMicrophoneAccess)
        _axGranted = State(initialValue: HotkeyMonitor.hasAccessibilityPermission)
        _inputGranted = State(initialValue: HotkeyMonitor.hasInputMonitoringPermission)
        _microphoneUID = State(initialValue: settings.microphoneUID)
        _devices = State(initialValue: AudioDevices.inputDevices())
    }

    /// Header and footnote are pinned; the cards scroll between them.
    ///
    /// The cards are built by hand rather than with `Form { }.formStyle(.grouped)`,
    /// which was the obvious thing to reach for and was measured at ~950pt of content —
    /// a third of it the form's own row padding, which is not adjustable. These rows are
    /// 30pt and everything still fits in a window smaller than the old flat layout.
    ///
    /// Sections are computed properties as much for the type-checker as for reading: one
    /// expression this size takes seconds to compile.
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    apiKeySection
                    recordingSection
                    formattingSection
                    permissionsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            footnote
        }
        .frame(width: SettingsWindowController.width, height: SettingsWindowController.height)
        // Stated rather than inherited: the cards are `controlBackgroundColor`, and they
        // only read as raised if what is behind them is the window's own colour.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            micGranted = AudioRecorder.hasMicrophoneAccess
            axGranted = HotkeyMonitor.hasAccessibilityPermission
            inputGranted = HotkeyMonitor.hasInputMonitoringPermission
            // Devices come and go — refresh whenever the window is opened.
            devices = AudioDevices.inputDevices()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // NSApp.applicationIconImage is the bundled icon itself, so this stays in
            // step with the Dock and menu bar automatically.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("QuickTalk").font(.system(size: 15, weight: .semibold))
                // Reads back the key that is actually bound, so the one line everyone
                // looks for cannot go stale after changing it.
                Text("Hold \(hotkey.label) to dictate")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            statusChip
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    /// A one-glance answer to "will this work if I hold the key right now?" — the same
    /// conditions the menu bar title reports, plus the key.
    private var statusChip: some View {
        let ready = hasKey && allPermissionsGranted
        return HStack(spacing: 5) {
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(ready ? "Ready" : "Needs setup")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var footnote: some View {
        Text("Language is detected automatically — German and English need no switching.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        section("Gemini API key") {
            HStack(spacing: 8) {
                // A field's placeholder is drawn as a *label* beside it in a labelled
                // row; `prompt:` is what keeps the hint inside the field itself.
                SecureField(
                    "",
                    text: $apiKey,
                    prompt: Text(hasKey ? "•••••••••  stored — type to replace" : "Paste your Gemini API key")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKey) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    settings.apiKey = trimmed
                    hasKey = true
                }

                if hasKey {
                    Button("Remove") {
                        settings.clearAPIKey()
                        apiKey = ""
                        hasKey = false
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                caption("Kept in a file only your macOS account can read — mode 0600, excluded from backups, never written to preferences, never logged, and sent only to Google.")
                Link("Get one free at aistudio.google.com", destination: Self.apiKeyURL)
                    .font(.system(size: 11))
            }
        }
    }

    private var recordingSection: some View {
        section("Recording") {
            row("Push-to-talk key") {
                Picker("", selection: $hotkey) {
                    ForEach(HotkeyKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: hotkey) { _, value in
                    settings.hotkey = value
                    onHotkeyChange(value)
                }
            }
            rowDivider
            row("Microphone") {
                Picker("", selection: $microphoneUID) {
                    Text(defaultMicLabel).tag("")
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .onChange(of: microphoneUID) { _, value in settings.microphoneUID = value }
            }
            if let micWarning {
                rowDivider
                warningRow(micWarning)
            }
            rowDivider
            row("Play a sound when recording starts and stops") {
                Toggle("", isOn: $playSound)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: playSound) { _, value in settings.playSound = value }
            }
            rowDivider
            row("Start cue") {
                Picker("", selection: $startSound) {
                    ForEach(AppSettings.startSoundChoices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: startSound) { _, value in
                    settings.startSound = value
                    NSSound(named: value)?.play()   // hear it as you pick
                }
            }
            .disabled(!playSound)
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                caption("Hold the key, speak, let go. The key keeps working normally otherwise.")
                // Dropped while a warning is up — that one is the line to read.
                if micWarning == nil {
                    caption("The microphone is picked per device, not per app, so it sticks even when macOS switches its default.")
                }
            }
        }
    }

    private var formattingSection: some View {
        section("Formatting") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $mode) {
                    ForEach(TranscriptionMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                // A segmented control keeps its intrinsic width and centres itself in
                // whatever it is given, which left it floating mid-card. Pin it leading
                // so it lines up with the row labels above and below.
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: mode) { _, value in settings.mode = value }

                caption(mode.detail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            rowDivider

            row("Per-app instructions") {
                HStack(spacing: 8) {
                    Text(appRulesSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Manage…", action: onManageApps)
                        .controlSize(.small)
                }
            }
        } footer: {
            caption(mode == .smart
                ? "Standing notes per app — “use more emojis” in a chat app, plain prose in an editor. Applied to whichever app is in front when you press the key."
                : "Instructions are only used in Smart mode, which is the only mode with a formatting step to apply them in.")
        }
    }

    /// Three rows while anything is missing, one line once it is all granted. The long
    /// explanation is what you need *while* you are fixing it; afterwards it is a wall
    /// of text between you and everything above it.
    private var permissionsSection: some View {
        section("Permissions") {
            if allPermissionsGranted {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Microphone, Input Monitoring and Accessibility are granted")
                        .font(.system(size: 12))
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
            } else {
                permissionRow(
                    "Microphone",
                    icon: "mic.fill",
                    granted: micGranted,
                    action: { AudioRecorder.requestMicrophoneAccess { micGranted = $0 } }
                )
                rowDivider
                permissionRow(
                    "Input Monitoring",
                    icon: "keyboard",
                    granted: inputGranted,
                    action: {
                        HotkeyMonitor.requestInputMonitoringPermission()
                        openSettingsPane("Privacy_ListenEvent")
                    }
                )
                rowDivider
                permissionRow(
                    "Accessibility",
                    icon: "hand.point.up.left.fill",
                    granted: axGranted,
                    action: {
                        HotkeyMonitor.requestAccessibilityPermission()
                        openSettingsPane("Privacy_Accessibility")
                    }
                )
            }
        } footer: {
            if !allPermissionsGranted {
                caption("Input Monitoring lets QuickTalk see the push-to-talk key while you're in another app — without it the hotkey only works when QuickTalk itself is frontmost. Accessibility lets it paste the result. macOS needs the app quit and reopened after granting Input Monitoring.")
            }
        }
    }

    // MARK: - Building blocks

    private static let apiKeyURL = URL(string: "https://aistudio.google.com/apikey")!

    private var allPermissionsGranted: Bool { micGranted && inputGranted && axGranted }

    private func section<Content: View, Footer: View>(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            card { content() }
            footer().padding(.horizontal, 2)
        }
    }

    /// The card is what the grouped `Form` would have drawn — a filled, hairline-bordered
    /// container — at a row height this window can afford.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }

    /// Inset on the leading edge so the rule reads as separating rows inside one card,
    /// rather than cutting the card in half.
    private var rowDivider: some View {
        Divider().padding(.leading, 12)
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12))
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    /// The leading glyph names the permission, the trailing state says whether it is
    /// there — "Grant…" only appears on the ones that still need it.
    private func permissionRow(
        _ name: String,
        icon: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name).font(.system(size: 12))
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Granted")
            } else {
                Button("Grant…", action: action).controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            caption(text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Text

    /// Whether the microphone that would actually be used is a Bluetooth one — either
    /// chosen explicitly, or reached through "System Default".
    private var bluetoothMicSelected: Bool {
        microphoneUID.isEmpty
            ? AudioDevices.defaultInputIsBluetooth
            : AudioDevices.isBluetooth(uid: microphoneUID)
    }

    private var micWarning: String? {
        if !microphoneUID.isEmpty && AudioDevices.name(forUID: microphoneUID) == nil {
            return "That device isn't connected right now — the system default will be used until it's back."
        }
        // A Bluetooth headset cannot do good playback and a microphone at the same time.
        // That is the device's own limitation, not something the app can work around —
        // so say which choice avoids it.
        if bluetoothMicSelected {
            return "Bluetooth microphone: recording switches the headphones into call mode, so playback drops to mono at 16 kHz until you stop. Pick the built-in microphone to keep music at full quality."
        }
        return nil
    }

    private var appRulesSummary: String {
        let active = appRules.activeCount
        if active == 0 { return appRules.rules.isEmpty ? "No apps yet" : "None active" }
        return active == 1 ? "1 app configured" : "\(active) apps configured"
    }

    private var defaultMicLabel: String {
        if let name = AudioDevices.defaultInputName {
            return "System Default (\(name))"
        }
        return "System Default"
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
