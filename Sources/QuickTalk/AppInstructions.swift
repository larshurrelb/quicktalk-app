import Foundation

/// A standing instruction attached to one application.
///
/// The point is that dictation into WhatsApp and dictation into an editor want different
/// output from the same voice: "use more emojis" belongs to one and would be wrong in the
/// other. Rules are keyed on bundle ID, so the right one is picked automatically from
/// whatever app was frontmost when the key went down.
struct AppRule: Codable, Identifiable, Equatable {
    var bundleID: String
    var name: String
    var instructions: String = ""
    /// Kept separately from "empty instructions" so a rule can be parked without losing
    /// what it said.
    var isEnabled: Bool = true

    var id: String { bundleID }

    var trimmedInstructions: String {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A rule only changes a dictation when it is switched on *and* actually says
    /// something — an enabled-but-blank rule is not a reason to run anything.
    var isActive: Bool { isEnabled && !trimmedInstructions.isEmpty }
}

/// The rules, persisted as JSON in UserDefaults alongside the other preferences.
///
/// `ObservableObject` because two windows and the status menu all read it, and an edit in
/// one has to be visible to the others immediately — the same reason the status menu
/// reads its state in `menuWillOpen` instead of being pushed to.
final class AppRuleStore: ObservableObject {
    private static let key = "appRules"
    private let defaults = UserDefaults.standard

    /// Sorted by name, always — the list is read far more often than it is edited.
    @Published private(set) var rules: [AppRule] = []

    init() {
        rules = Self.load(from: defaults)
    }

    // MARK: - Reading

    func rule(for bundleID: String?) -> AppRule? {
        guard let bundleID else { return nil }
        return rules.first { $0.bundleID == bundleID }
    }

    /// The instructions that should actually be sent for this app, or "" for none.
    func instructions(for bundleID: String?) -> String {
        guard let rule = rule(for: bundleID), rule.isActive else { return "" }
        return rule.trimmedInstructions
    }

    var activeCount: Int { rules.filter(\.isActive).count }

    // MARK: - Writing

    /// Adds an app with no instructions yet, or returns the existing rule untouched —
    /// adding an app twice must never wipe what it already said.
    @discardableResult
    func add(_ app: TargetApp) -> AppRule {
        if let existing = rule(for: app.bundleID) { return existing }
        let rule = AppRule(bundleID: app.bundleID, name: app.name)
        rules.append(rule)
        sortAndSave()
        return rule
    }

    func setInstructions(_ text: String, for bundleID: String) {
        update(bundleID) { $0.instructions = text }
    }

    func setEnabled(_ enabled: Bool, for bundleID: String) {
        update(bundleID) { $0.isEnabled = enabled }
    }

    func remove(_ bundleID: String) {
        rules.removeAll { $0.bundleID == bundleID }
        sortAndSave()
    }

    private func update(_ bundleID: String, _ change: (inout AppRule) -> Void) {
        guard let index = rules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        change(&rules[index])
        save()
    }

    // MARK: - Persistence

    private func sortAndSave() {
        rules.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(from defaults: UserDefaults) -> [AppRule] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AppRule].self, from: data)
        else { return [] }
        return decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
