import AppKit
import SwiftUI

enum PillState: Equatable {
    case listening
    case transcribing
    case success
    /// Nothing was said. Deliberately not a `failure`: it needs no warning icon, no long
    /// timeout and no red flag — nothing went wrong.
    case silent
    case failure(String)
}

final class PillModel: ObservableObject {
    static let barCount = 21

    @Published var state: PillState = .listening
    /// Bar heights, 0...1. Symmetric around the centre: the whole cluster swells with
    /// your voice rather than scrolling past, so it reads as "this is how loud you are
    /// right now" instead of "here is the last second of history".
    @Published var bars: [Float] = Array(repeating: 0, count: PillModel.barCount)

    /// Advances every update so neighbouring bars shimmer slightly out of step. Without
    /// it the cluster is one shape being scaled, which looks mechanical.
    private var phase: Double = 0

    func push(_ level: Float) {
        phase += 0.42
        let count = Self.barCount
        let centre = Double(count - 1) / 2

        bars = (0..<count).map { index in
            let distance = abs(Double(index) - centre) / centre
            // Bell-shaped falloff: tallest in the middle, tapering symmetrically.
            let envelope = pow(cos(distance * .pi / 2), 0.75)
            let wobble = 0.78 + 0.22 * sin(phase + Double(index) * 0.85)
            return Float(Double(level) * envelope * wobble)
        }
    }
}

/// The pill's drop shadow, and the room the panel has to leave for it.
///
/// SwiftUI's blur reaches about **twice** the nominal radius before it fades out, which is
/// not obvious from the API and is what made this wrong. Rendered and measured at radius
/// 12: the last visible pixels sit 25pt to each side, 22pt above and 30pt below the
/// capsule — against a uniform 14pt of padding, so the falloff was being sliced off
/// mid-gradient. A cut gradient does not read as a soft shadow, it reads as a straight
/// grey edge, and it was worst along the bottom where the y offset pushes the blur further.
///
/// Keep the insets derived from `radius` and `offsetY` rather than typed in. Every one of
/// them is wrong the moment someone nudges the shadow and doesn't know to re-measure.
enum PillShadow {
    static let color = Color.black.opacity(0.28)
    static let radius: CGFloat = 12
    static let offsetY: CGFloat = 4

    /// Twice the radius, plus slack: at exactly 2×+2 the outermost pixel of the gradient
    /// still lands on the panel edge.
    private static let reach = radius * 2 + 4

    static let side = reach
    static let top = reach - offsetY
    static let bottom = reach + offsetY

    /// How high the *capsule* sits above the bottom of the screen. Measured to the pill
    /// itself rather than to the panel, because the panel's own height now depends on the
    /// shadow — position it by the panel and the pill drifts upward every time the shadow
    /// gets softer.
    static let heightAboveScreenBottom: CGFloat = 102
}

