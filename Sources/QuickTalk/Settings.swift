import Foundation
import CoreGraphics

// MARK: - Hotkey

/// Modifier keys usable as a push-to-talk key. Only modifiers: they can be held
/// without typing anything into the app you are dictating into.
enum HotkeyKey: String, CaseIterable, Identifiable {
    case rightCommand
    case leftCommand
    case rightOption
    case leftOption
    case rightControl
    case fn

    var id: String { rawValue }

    /// Virtual key codes for the modifier keys, which `flagsChanged` events carry.
    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    var mask: CGEventFlags {
        switch self {
        case .rightCommand, .leftCommand: return .maskCommand
        case .rightOption, .leftOption: return .maskAlternate
        case .rightControl: return .maskControl
        case .fn: return .maskSecondaryFn
        }
    }

    var label: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .leftCommand: return "Left ⌘"
        case .rightOption: return "Right ⌥"
        case .leftOption: return "Left ⌥"
        case .rightControl: return "Right ⌃"
        case .fn: return "fn"
        }
    }
}

// MARK: - Transcription mode

enum TranscriptionMode: String, CaseIterable, Identifiable {
    /// Live socket, VERBATIM. Word for word, and the fastest thing here.
    case verbatim
    /// Live socket in SMART, then the formatting pass. Streaming means the transcript is
    /// ready at key-up, so the formatting model starts ~2.5s earlier than it used to.
    case smart
    /// The batch endpoint, verbatim. Slower, but roughly half the price.
    case cheap

    var id: String { rawValue }

    /// Everything but `cheap` streams. `cheap` exists precisely to avoid the live
    /// premium (1.8x on tokens).
    var usesLive: Bool { self != .cheap }

    /// The socket's own disfluency removal — "um", false starts, self-corrections.
    var liveSmart: Bool { self == .smart }

    /// The second `flash-lite` pass that produces paragraphs and real lists.
    var needsFormattingPass: Bool { self == .smart }

    /// What a batch request should ask for — used by `cheap`, and by any live session
    /// that fails and falls back.
    var batchSmart: Bool { self == .smart }

    var label: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .smart: return "Smart"
        case .cheap: return "Cheap"
        }
    }

    var detail: String {
        switch self {
        case .verbatim:
            return "Streamed while you speak, word for word. Fastest."
        case .smart:
            return "Streamed, then tidied into paragraphs and real lists. Fast and formatted."
        case .cheap:
            return "One request after you finish, word for word. Slower, about half the cost."
        }
    }

    /// Older builds stored `structured` and `live`; map them rather than silently
    /// resetting someone's choice to the default.
    static func migrating(_ raw: String?) -> TranscriptionMode {
        switch raw {
        case "structured": return .smart      // structured became the new smart
        case "live": return .verbatim         // live folded into verbatim
        case let value?: return TranscriptionMode(rawValue: value) ?? .smart
        case nil: return .smart
        }
    }
}

// MARK: - Settings

/// Preferences live in UserDefaults; the API key lives in the Keychain and never
/// touches defaults, logs, or disk in plain text.
final class AppSettings {
    private let defaults = UserDefaults.standard

    /// Per-app instruction rules. Owned here so the status menu, the Settings window and
    /// the App Instructions window all read and write the same live object.
    let appRules = AppRuleStore()
    private enum Key {
        static let hotkey = "hotkey"
        static let mode = "mode"
        static let playSound = "playSound"
        static let microphone = "microphoneUID"
        static let startSound = "startSound"
    }

