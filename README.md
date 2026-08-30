<img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+"> <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6"> <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">

# QuickTalk

**Hold a key, speak, let go — the text appears where your cursor is.**

A push-to-talk dictation app for macOS. It lives in the menu bar, has no Dock icon, and
uses Google's **Gemini 3.5 Transcribe** with your own API key. English and German are
detected automatically; there is no language setting to switch.

No dependencies, no telemetry, no accounts. One network destination, and it's Google's.

---

## Contents

- [Install](#install) · [First run](#first-run) · [Using it](#using-it)
- [Modes](#modes) · [Per-app instructions](#per-app-instructions)
- [Permissions](#permissions) · [Troubleshooting](#troubleshooting)
- [Where your API key is stored](#where-your-api-key-is-stored) · [Privacy](#privacy)
- [How it works](#how-it-works) · [Building and contributing](#building-and-contributing)

---

## Install

There is no download. **You build it yourself** — one command, no Xcode project, no
dependencies:

```bash
./build.sh
```

That compiles, assembles the `.app`, signs it, and installs it to `/Applications`. Then:

```bash
open /Applications/QuickTalk.app
```

You need macOS 14 or later and the Swift toolchain (`xcode-select --install` is enough).

> **Why no prebuilt download?** See [Building and contributing](#building-and-contributing).
> Short version: a downloadable app that macOS will actually run requires a paid Apple
> Developer account, and a self-built copy is both safer for you and works better with
> macOS permissions.

## First run

Settings opens automatically. Work top to bottom:

1. **Paste your Gemini API key** — free from [aistudio.google.com](https://aistudio.google.com).
2. **Grant Input Monitoring**, then **quit and reopen QuickTalk.** The restart is not
   optional — see [Permissions](#permissions).
3. **Grant Accessibility** — takes effect immediately.
4. **Grant Microphone** — you'll be asked on your first dictation.

The menu-bar item is the source of truth. When it reads **"Hold Right ⌘ to dictate"**,
everything is live. If something is missing, it names which permission.

---

## Using it

Hold **Right ⌘**, speak, release. A pill appears at the bottom of the screen with a level
meter that swells from the centre with your voice, switches to "Transcribing…", and the
text is pasted at your cursor.

Presses shorter than 0.25 s are ignored, so brushing the key does nothing.

The pill shows the stage as a coloured dot — **red** recording, **blue** transcribing,
**green** inserted, **grey** "No speech" when nothing was said. Errors get a bigger pill
and the full message.

| Setting | Default | Notes |
|---|---|---|
| Push-to-talk key | Right ⌘ | Also Left ⌘, Right/Left ⌥, Right ⌃, fn |
| Microphone | System Default | Any connected input, remembered per device |
| Mode | Smart | See below |
| Start cue | Purr | Six system sounds, previewed as you pick |
| App instructions | none | Per-app notes, added in Smart mode |

Mode can be switched without opening Settings: click the menu-bar icon and pick one under
**Formatting**. The menu also has **Copy Diagnostics**, which puts the recent log on your
clipboard for bug reports.

### Modes

| Mode | How | Formatting | Cost per ~6 s dictation |
|---|---|---|---|
| **Verbatim** | streamed while you speak | none — word for word | ~$0.0009 |
| **Smart** | streamed, then tidied | paragraphs and real lists | ~$0.0013 |
| **Cheap** | one request after you finish | none | ~$0.0005 |

At 100 dictations a day that's roughly **$2.60 / $3.80 / $1.50 a month**.

Verbatim and Smart stream audio over a WebSocket *while you speak*, so the transcript is
essentially ready when you release the key. Smart then runs a second, cheap pass that adds
structure. Cheap skips streaming to avoid the live model's 1.75× token premium.

Streaming is failure-tolerant by design: the audio file is written to disk even during a
live session, so if the socket fails at any point the batch request runs instead with the
same settings. **A failed socket costs latency, never words.**

### Per-app instructions

Dictating into a chat app and dictating into an editor want different output from the same
voice. QuickTalk notices which app was frontmost when you pressed the key and adds that
app's standing instructions to the Smart formatting pass.

Open **App Instructions…** from the menu bar (or *Manage Apps…* in Settings), add an app,
and write what should happen:

| App | Instruction |
|---|---|
| WhatsApp | Use plenty of emojis and keep it casual. Never add a greeting. |
| Mail | Full sentences, no contractions. Sign off politely. |
| Visual Studio Code | Plain prose. Never add emojis or markdown formatting. |

The menu bar shows which app you're pointed at — `WhatsApp — instructions on` — and
clicking that row jumps straight to its rule. Each app has a switch, so a rule can be
parked without losing what it said.

Three things worth knowing:

- **Smart mode only.** The instructions ride along with the formatting pass, and the other
  two modes have no formatting pass to put them in. The window says so when you're in the
  wrong mode rather than silently doing nothing.
- **The app it detects is the one you were in when you started talking**, not where the
  cursor ends up. That's deliberate — it's the app you meant.
- **A wholesale rewrite is still rejected.** Instructions widen how much the pass may
  change, but a result that stopped being your dictation is thrown away and the raw
  transcript is pasted instead.

Reading the frontmost app needs **no extra permission** — an app's name and bundle ID are
public metadata, the same thing the Dock shows. QuickTalk never reads window titles or
contents.

---

## Permissions

Three separate grants. They are genuinely different things, and getting them confused
accounts for nearly every "it doesn't work" report.

| Permission | What it's for | Restart needed? |
|---|---|---|
| **Input Monitoring** | Seeing the push-to-talk key while you're in *another* app | **Yes** |
| **Accessibility** | Pasting the result into the frontmost app | No |
| **Microphone** | Recording | No |

### Why they break

- **Input Monitoring is not Accessibility.** Without it, `CGEvent.tapCreate` still
  *succeeds* and still delivers events — but only this app's own. The symptom is a hotkey
  that works while QuickTalk is frontmost and does nothing anywhere else. There is no
  error to catch.
- **Granting Input Monitoring doesn't fix a running process.** The existing tap stays
  crippled; quit and reopen. Accessibility, by contrast, is picked up live.
- **macOS keys permissions on path *and* code signature.** Two copies of the app are two
  identities: the Privacy list shows both as "QuickTalk", and toggling the wrong one looks
  exactly like a permission that is on but ignored. `build.sh` therefore installs only to
  `/Applications` and deletes its build-folder copy.

### Resetting them

```bash
killall QuickTalk; tccutil reset Microphone com.quicktalk.QuickTalk; tccutil reset Accessibility com.quicktalk.QuickTalk; tccutil reset ListenEvent com.quicktalk.QuickTalk
```

`tccutil`'s service names don't match the UI labels — **Input Monitoring is
`ListenEvent`**.

---

## Troubleshooting

**Hotkey does nothing outside QuickTalk** → Input Monitoring. Grant it, then quit and
reopen.

**Permission shows enabled in System Settings but the app disagrees** → a stale entry for
an older copy or signature. Run the reset above, remove any duplicate QuickTalk rows with
the **–** button, and re-grant.

**"No speech" when you did speak** → check the microphone picker. **Copy Diagnostics**
shows `peakLevel` per take: real speech reads 0.019 or higher, silence 0.000–0.002. A peak
near zero means capture failed, not the API.

**Bluetooth headphones go muffled while dictating** → pick the **built-in microphone** in
Settings rather than "System Default". A Bluetooth headset cannot carry high-quality
playback and a microphone at the same time — opening its mic switches the device from A2DP
to HFP, and playback drops from stereo at 44.1 kHz to mono at 16 kHz until the recording
stops. That's the headset's limitation, not the app's. QuickTalk opens exactly the device
you pick and nothing else, so choosing the built-in mic leaves your music untouched.
Settings flags the choice when it would degrade playback.

**Everything else** → the pill shows the full error, and `~/Library/Logs/QuickTalk.log`
has the details.

---

## Where your API key is stored

In a file only your macOS account can read:

```
~/Library/Application Support/QuickTalk/gemini-api-key      mode 0600, in a 0700 directory
```

- **Not in preferences.** An API key in `UserDefaults` is printed in full by
  `defaults read com.quicktalk.QuickTalk` — a real leak the moment someone pastes their
  settings into a bug report.
- **Not in the Keychain.** macOS grants keychain access per code signature, so every build
  with a different signature raises a password overlay. Self-built copies are usually
  signed ad-hoc, whose signature changes on *every* build. That's a wall of dialogs for
  no gain.
- **Excluded from Time Machine**, so it doesn't spread into backups.
- **Never logged.** The key is sent in a request header, never in a URL, and the
  diagnostics log redacts anything key-shaped as a backstop — so **Copy Diagnostics**
  output is safe to paste into an issue.
- **Removable.** Settings has a **Remove** button next to the key field.

**What this does not do:** protect the key from other software running as *you*. No local
store does — anything that can decrypt a key can be read by whatever decrypts it, and the
Keychain only raises the bar. Treat it as a credential on a trusted machine. If that stops
being true, revoke it at [aistudio.google.com](https://aistudio.google.com); it takes a
second and is the only real remedy.

## Privacy

- **The key tap watches `flagsChanged` only** — modifier keys. No keystrokes, and
  therefore no passwords, pass through this process. It's `.listenOnly`, so it observes
  without consuming: your push-to-talk key keeps working normally.
- **The microphone is open only while you hold the key.** The audio unit is built on press
  and torn down on release — no idle audio session, no lingering orange indicator.
- **Audio is deleted after upload**, including when transcription fails.
- **App detection reads a name and a bundle ID, nothing more.** No window titles, no
  contents, no extra permission. Your instructions are logged by length, never content.
- **Your clipboard is restored** after the paste.
- **One network destination**, `generativelanguage.googleapis.com`. No analytics, no
  telemetry, no third-party dependencies — nothing beyond Apple's own frameworks.

---

## How it works

### Why streaming is faster

Measured across 29 real dictations, the batch path costs **≈2.9 s fixed + 0.55 s per MB**
of audio. Size barely matters — ten times the audio adds about half a second — so nearly
all of it is inference and round trip paid *after* you stop talking. (Connection setup
isn't the culprit: DNS + TCP + TLS to Google measures 37 ms.)

The live socket moves that work to while you're still speaking. On key-up only the tail is
outstanding.

### API notes

Gemini 3.5 Transcribe, `POST /v1beta/interactions`. Two behaviours are easy to get wrong,
both verified against the live API:

1. **`mode: "smart"` only works on `/v1beta/interactions`.** On `:generateContent` the
   field parses but returns an empty text part. The model is named in the *body*, not the
   URL path, and the response envelope is `steps[].content[].text` — not `candidates`.
2. **Never send `language_codes` with smart mode.** It silently disables smart formatting
   and returns verbatim output: HTTP 200, no error, no signal. Google's own published
   example pairs them. Omitting it is also what enables automatic language detection —
   which is why English and German both work, and why there is no language setting.

Verbatim sends no `transcription_config` at all, because that's byte-identical to sending
`mode: "verbatim"` — it's the server default.

**Silence is not an error.** A take with no speech returns HTTP 200, `status: "completed"`,
and **no `steps` key at all** — so a parser expecting `steps` reports a malformed response
when nothing is wrong. That case maps to "No speech". Takes whose peak level is below
0.006 are never uploaded: the answer is instant and costs no request.

### Footprint

~700 KB binary, ~67 MB resident. Sampled while idle, the main thread sits 1690/1706
samples in `mach_msg2_trap` — genuinely asleep. There are no timers and no polling once
permissions are granted. Most of the memory is the SwiftUI + AppKit runtime rather than
anything this app allocates.

### Layout

```
Sources/QuickTalk/
├── main.swift              — NSApplication, .accessory (menu bar only)
├── AppDelegate.swift       — status item, state machine, permission watching
├── HotkeyMonitor.swift     — CGEventTap on flagsChanged; both key permissions
├── AudioRecorder.swift     — AUHAL capture → 16 kHz mono WAV, dB level metering
├── AudioDevices.swift      — CoreAudio device enumeration
├── LiveTranscriber.swift   — streaming transcription over a WebSocket
├── GeminiTranscriber.swift — batch transcription + the formatting pass
├── TextInserter.swift      — pasteboard + synthetic ⌘V, restores the clipboard
├── PillHUD.swift           — non-activating NSPanel + level meter
├── SettingsWindow.swift    — key, hotkey, mic, mode, permissions
├── AppRulesWindow.swift    — the per-app instruction editor
├── AppInstructions.swift   — per-app rules and their storage
├── FrontmostApp.swift      — which app you're dictating into
├── Settings.swift          — preferences and API key storage
└── Diagnostics.swift       — log + Copy Diagnostics
```

`CLAUDE.md` documents the platform traps behind the odd-looking code. Read it before
"simplifying" anything — most of it is load-bearing.

### The icon

`make-icon.swift` renders `AppIcon.icns` from the same `waveform` SF Symbol the menu bar
uses, so the Dock icon, the menu-bar glyph and the Settings header can't drift apart:

```bash
swift make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

---

## Building and contributing

```bash
./build.sh          # compile, assemble, sign, install to /Applications
swift build         # compile only (produces no runnable app)
```

There is deliberately **no Xcode project** and **no third-party dependencies**. Please
keep it that way.

### About signing

`build.sh` signs with your **Apple Development** certificate if you have one, and falls
back to ad-hoc signing with a warning if you don't. Both work, but the difference matters:

- **With a certificate**, your signature is stable across rebuilds, so macOS permissions
  are granted once and stay granted.
- **Ad-hoc**, the signature changes on every build, so macOS treats each build as a new
  app and you re-grant Input Monitoring and Accessibility each time. Annoying, not fatal.

A free Apple Developer account is enough to get a development certificate through Xcode.

### Why there's no prebuilt binary to download

This was considered and rejected:

1. **Gatekeeper would block it.** A downloaded app that isn't notarised gets "cannot be
   opened because the developer cannot be verified". Notarisation requires the **paid**
   Apple Developer Program and a Developer ID certificate.
2. **A development-signed build won't run on other Macs** at all.
3. **A signature identifies its signer.** Anyone can read the signer's name and Team ID
   out of a shipped binary with `codesign -dvvv`.
4. **An app that can type into every window deserves to be read before it's run.**
   Building from source takes one command and about thirty seconds.

If you fork this and want to ship releases, you'll need a Developer ID certificate,
`xcrun notarytool`, and your own bundle identifier — change `CFBundleIdentifier` in
`Info.plist` and the matching `--identifier` in `build.sh` to your own reverse-DNS name.

### Verifying a change

There are no automated tests. Check by hand:

1. `./build.sh`, then `open /Applications/QuickTalk.app`.
2. The menu bar reads "Hold Right ⌘ to dictate" — if not, it names the missing permission.
3. **Switch to another app**, hold the key, speak, release. The overlay must appear there,
   not only in QuickTalk. (This step is what catches a missing Input Monitoring grant.)
4. **Copy Diagnostics** shows the device it actually opened, byte count, peak level, and
   any HTTP error with the real server message.

---

## License

MIT — see [LICENSE](LICENSE).
