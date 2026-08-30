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
            contentRect: NSRect(x: 0, y: 0, width: 440, height: Self.height),
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
    /// content is either clipped or floating in dead space.
    static let height: CGFloat = 780
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Spacer()
                // NSApp.applicationIconImage is the bundled icon itself, so this stays in
                // step with the Dock and menu bar automatically.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
            }
            .padding(.bottom, -14)

            section("Gemini API key") {
                HStack(spacing: 8) {
                    SecureField(hasKey ? "•••••••••  (stored — type to replace)" : "Paste your Gemini API key", text: $apiKey)
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
                caption("Kept in a private file only your macOS account can read (mode 0600 in Application Support), excluded from backups, never written to preferences, never logged, and sent only to Google. Get one free at aistudio.google.com.")
            }

            section("Push to talk") {
                Picker("", selection: $hotkey) {
                    ForEach(HotkeyKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
                .onChange(of: hotkey) { _, value in
                    settings.hotkey = value
                    onHotkeyChange(value)
                }
                caption("Hold the key, speak, let go. The key keeps working normally otherwise.")
            }

            section("Microphone") {
                Picker("", selection: $microphoneUID) {
                    Text(defaultMicLabel).tag("")
                    if !devices.isEmpty { Divider() }
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 260)
                .onChange(of: microphoneUID) { _, value in settings.microphoneUID = value }

                if !microphoneUID.isEmpty && AudioDevices.name(forUID: microphoneUID) == nil {
                    caption("⚠︎ That device isn't connected right now — the system default will be used until it's back.")
                } else if bluetoothMicSelected {
                    // A Bluetooth headset cannot do good playback and a microphone at the
                    // same time. This is the device's own limitation, not something the
                    // app can work around — so say which choice avoids it.
                    caption("⚠︎ This is a Bluetooth microphone. Recording from it switches the headphones into call mode, so playback drops to mono at 16 kHz until the dictation ends. Pick the built-in microphone to keep music at full quality while you dictate.")
                } else {
                    caption("Picked per device, not per app, so it sticks even when macOS switches its default.")
                }
            }

            section("Formatting") {
                Picker("", selection: $mode) {
                    ForEach(TranscriptionMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
                .onChange(of: mode) { _, value in settings.mode = value }
                caption(mode.detail)
            }

            section("Per-app instructions") {
                HStack(spacing: 10) {
                    Button("Manage Apps…", action: onManageApps)
                        .controlSize(.small)
                    Text(appRulesSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                caption(mode == .smart
                    ? "Standing notes per app — \u{201c}use more emojis\u{201d} in a chat app, plain prose in an editor. QuickTalk sees which app is in front when you press the key and adds that app\u{2019}s instructions."
                    : "Only used in Smart mode, which is the only mode with a formatting step to apply them in.")
            }

            section("Sound") {
                Toggle("Play a sound when recording starts and stops", isOn: $playSound)
                    .onChange(of: playSound) { _, value in settings.playSound = value }
                    .font(.system(size: 12))

                HStack(spacing: 8) {
                    Text("Start cue").font(.system(size: 12))
                    Picker("", selection: $startSound) {
                        ForEach(AppSettings.startSoundChoices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .onChange(of: startSound) { _, value in
                        settings.startSound = value
                        NSSound(named: value)?.play()   // hear it as you pick
                    }
                }
                .disabled(!playSound)
            }

            Divider()

            section("Permissions") {
                permissionRow(
                    "Microphone",
                    granted: micGranted,
                    action: { AudioRecorder.requestMicrophoneAccess { micGranted = $0 } }
                )
                permissionRow(
                    "Input Monitoring",
                    granted: inputGranted,
                    action: {
                        HotkeyMonitor.requestInputMonitoringPermission()
                        openSettingsPane("Privacy_ListenEvent")
                    }
                )
                permissionRow(
                    "Accessibility",
                    granted: axGranted,
                    action: {
                        HotkeyMonitor.requestAccessibilityPermission()
                        openSettingsPane("Privacy_Accessibility")
                    }
                )
                caption("Input Monitoring lets QuickTalk see the push-to-talk key while you're in another app — without it the hotkey only works when QuickTalk itself is frontmost. Accessibility lets it paste the result. macOS needs the app quit and reopened after granting Input Monitoring.")
            }

            Spacer()

            Text("Language is detected automatically — German and English work without switching anything.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440, height: SettingsWindowController.height, alignment: .topLeading)
        .onAppear {
            micGranted = AudioRecorder.hasMicrophoneAccess
            axGranted = HotkeyMonitor.hasAccessibilityPermission
            inputGranted = HotkeyMonitor.hasInputMonitoringPermission
            // Devices come and go — refresh whenever the window is opened.
            devices = AudioDevices.inputDevices()
        }
    }

    /// Whether the microphone that would actually be used is a Bluetooth one — either
    /// chosen explicitly, or reached through "System Default".
    private var bluetoothMicSelected: Bool {
        microphoneUID.isEmpty
            ? AudioDevices.defaultInputIsBluetooth
            : AudioDevices.isBluetooth(uid: microphoneUID)
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(name).font(.system(size: 12))
            Spacer()
            if !granted {
                Button("Grant…", action: action).controlSize(.small)
            }
        }
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
