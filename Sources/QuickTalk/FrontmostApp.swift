import AppKit

/// The app a dictation is going to land in.
///
/// Identified by bundle ID rather than name: names are localised and change between
/// versions, bundle IDs do not. The name is carried alongside only so the UI can show
/// something readable for an app that isn't running right now.
struct TargetApp: Equatable {
    var bundleID: String
    var name: String
}

/// Remembers which application is frontmost, so a dictation can be matched to a rule.
///
/// Notification-driven, never polled — the app has to stay free while idle, and
/// `didActivateApplication` fires exactly when the answer changes.
///
/// QuickTalk itself is deliberately ignored. Its Settings and App Instructions windows
/// *do* become frontmost, and the status menu can too, so adopting our own bundle ID
/// would forget the real target at the very moment the user is configuring it.
///
/// Main thread only. Reading the frontmost app needs no permission at all: bundle ID and
/// localised name are public process metadata, unlike window titles or contents.
final class FrontmostAppTracker {
    private(set) var current: TargetApp?

    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.quicktalk.QuickTalk"
    private var token: NSObjectProtocol?

    init() {
        adopt(NSWorkspace.shared.frontmostApplication)

        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.adopt(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    /// Re-reads at the moment it matters — the key going down. The notification is
    /// normally enough, but this costs nothing and closes the gap if one was missed.
    @discardableResult
    func refresh() -> TargetApp? {
        adopt(NSWorkspace.shared.frontmostApplication)
        return current
    }

    private func adopt(_ app: NSRunningApplication?) {
        guard let app,
              let bundleID = app.bundleIdentifier,
              bundleID != ownBundleID
        else { return }
        current = TargetApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }
}

// MARK: - Picking an app

/// Everything the rules UI needs to offer an app the user can attach instructions to.
enum AppCatalog {
    /// Apps with a Dock icon and a window — the ones you could plausibly dictate into.
    /// Background agents and other menu-bar-only apps are filtered out, along with
    /// QuickTalk itself.
    static func runningApps() -> [TargetApp] {
        let own = Bundle.main.bundleIdentifier ?? "com.quicktalk.QuickTalk"

        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> TargetApp? in
                guard let bundleID = app.bundleIdentifier, bundleID != own else { return nil }
                guard seen.insert(bundleID).inserted else { return nil }
                return TargetApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads an app bundle the user picked in the open panel.
    static func identity(of bundleURL: URL) -> TargetApp? {
        guard let bundle = Bundle(url: bundleURL), let bundleID = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: bundleURL.path)
            .replacingOccurrences(of: ".app", with: "")
        return TargetApp(bundleID: bundleID, name: name)
    }

    /// The real Finder icon, so a list of rules is scannable at a glance. Looked up by
    /// bundle ID so it also works for apps that aren't running.
    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
