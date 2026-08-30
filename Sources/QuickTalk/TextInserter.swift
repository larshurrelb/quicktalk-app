import AppKit

/// Puts the transcript where the cursor is.
///
/// Pasting is used rather than typing the characters one by one: it is instant, it can't
/// be garbled by key-repeat or dead keys, and it handles umlauts and emoji correctly —
/// which synthesised keystrokes on a German layout would not.
enum TextInserter {
    /// Restores whatever was on the clipboard afterwards, so dictating doesn't quietly
    /// destroy what you had copied.
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // A beat for the push-to-talk key to be fully released; otherwise its modifier
        // can still be down and turn the synthetic ⌘V into ⌘⌥V or similar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            pressCommandV()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let saved else { return }
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 9 is `v` on every layout — virtual key codes are positional, not lettered.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
