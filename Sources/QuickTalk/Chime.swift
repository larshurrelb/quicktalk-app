import AppKit

/// The start and stop chirps, played off the main thread.
///
/// `NSSound.play()` opens the default *output* device, and the first play after that output
/// has gone idle blocks until the device is ready. Measured with a Bluetooth headset as the
/// default output: **744 ms**, and 1631 ms on a colder link — the A2DP connection has to
/// wake before anything can be written to it. None of that is avoidable. QuickTalk wants to
/// make a sound, and making a sound means waking the speakers.
///
/// What *was* avoidable is paying for it on the main thread. `beginRecording` played the
/// chirp inline, ahead of the microphone, so pressing the hotkey with headphones connected
/// froze the app for up to a second and a half before it even began opening the input: the
/// pill could not appear and the event tap could not be serviced. It is the same mistake
/// the microphone open used to make, one device over — the app was opening the *speakers*
/// before the microphone, and the speakers were the slow part. After that was fixed the
/// device open measured 44–95 ms while key-down-to-ready was still crossing a second, which
/// is what pointed here.
///
/// A chirp that arrives a beat late is only a late chirp. A pill that arrives a beat late
/// looks like a broken app.
enum Chime {
    /// Serial, so the stop chirp cannot overtake a start chirp still waiting on the device.
    /// Every `NSSound` below is created and driven here and nowhere else, which is what
    /// makes using AppKit's sound API off the main thread safe.
    private static let queue = DispatchQueue(label: "com.quicktalk.QuickTalk.chime", qos: .userInitiated)
    private static var cache: [String: NSSound] = [:]

    static func play(_ name: String) {
        queue.async {
            guard let sound = sound(named: name) else { return }
            // `play()` on a sound that is already playing returns false and does nothing,
            // so a quick second dictation would otherwise be silent.
            if sound.isPlaying { sound.stop() }
            sound.play()
        }
    }

    /// Cached because `NSSound(named:)` reads the sound off disk — another 14 ms the first
    /// time, for nothing.
    private static func sound(named name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        // `NSSound(named:)` hands back a shared instance, so take a copy rather than
        // driving an object the rest of AppKit may also be using.
        let sound = NSSound(named: name)?.copy() as? NSSound
        cache[name] = sound
        return sound
    }
}