    var hotkey: HotkeyKey {
        get { HotkeyKey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .rightCommand }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    var mode: TranscriptionMode {
        get { TranscriptionMode.migrating(defaults.string(forKey: Key.mode)) }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    var playSound: Bool {
        get { defaults.object(forKey: Key.playSound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSound) }
    }

    /// Cue played when recording starts. "Purr" is soft and low, so it sits under the
    /// voice instead of competing with it the way the sharper "Tink" did.
    var startSound: String {
        get { defaults.string(forKey: Key.startSound) ?? "Purr" }
        set { defaults.set(newValue, forKey: Key.startSound) }
    }

    /// Sounds that read as a soft "listening now" rather than an alert.
    static let startSoundChoices = ["Purr", "Bottle", "Morse", "Tink", "Blow", "Submarine"]

    /// CoreAudio device UID, or empty for "follow the system default".
    var microphoneUID: String {
        get { defaults.string(forKey: Key.microphone) ?? "" }
        set { defaults.set(newValue, forKey: Key.microphone) }
    }

    var apiKey: String {
        get { KeyStore.read() ?? "" }
        set { KeyStore.write(newValue) }
    }

    var hasAPIKey: Bool { KeyStore.read() != nil }

    func clearAPIKey() { KeyStore.clear() }
}

// MARK: - Key storage

/// The Gemini API key, in a file only your account can read.
///
/// **Not the Keychain.** On the file-based macOS keychain, access is granted per code
/// signature, so any build whose signature differs from the one that stored the item
/// raises a password overlay — which is every build when signing ad-hoc. That was
/// measured, not assumed: re-signing with the same certificate reads back silently, an
/// ad-hoc re-sign prompts.
///
/// **Not `UserDefaults`.** That is where the key used to live, and it puts a credential
/// somewhere `defaults read com.quicktalk.QuickTalk` will print in full — a genuine leak
/// the moment anyone pastes their settings into a bug report.
///
/// What this gives you, stated plainly:
///
///  * mode `0600` in a `0700` directory — no other account on this Mac can read it
///  * outside the preferences domain, so no `defaults read` ever prints it
///  * excluded from Time Machine, so it does not spread into backups
///  * encrypted at rest by FileVault, if FileVault is on
///  * never logged — and `Diagnostics` redacts anything key-shaped as a backstop
///
/// What it does **not** give you: protection from other software running as *you*. No
/// local store does, short of the Keychain, and even that only raises the bar. This is a
/// credential on a trusted machine; if that stops being true, revoke it at
/// aistudio.google.com — that takes a second and is the only real remedy.
enum KeyStore {
    /// Left over from when the key lived in preferences. Read once so an upgrade does not
    /// lose it, then deleted so no plaintext copy is left behind.
    private static let legacyDefaultsKey = "geminiAPIKey"

    private static let lock = NSLock()
    /// `nil` means "not read yet"; `.some(nil)` means "read, and there is no key".
    private static var cached: String??

    private static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickTalk", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("gemini-api-key")
    }

    static func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        var value = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // One-time move off the old preferences storage.
        if value?.isEmpty != false,
           let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey),
           !legacy.isEmpty {
            store(legacy)
            value = legacy
        }

        cached = .some((value?.isEmpty == false) ? value : nil)
        return cached ?? nil
    }

    static func write(_ value: String) {
        lock.lock()
        defer { lock.unlock() }

        guard !value.isEmpty else {
            purge()
            cached = .some(nil)
            return
        }
        store(value)
        cached = .some(value)
    }

    /// Forgets the key entirely — Settings offers this so a machine can be handed on
    /// without leaving a credential behind.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        purge()
        cached = .some(nil)
    }

    // MARK: - Disk

    private static func store(_ value: String) {
        let manager = FileManager.default

        // 0700: the directory itself is not listable by anyone else either.
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // createFile applies the permissions as the file is created, so there is never an
        // instant where the key exists as a world-readable file. Writing "atomically"
        // would rename a temp file into place and take the umask's permissions instead.
        try? manager.removeItem(at: fileURL)
        let created = manager.createFile(
            atPath: fileURL.path,
            contents: Data(value.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            // Only ever the fact of failure — never the value.
            Diagnostics.recordError("could not write the API key file")
            return
        }

        // Keep the credential out of Time Machine snapshots.
        var url = fileURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)

        // Never leave the old plaintext copy in preferences.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    private static func purge() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }
}
