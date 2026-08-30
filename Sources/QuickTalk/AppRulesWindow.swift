import AppKit
import SwiftUI

@MainActor
final class AppRulesWindowController {
    private var window: NSWindow?

    private let store: AppRuleStore
    private let settings: AppSettings
    private let frontmost: FrontmostAppTracker

    init(store: AppRuleStore, settings: AppSettings, frontmost: FrontmostAppTracker) {
        self.store = store
        self.settings = settings
        self.frontmost = frontmost
    }

    /// `selecting` is the app to open on — the status menu passes whatever was frontmost,
    /// so "Add instructions for WhatsApp…" lands directly on WhatsApp's rule.
    ///
    /// The content view is rebuilt on every open rather than reused. The list of apps you
    /// can add is a snapshot of what is running, and the pickers seed their @State once at
    /// construction; rebuilding is how both stay current without an observer that would
    /// keep working while the window is closed.
    /// `sizingOptions = []` stops the hosting view from pushing its content's ideal size
    /// out as the window's size. Left at the default, one greedy subview resizes the
    /// window itself — which is how a 420pt window ended up laying out 2016pt of content
    /// and hiding the app list off-screen.
    private static func host(_ view: AppRulesView) -> NSHostingView<AppRulesView> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        return host
    }

    func show(selecting app: TargetApp? = nil) {
        let target = app.map { store.add($0).bundleID }

        let view = AppRulesView(
            store: store,
            settings: settings,
            frontmost: frontmost,
            initialSelection: target ?? store.rules.first?.bundleID
        )

        if let window {
            window.contentView = Self.host(view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "App Instructions"
        window.contentView = Self.host(view)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

// MARK: - View

private struct AppRulesView: View {
    @ObservedObject var store: AppRuleStore
    let settings: AppSettings
    let frontmost: FrontmostAppTracker

    @State private var selection: String?
    /// The text field's own copy. Edits are written straight back to the store on every
    /// keystroke — there is no Save button, and a rule the user typed but never "saved"
    /// would be the worst possible failure here.
    @State private var draft: String = ""
    init(store: AppRuleStore, settings: AppSettings, frontmost: FrontmostAppTracker, initialSelection: String?) {
        self.store = store
        self.settings = settings
        self.frontmost = frontmost
        _selection = State(initialValue: initialSelection)
        _draft = State(initialValue: store.rule(for: initialSelection)?.instructions ?? "")
    }

    /// Every part of this layout has to be *flexible*, never merely "at least this big".
    ///
    /// `TextEditor` has an unbounded ideal height, so a bare `minHeight` let it inflate
    /// the whole window's content to 2056pt inside a 420pt window — which pushed the app
    /// list off-screen and made the window look empty even with rules stored. Anything
    /// greedy here needs a `maxHeight`, not just a minimum.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.rules) { rule in
                    row(rule).tag(rule.bundleID)
                }
            }
            .listStyle(.plain)
            .frame(maxHeight: .infinity)
            .onChange(of: selection) { _, value in
                draft = store.rule(for: value)?.instructions ?? ""
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    presentAddMenu()
                } label: {
                    Image(systemName: "plus").frame(width: 18, height: 14)
                }
                .help("Add an app")

                Button {
                    guard let selection else { return }
                    store.remove(selection)
                    self.selection = store.rules.first?.bundleID
                    draft = store.rule(for: self.selection)?.instructions ?? ""
                } label: {
                    Image(systemName: "minus").frame(width: 18, height: 14)
                }
                .disabled(selection == nil)
                .help("Remove the selected app")

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
    }

    private func row(_ rule: AppRule) -> some View {
        HStack(spacing: 7) {
            icon(rule.bundleID)
            Text(rule.name)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            // An app in the list that will not actually do anything is worth flagging —
            // otherwise a switched-off or still-empty rule looks identical to a live one.
            if !rule.isActive {
                Text(rule.isEnabled ? "empty" : "off")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    private func icon(_ bundleID: String) -> some View {
        Group {
            if let image = AppCatalog.icon(for: bundleID) {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }

    /// An AppKit menu rather than SwiftUI's `Menu`, for two reasons.
    ///
    /// SwiftUI's macOS `Menu` under `BorderlessButtonMenuStyle` in a narrow fixed frame
    /// rendered a `+` that did not respond to a click at all — the style is deprecated and
    /// the hit region did not survive the frame clamp.
    ///
    /// The list also has to be built *now*, not when the window opened. Apps launch and
    /// quit while this window sits there, and a snapshot taken in `onAppear` silently
    /// omits anything started since.
    private func presentAddMenu() {
        let menu = AddAppMenu.build(
            taken: Set(store.rules.map(\.bundleID)),
            lastUsed: frontmost.current,
            available: AppCatalog.runningApps(),
            onPick: { add($0) },
            onOther: { chooseFromDisk() }
        )

        // Popped at the pointer — which is where the button the user just clicked is.
        // A nil view means the location is read in screen coordinates, so this does not
        // depend on finding a key window; `NSApp.keyWindow` being nil at the wrong moment
        // would be another silent "the button does nothing".
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let selection, let rule = store.rule(for: selection) {
            editor(rule)
        } else {
            VStack(spacing: 6) {
                Text("No app selected")
                    .font(.system(size: 13, weight: .medium))
                Text("Add an app on the left, then write what should happen to dictation that lands in it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editor(_ rule: AppRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                icon(rule.bundleID).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name).font(.system(size: 13, weight: .semibold))
                    Text(rule.bundleID).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { store.setEnabled($0, for: rule.bundleID) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Use these instructions when dictating into \(rule.name)")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .onChange(of: draft) { _, value in
                        store.setInstructions(value, for: rule.bundleID)
                    }

                if draft.isEmpty {
                    Text("Use plenty of emojis and keep it casual. Never add a greeting.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            // idealHeight is the load-bearing part. `maxHeight` only grants permission to
            // grow — TextEditor's *ideal* height stays unbounded without an explicit one,
            // and NSHostingView reports that ideal upward as the window's content size.
            .frame(minHeight: 120, idealHeight: 150, maxHeight: .infinity)
            .disabled(!rule.isEnabled)
            .opacity(rule.isEnabled ? 1 : 0.5)

            Text("Written to the model as your own instructions, so they outrank QuickTalk's own formatting rules. The dictation itself is never treated as an instruction.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Instructions ride along with the Smart formatting pass, and there is no
            // formatting pass in the other two modes — better to say so here than to
            // leave someone wondering why nothing changed.
            if settings.mode != .smart {
                Label(
                    "These only apply in Smart mode. QuickTalk is set to \(settings.mode.label) right now.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Adding

    private func add(_ app: TargetApp) {
        let rule = store.add(app)
        selection = rule.bundleID
        draft = rule.instructions
    }

    /// For apps that aren't running: the list can only show what is open right now.
    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"

        guard panel.runModal() == .OK,
              let url = panel.url,
              let app = AppCatalog.identity(of: url)
        else { return }
        add(app)
    }
}

/// The contents of the `+` menu.
///
/// AppKit rather than SwiftUI's `Menu`: under `BorderlessButtonMenuStyle` in a narrow
/// fixed frame, SwiftUI rendered a `+` that did not respond to clicks at all — the style
/// is deprecated and the hit region did not survive the frame clamp.
///
/// Split out from the view so it can be built and exercised without a window on screen.
/// The list is assembled per call, never cached: apps launch and quit while this window
/// sits open, and a snapshot taken at `onAppear` silently omits anything started since.
enum AddAppMenu {
    static func build(
        taken: Set<String>,
        lastUsed: TargetApp?,
        available: [TargetApp],
        onPick: @escaping (TargetApp) -> Void,
        onOther: @escaping () -> Void
    ) -> NSMenu {
        let menu = NSMenu()

        // Whatever you were in a moment ago is nearly always the app you came here to
        // configure, so it goes first rather than being hunted for in the list.
        if let lastUsed, !taken.contains(lastUsed.bundleID) {
            menu.addItem(item(for: lastUsed, suffix: "  (last used)", onPick: onPick))
            menu.addItem(.separator())
        }

        let rest = available.filter { !taken.contains($0.bundleID) && $0.bundleID != lastUsed?.bundleID }
        if rest.isEmpty {
            let none = NSMenuItem(title: "No other apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for app in rest { menu.addItem(item(for: app, onPick: onPick)) }
        }

        menu.addItem(.separator())
        // The list can only show what is open; anything else is reachable from disk.
        menu.addItem(entry(title: "Other App…", run: onOther))
        return menu
    }

    private static func item(
        for app: TargetApp,
        suffix: String = "",
        onPick: @escaping (TargetApp) -> Void
    ) -> NSMenuItem {
        let item = entry(title: app.name + suffix) { onPick(app) }
        if let icon = AppCatalog.icon(for: app.bundleID) {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }

    private static func entry(title: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: "")
        let action = MenuAction(run)
        item.target = action
        // NSMenuItem holds its target *weakly*, so the action object would be released
        // before the click ever arrives and the item would come up greyed out and dead.
        // representedObject is what keeps it alive.
        item.representedObject = action
        return item
    }
}

/// Carries a Swift closure across NSMenuItem's Objective-C target/action boundary.
final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire() { run() }
}
