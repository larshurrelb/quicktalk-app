# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A macOS push-to-talk dictation app. Hold Right ⌘ → record → Gemini 3.5 Transcribe →
paste at the cursor. Menu-bar only (`LSUIElement`), SwiftPM executable assembled into an
`.app` by `build.sh`. No third-party dependencies, and it should stay that way.

## Build and run

```bash
./build.sh
```

Compiles, signs, installs to `/Applications`, removes the build-folder copy. There is no
Xcode project — don't add one.

- `swift build -c release` alone compiles but produces no runnable app; permissions need
  a signed bundle.
- **Never leave a second copy of the app on disk.** TCC keys permissions on path *and*
  signature, so a copy in the build folder is a separate identity to macOS and shows up
  as a duplicate "QuickTalk" in the Privacy lists. `build.sh` deletes it deliberately.
- The build signs with the user's **Apple Development** certificate when present. Do not
  "simplify" this back to ad-hoc: an ad-hoc signature changes with every code change,
  which silently invalidates every granted permission. That produced hours of
  "Accessibility is green but the app says it isn't".

## Hard-won gotchas

Each of these cost real debugging time. Don't rediscover them.

### Permissions

- **Input Monitoring ≠ Accessibility.** Reading the keyboard via `CGEventTap` needs
  Input Monitoring (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`). Accessibility
  covers *posting* events (the synthetic ⌘V) and `AXIsProcessTrusted()`.
- Without Input Monitoring, `CGEvent.tapCreate` **succeeds** and delivers only this app's
  own events. It does not fail, so there is no error to catch — the symptom is a hotkey
  that works only while QuickTalk is frontmost.
- **Granting Input Monitoring does not fix a running process.** The app must be
  relaunched. Accessibility *can* be picked up live, which is why `AppDelegate` polls
  while untrusted and rebuilds the tap when trust arrives.
- `tccutil` service name for Input Monitoring is **`ListenEvent`**.

### Gemini API

- `mode: "smart"` works **only** on `POST /v1beta/interactions`. On `:generateContent`
  the field parses and returns an empty text part.
- **Never add `language_codes`.** With smart mode it silently returns verbatim output —
  HTTP 200, no error. Omitting it is also what gives automatic German/English detection.
  If someone asks for a language picker, the correct answer is that adding one breaks
  smart mode.
- Verbatim = omit `transcription_config` entirely; that is byte-identical to sending it.
- Modes are **Verbatim** (live, VERBATIM), **Smart** (live SMART + formatting pass) and
  **Cheap** (batch, verbatim). `TranscriptionMode.migrating` maps the retired `structured`
  and `live` raw values — don't drop it, it protects a stored preference.
- **The transcribe model ignores prompts and never returns markdown.** Spoken lists come
  back as run-on prose. That is what `structured` mode is for: a second
  `gemini-3.5-flash-lite` `:generateContent` call that reformats. It must stay guarded by
  `isFaithful` (rejects a pass that invents >15% new words) and must fall back to the raw
  transcript on any failure — losing a dictation to the tidying step is unacceptable.
- Response envelope is `steps[] → content[] → text`, filtered on `type == "model_output"`
  and `type == "text"`. Not `candidates`.
- **Silence returns HTTP 200 with `status: "completed"` and no `steps` key.** It is not an
  error and must not be surfaced as one — map it to `TranscribeError.empty` → the `.silent`
  pill state ("No speech"), never `.badResponse`. `AppDelegate` also gates on
  `recorder.peakLevel` (< 0.006) and skips the upload entirely; observed peaks are
  0.000–0.002 for silence against 0.019+ for speech.

### Per-app instructions

- The frontmost app is read with `NSWorkspace.shared.frontmostApplication`, which needs
  **no permission at all** — bundle ID and localised name are public process metadata.
  Reading window *titles* or contents would need Screen Recording; don't go there.
- Rules are keyed on **bundle ID**, never the name. Names are localised and change
  between versions.
- `FrontmostAppTracker` **must ignore QuickTalk's own bundle ID.** Settings and the App
  Instructions window both make the app frontmost, and the status menu can too — adopting
  our own ID would forget the real target at the exact moment the user is configuring it.
  It is notification-driven (`didActivateApplication`), never polled, plus a `refresh()`
  at key-down.
- The target app and its instructions are captured in `beginRecording`, not read again
  later. By the time the transcript returns the user may have switched windows.
- Instructions only reach the **formatting pass**, so they only do anything in Smart mode.
  The transcribe model ignores prompts entirely and the live socket has nowhere to put
  them — there is no second place to try. Both the Settings caption and the rules window
  say so out loud, because "I wrote instructions and nothing happened" is otherwise
  indistinguishable from a bug.
- `isFaithful` gets a **looser tolerance (0.5) when instructions are present**. "Use more
  emojis" is an explicit licence to add words, and the 0.15 default would throw the result
  away. It still runs: a pass that answered the dictation instead of formatting it is
  caught at either threshold. Emoji alone never trip it — they are non-alphanumeric, so
  the word comparison drops them.
- Instructions are the *user* speaking to the model and may override the formatting rules;
  the transcript never can. That is why they go in their own `<user-instructions>` block
  with the precedence stated explicitly, right next to `<transcript>`.
- The `+` in the rules window is an **NSMenu popped at click time**, not SwiftUI's `Menu`.
  Under `BorderlessButtonMenuStyle` in a narrow fixed frame SwiftUI rendered a `+` that
  did not respond to clicks at all — nothing to catch, it simply did nothing. Building the
  menu per click is also what keeps the app list current: apps launch and quit while the
  window is open, so a snapshot taken in `onAppear` goes stale.
- `NSMenuItem.target` is **weak**. The closure carrier has to be retained by
  `representedObject`, or every item comes up dead — the same symptom as above.
- `menu.popUp(…, in: nil)` reads the location in **screen** coordinates, which is why it
  takes no window. Going through `NSApp.keyWindow` reintroduces a nil path that silently
  shows no menu.
- The rules window's layout must be **flexible everywhere**. `TextEditor` has an
  unbounded ideal height, and `NSHostingView` reports its content's ideal size upward as
  the window's size — so a bare `minHeight` on the editor laid out 2016pt of content in a
  420pt window and pushed the app list off-screen. The window looked empty while the rules
  were stored and correct, which sends you hunting in the store instead of the layout.
  Two things keep it honest: `idealHeight` on the editor (`maxHeight` alone only grants
  permission to grow, it does not shrink the ideal) and `sizingOptions = []` on the
  hosting view. `SettingsWindow` avoids all of this only because it is a fixed
  `.frame(width:height:)`.
- The log records instruction **length only**, never the text — `Copy Diagnostics` puts
  the log on the clipboard.

### Live socket

- `wss://…/BidiGenerateContent`, model `gemini-3.5-transcribe-live`. The key goes in the
  **`x-goog-api-key` header, never `?key=`** — a query-string key lands verbatim in proxy
  and crash logs.
- **`activityEnd` must never overtake the audio in front of it.** The server finalises on
  what it has received, so an end frame that jumps the queue truncates the last words.
  Every frame goes through one serial `sendQueue`, which is what guarantees the ordering.
- Automatic voice detection is **disabled**: the hotkey defines turn boundaries, and
  server-side VAD would cut the turn whenever the speaker pauses to think.
- Check `interimInputTranscription` **before** `inputTranscription` — a frame can carry
  both, and treating an interim as final puts speculative text on the user's cursor.
- Accept camelCase *and* snake_case; the documented clients disagree, and guessing wrong
  looks identical to a model that transcribes nothing.
- Same `languageCodes` prohibition as the batch path.
- The WAV is always written, even in live mode, so **every** live failure falls back to
  the batch request. Losing words is unacceptable; being slow is not.

### Audio

- **Capture is a raw AUHAL, not `AVAudioEngine`. Do not "simplify" it back.**
  `AVAudioEngine.start()` silently rebinds its input to a system
  `CADefaultDeviceAggregate` wrapping the *default* input device, discarding whatever was
  set on the input node. Setting `kAudioOutputUnitProperty_CurrentDevice` on
  `engine.inputNode` succeeds, reads back correctly, survives `prepare()` — and is thrown
  away by `start()`. Measured directly: after `start()` the unit's current device reads
  `CADefaultDeviceAggregate-…`, never the device that was set.
  - Consequence 1: the microphone picker did nothing for months. Every recording came
    from the system default input.
  - Consequence 2: with Bluetooth headphones as the default input, every dictation opened
    their microphone and flipped them A2DP → HFP, dropping playback from 2ch/44.1 kHz to
    1ch/16 kHz for the whole take — even with the built-in mic selected.
  - An AUHAL (`kAudioUnitSubType_HALOutput`) takes the device *before*
    `AudioUnitInitialize` and keeps it. Verified by watching the Bluetooth device's
    channel count and rate across a recording: it now stays at 2ch/44.1 kHz.
- **Always resolve "system default" to a concrete `AudioDeviceID` and bind that.** Asking
  CoreAudio for "the default device" is what builds the aggregate that drags the Bluetooth
  microphone in. Naming a device opens that device and nothing else.
- A Bluetooth headset genuinely cannot do good playback and microphone at once — that is
  the profile switch, not something the app can fix. Choosing a Bluetooth mic (directly or
  via System Default) *should* degrade playback; Settings says so rather than pretending
  otherwise.
- The input format must be read **after** the device is bound — a different device can
  mean a different sample rate and channel count.
- Store the CoreAudio **device UID**, never the numeric `AudioDeviceID` (only stable
  within a boot).
- Level metering is on a **dB scale**, not linear RMS. Linear was why normal speech
  barely moved the waveform: conversational level is ~0.02 RMS, which is near the floor
  linearly but around 0.5 on the dB mapping.

### UI

- The pill is an `NSPanel` with `.nonactivatingPanel` — it must never take focus, or the
  paste lands in the wrong place. Don't call `NSApp.activate` around it.
- Errors get a larger panel and three lines. A one-line pill made failures unreadable
  exactly when they mattered.
- The pill **sizes itself to its content** via `NSHostingView.fittingSize`, and
  `position()` re-centres using the panel's current width. Never give the root view
  `maxWidth: .infinity` — every state then inherits the widest one's width, which is how
  "Transcribing…" ended up with dead space beside it. The root view keeps a `.padding(14)`
  so the shadow has room inside the panel instead of being clipped.
- Background is `glassEffect(.regular, in: Capsule())` under `#available(macOS 26)`, with
  `.ultraThinMaterial` as the fallback. Text and bars use `.primary`, not white — glass
  takes on whatever is behind it, and fixed white is unreadable over a light window.
- The waveform is a **centred symmetric visualiser**, not a scrolling history: every bar
  reacts to the current level at once, tallest in the middle. Bar values are computed in
  `PillModel.push` from the audio callback (~23/s), so there is no render timer — don't
  reach for `TimelineView`, it would redraw at 60fps for no benefit. The per-bar `phase`
  shimmer is what stops the cluster looking like one shape being scaled.

- The status menu is refreshed in `menuWillOpen`, not pushed to from elsewhere. Mode can
  change from either the menu or Settings, and permissions change outside the app
  entirely; reading state when the menu opens keeps all of it correct with no cross-wiring.
  `SettingsWindowController.reloadIfVisible()` handles the other direction, because the
  SwiftUI view seeds its `@State` only at construction.

## Conventions

- Comments explain *why*, especially where the code looks odd — most of the odd-looking
  code here is working around one of the gotchas above. Keep those comments; they are
  load-bearing.
- Secrets: the API key lives in a `0600` file at
  `~/Library/Application Support/QuickTalk/gemini-api-key`, inside a `0700` directory and
  excluded from Time Machine. Two stores were rejected and both rejections were measured:
  - **Keychain** — access is granted per code signature, so any build signed differently
    from the one that stored the item raises a password overlay. Re-signing with the same
    certificate reads back silently; an ad-hoc re-sign prompts. Since contributors build
    ad-hoc, that is a wall of dialogs for them.
  - **`UserDefaults`** — puts a credential where `defaults read com.quicktalk.QuickTalk`
    prints it in full, which leaks the moment anyone pastes their settings into an issue.
  - Be honest in docs about what the file does *not* do: it stops other accounts and
    backups, not other software running as the same user. Nothing local does.
  The key must never be logged or written anywhere else. `Diagnostics` never receives it,
  and redacts anything `AIza`-shaped as a backstop.
- The key tap must stay `flagsChanged`-only and `.listenOnly`. Widening it to keyboard
  events would put every keystroke, passwords included, through this process.
- Idle cost matters: no timers, no audio session, no polling once permissions are
  granted.

## Verifying a change

There are no tests. Check by hand:

1. `./build.sh`, then `open /Applications/QuickTalk.app`.
2. Menu bar reads "Hold Right ⌘ to dictate" — if not, it names the missing permission.
3. Switch to **another app**, hold Right ⌘, speak, release. Overlay must appear there,
   not only in QuickTalk.
4. `~/Library/Logs/QuickTalk.log` or **Copy Diagnostics** shows device, bytes, peak level,
   request mode, and any HTTP error with the real server message. The log names the device
   it actually opened — check it matches what Settings has selected. It used to say
   "system default" whichever was picked, which is how the picker being ignored went
   unnoticed.
5. With Bluetooth headphones connected and the *built-in* mic selected, play music and
   dictate. The music must not change. If it goes muffled and mono, capture has fallen
   back to the default-device path again.

A `peakLevel` near 0 means capture failed, not the API.

## Don't

- Don't add dependencies, an Xcode project, or a language picker.
- Don't feed per-app instructions to the transcribe model or the live socket. Neither
  takes prompts; it looks like it works and silently does nothing.
- Don't revert to ad-hoc signing.
- Don't move capture back to `AVAudioEngine`. It looks tidier and silently ignores the
  microphone picker.
- Don't read the key more than once per launch — `KeyStore` caches it, and repeated reads were half of what made the old Keychain implementation unbearable.
- Don't ship a second copy of the app anywhere on disk.