/// The floating pill.
///
/// An `NSPanel` with `.nonactivatingPanel` is the whole trick: it appears above every
/// app — including full-screen ones — without taking focus, so the text field you are
/// dictating into stays first responder and the paste lands in the right place.
@MainActor
final class PillHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<PillView>?
    let model = PillModel()

    /// Bumped by every `show` and every `dismiss`, so work scheduled by an earlier state
    /// can tell it has been superseded. Without it, tapping the hotkey repeatedly stacked
    /// a fresh panel on top of one still fading out, and which of them survived came down
    /// to whichever animation happened to finish last.
    private var generation = 0
    private var pendingDismissal: DispatchWorkItem?

    /// Only a starting guess — `resizeToFit` runs before the panel is ever shown, so this
    /// is never what appears. It still tracks the real height, because a first layout pass
    /// at the wrong size is a hitch nobody needs.
    private static let initialSize = CGSize(
        width: 200 + PillShadow.side * 2,
        height: 40 + PillShadow.top + PillShadow.bottom
    )

    func show(_ state: PillState) {
        generation &+= 1
        pendingDismissal?.cancel()
        pendingDismissal = nil
        model.state = state

        // Reuse the panel a fade has not finished with yet, rather than leaving it to
        // wander off screen on its own while a new one appears underneath it.
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
            resizeToFit()
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        panel.alphaValue = 1

        let host = NSHostingView(rootView: PillView(model: model))
        panel.contentView = host

        self.panel = panel
        self.host = host
        resizeToFit()
        panel.orderFrontRegardless()
    }

    /// Ask SwiftUI how big the pill actually wants to be, then match the panel to it and
    /// re-centre. Without this the panel keeps whatever width the widest state needed.
    private func resizeToFit() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()

        // Floors, not targets — they only matter for a state narrower than the shadow
        // margins, and they have to clear those margins or the panel would clip the very
        // thing it is sized to contain.
        var size = host.fittingSize
        size.width = max(size.width, 120 + PillShadow.side * 2)
        size.height = max(size.height, 40 + PillShadow.top + PillShadow.bottom)

        panel.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        position(panel)
    }

    func update(level: Float) {
        model.push(level)
    }

    func update(state: PillState) {
        model.state = state
        // Let the new content lay out first, then fit the panel around it.
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
    }

    /// Fades out after `delay`, so a result is readable before the pill disappears.
    ///
    /// The panel is held until the fade actually completes. A `show` arriving in the
    /// meantime cancels the fade and takes the panel back, which is what keeps a burst of
    /// quick presses to one pill instead of a pile of them.
    func dismiss(after delay: TimeInterval = 0) {
        guard panel != nil else { return }
        generation &+= 1
        let token = generation

        pendingDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, let panel = self.panel else { return }
            self.pendingDismissal = nil
            self.fadeOut(panel, token: token)
        }
        pendingDismissal = work

        guard delay > 0 else { return work.perform() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut(_ panel: NSPanel, token: Int) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit runs this on the main thread; the compiler just can't see that.
            MainActor.assumeIsolated {
                // A new take may have claimed this panel mid-fade — `show` already restored
                // its opacity, so ordering it out here would hide a pill that is in use.
                guard let self, self.generation == token else { return }
                panel.orderOut(nil)
                if self.panel === panel {
                    self.panel = nil
                    self.host = nil
                }
            }
        }
    }

    private func position(_ panel: NSPanel) {
        // Bottom centre of the screen the mouse is on, clear of the Dock. Centring uses
        // the panel's *current* width, so it stays centred as the pill resizes.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + PillShadow.heightAboveScreenBottom - PillShadow.bottom
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - View

private struct PillView: View {
    @ObservedObject var model: PillModel

    /// Drives the transcribing dot's pulse — a static dot would look stalled.
    @State private var pulse = false

    var body: some View {
        // No maxWidth: the pill must size to its content, or every state inherits the
        // width of the widest one — which is why "Transcribing…" had dead space to its
        // right where the waveform used to be.
        let pill = HStack(spacing: 10) {
            icon
            content
        }
        .padding(.horizontal, 16)
        .frame(height: 40)

        return Group {
            if #available(macOS 26.0, *) {
                pill.glassEffect(.regular, in: Capsule(style: .continuous))
            } else {
                pill
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    )
            }
        }
        .shadow(color: PillShadow.color, radius: PillShadow.radius, y: PillShadow.offsetY)
        // Room for the shadow to draw inside the panel instead of being clipped. Asymmetric
        // because the shadow is: the y offset moves the blur down, so the bottom needs more
        // room than the top and a uniform inset can only be right on one of them.
        .padding(.horizontal, PillShadow.side)
        .padding(.top, PillShadow.top)
        .padding(.bottom, PillShadow.bottom)
        .animation(.easeOut(duration: 0.18), value: model.state)
    }

    /// One dot in three colours, so the stage reads at a glance without any text:
    /// red recording, blue transcribing, green inserted. Failures keep a distinct glyph —
    /// a fourth colour of the same dot would be too easy to mistake for success.
    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .listening:
            dot(Self.recording)
        case .transcribing:
            dot(Self.working)
                .opacity(pulse ? 0.3 : 1)
                .onAppear { pulse = true }
                .onDisappear { pulse = false }
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: pulse
                )
        case .success:
            dot(Self.done)
        case .silent:
            dot(Self.quiet)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private static let recording = Color(red: 0.98, green: 0.24, blue: 0.24)
    private static let working = Color(red: 0.22, green: 0.56, blue: 0.99)
    private static let done = Color(red: 0.20, green: 0.80, blue: 0.42)
    /// Muted: nothing happened, which is not worth an alarming colour.
    private static let quiet = Color(red: 0.62, green: 0.64, blue: 0.68)

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .listening:
            Waveform(bars: model.bars)
        case .transcribing:
            label("Transcribing…")
        case .success:
            label("Inserted")
        case .silent:
            label("No speech")
        case let .failure(message):
            label(message, lines: 3)
        }
    }

    private func label(_ text: String, lines: Int = 1) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: lines > 1 ? 300 : nil, alignment: .leading)
    }
}

/// A centred, symmetric level display: every bar reacts to the current volume at once,
/// tallest in the middle, mirrored outwards. Bars grow from the centre line in both
/// directions rather than sitting on a baseline.
private struct Waveform: View {
    let bars: [Float]

    private let minHeight: CGFloat = 2.5
    private let maxHeight: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(.primary.opacity(0.85))
                    .frame(width: 2.5, height: height(for: value))
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.07), value: bars)
    }

    private func height(for value: Float) -> CGFloat {
        let amplitude = CGFloat(min(max(value, 0), 1))
        return minHeight + (maxHeight - minHeight) * amplitude
    }
}
