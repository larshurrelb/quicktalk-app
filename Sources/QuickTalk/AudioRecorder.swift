import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures the microphone into a small mono file and reports a live level for the HUD.
///
/// The unit only exists while you are actually holding the key: it is created on start
/// and torn down on stop, so the app holds no audio session — and no microphone
/// indicator — while idle.
///
/// **Capture goes through a raw AUHAL audio unit, not `AVAudioEngine`.** That is not a
/// style preference. `AVAudioEngine.start()` silently rebinds its input to a system
/// "CADefaultDeviceAggregate" wrapping the *default* input device, discarding any device
/// set on the input node beforehand — the set succeeds, reads back correctly, and is then
/// thrown away by `start()`. Two things followed from that:
///
///   * the microphone picker in Settings did nothing; every recording came from whatever
///     macOS currently called the default input;
///   * with Bluetooth headphones as that default, opening their microphone flipped them
///     from A2DP to HFP — so music dropped from 2ch/44.1 kHz to 1ch/16 kHz for the
///     length of every dictation, even with the built-in mic selected.
///
/// An AUHAL takes `kAudioOutputUnitProperty_CurrentDevice` *before* `AudioUnitInitialize`
/// and keeps it, so nothing but the chosen device is ever opened. Verified by watching the
/// Bluetooth device's channel count and sample rate across a recording.
///
/// `@unchecked Sendable` is a claim about discipline rather than an escape hatch, so here
/// is the discipline: every mutable field is written on `control`, or on the audio thread
/// that `control` starts and stops around. The two callbacks are ordered rather than
/// locked: `onLevel` is set once at launch, and `onPCM` is written in exactly two places —
/// from the caller *before* `start`, which crosses `control` before the IO thread exists,
/// and by `close()` on `control` itself, once the IO thread is gone. Neither can race a
/// callback that is actually running, which is why no caller may clear `onPCM` itself.
final class AudioRecorder: @unchecked Sendable {
    /// 16 kHz mono is plenty for speech and keeps the upload small, which is most of the
    /// round-trip time for a short dictation.
    private static let sampleRate: Double = 16_000

    /// **Every CoreAudio call below runs here, never on the main thread.**
    ///
    /// Opening an input device is neither quick nor bounded. Measured across 98 takes in
    /// the diagnostics log, the gap between key-down and `recording started` was under a
    /// second 84 times and reached **three seconds** three times — all of them with the
    /// *built-in* microphone selected, so a Bluetooth profile switch is not the
    /// explanation. (What is, the new `open=` timing breakdown will say next time it
    /// happens.) Sitting on the main thread through that costs far more than the wait:
    ///
    ///   * the pill cannot appear, so a slow start is indistinguishable from a dead app;
    ///   * macOS disables an event tap whose run loop stops answering, and the event most
    ///     likely to be lost is the key *release* — leaving the app recording with nothing
    ///     left to stop it.
    ///
    /// The queue is serial, so start, stop and discard can never overlap and the audio
    /// callback still sees a single writer for everything it touches.
    private let control = DispatchQueue(label: "com.quicktalk.QuickTalk.recorder", qos: .userInitiated)

    /// One finished recording.
    ///
    /// The peak travels with the file rather than being read off the recorder afterwards:
    /// it is written from the audio thread, and the only moment it can be read safely is
    /// once capture has stopped — which is exactly when this is handed over.
    struct Take {
        let fileURL: URL
        let peakLevel: Float
    }

    /// The input bus of an AUHAL. Bus 0 is output to the device, which we disable.
    private static let inputBus: AudioUnitElement = 1
    private static let maxFramesPerSlice: AVAudioFrameCount = 4096

    private var unit: AudioUnit?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var fileURL: URL?

    /// Rendered into on the audio thread. Allocated once at start, because the render
    /// callback is real-time and must not allocate.
    private var captureBuffer: AVAudioPCMBuffer?

    /// 0...1, already smoothed for display.
    var onLevel: ((Float) -> Void)?

    /// 16 kHz mono Int16 PCM, for streaming to the live socket. The WAV file is written
    /// either way, so a live session that fails can still fall back to the batch request.
    var onPCM: ((Data) -> Void)?

    private var smoothedLevel: Float = 0
    /// Loudest sample seen this take — a peak of ~0 means the wrong input was captured.
    /// Written on the audio thread, read only once capture has stopped, via `Take`.
    private var peakLevel: Float = 0

    /// Only ever touched on `control`; callers track the take's phase themselves, because
    /// between key-down and the device answering there is no useful answer to give.
    private var isRecording = false

    enum RecorderError: Error {
        case noInputDevice
        case couldNotCreateFile
        /// Carries the CoreAudio status so a failure names itself in the diagnostics log.
        case couldNotConfigure(String, OSStatus)
    }

    private struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    // MARK: - Control

    /// Opens the microphone and begins capture. `deviceUID` empty follows the system
    /// default input.
    ///
    /// Async because the work behind it can block for seconds — see `control`.
    func start(deviceUID: String = "") async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                do {
                    try open(deviceUID: deviceUID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops capture and returns the finished take, or nil if nothing was recorded.
    func stop() async -> Take? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Take?, Never>) in
            control.async { [self] in continuation.resume(returning: close()) }
        }
    }

    /// Throws the current take away. Fire-and-forget: nobody is waiting on a recording
    /// that is being discarded, and making the caller wait would put the queue's latency
    /// back on the main thread for no reason.
    func discard() {
        control.async { [self] in
            if let take = close() { try? FileManager.default.removeItem(at: take.fileURL) }
        }
    }

    /// `discard()` for callers that must not outlive it — app termination, where a
    /// fire-and-forget cleanup would simply not happen.
    func discardAndWait() {
        control.sync { if let take = close() { try? FileManager.default.removeItem(at: take.fileURL) } }
    }

    private func open(deviceUID: String) throws {
        closeEngine()

        // Timed in three parts, because "sometimes it takes a moment to start" is not
        // something you can act on. Resolve being slow means HAL contention — something
        // else on the machine, a Bluetooth headset most likely, is keeping coreaudiod
        // busy. Configure or start being slow means the chosen device itself is taking
        // its time. The wait is off the main thread either way, so this is now a number
        // to read rather than a freeze to explain.
        let began = DispatchTime.now()
        let device = try Self.resolve(uid: deviceUID)
        let resolved = DispatchTime.now()
        let unit = try Self.makeInputUnit(device: device.id)
        var failed = true
        defer { if failed { AudioComponentInstanceDispose(unit) } }

        // The hardware's own format, read after the device is bound — a different device
        // can mean a different sample rate and channel count.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let readStatus = AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Self.inputBus, &hardware, &size
        )
        guard readStatus == noErr, hardware.mSampleRate > 0 else {
            throw RecorderError.couldNotConfigure("read hardware format", readStatus)
        }

        // What we want handed to us: deinterleaved float at the hardware's own rate.
        // Rate and channel conversion happen once, later, in the AVAudioConverter that
        // already feeds the file — no need to ask the unit to do it too.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardware.mSampleRate,
            channels: AVAudioChannelCount(max(1, hardware.mChannelsPerFrame)),
            interleaved: false
        ) else { throw RecorderError.noInputDevice }

        var client = clientFormat.streamDescription.pointee
        let formatStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, Self.inputBus,
            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard formatStatus == noErr else {
            throw RecorderError.couldNotConfigure("set client format", formatStatus)
        }

        var maxFrames = Self.maxFramesPerSlice
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFrames, UInt32(MemoryLayout<AVAudioFrameCount>.size)
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicktalk-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        // Linear PCM keeps this dependency-free and decodes everywhere. A 15-second
        // dictation is ~480 KB, which uploads in a blink.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else {
            throw RecorderError.couldNotCreateFile
        }
        guard let converter = AVAudioConverter(from: clientFormat, to: file.processingFormat),
              let captureBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: maxFrames)
        else { throw RecorderError.couldNotCreateFile }

        var callback = AURenderCallbackStruct(
            inputProc: Self.render,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let callbackStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else {
            throw RecorderError.couldNotConfigure("set input callback", callbackStatus)
        }

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            throw RecorderError.couldNotConfigure("initialize", initStatus)
        }
        let configured = DispatchTime.now()

        // Everything the callback touches must be in place before IO starts.
        self.unit = unit
        self.file = file
        self.converter = converter
        self.captureBuffer = captureBuffer
        self.fileURL = url
        self.smoothedLevel = 0
        self.peakLevel = 0

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            AudioUnitUninitialize(unit)
            self.unit = nil
            self.file = nil
            self.converter = nil
            self.captureBuffer = nil
            self.fileURL = nil
            // The WAV was created before the unit was started; nothing will ever read it.
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.couldNotConfigure("start", startStatus)
        }

        failed = false
        isRecording = true
        let running = DispatchTime.now()
        // The device *name* is logged, not just the stored UID. When the picker was
        // silently ignored, the log said "system default" either way and hid the bug.
        Diagnostics.log(
            "recording started device=\(device.name) [\(device.uid)] "
            + "rate=\(Int(hardware.mSampleRate))Hz ch=\(Int(hardware.mChannelsPerFrame)) "
            + "open=\(Self.ms(began, running))ms "
            + "(resolve \(Self.ms(began, resolved)), configure \(Self.ms(resolved, configured)), "
            + "start \(Self.ms(configured, running)))"
        )
    }

    private static func ms(_ from: DispatchTime, _ to: DispatchTime) -> Int {
        Int((to.uptimeNanoseconds &- from.uptimeNanoseconds) / 1_000_000)
    }

    // MARK: - Device and unit setup

    /// The chosen device, or the system default when nothing is chosen or the chosen one
    /// is unplugged.
    ///
    /// The default is resolved to a concrete device ID here rather than left to CoreAudio.
    /// Asking for "the default device" is what makes macOS build the aggregate that drags
    /// the Bluetooth microphone in; naming a device opens that device and nothing else.
    private static func resolve(uid: String) throws -> Device {
        if !uid.isEmpty {
            if let id = AudioDevices.deviceID(forUID: uid) {
                return Device(id: id, uid: uid, name: AudioDevices.name(forDeviceID: id) ?? uid)
            }
            Diagnostics.log("microphone \(uid) isn't connected — falling back to the system default")
        }

        guard let id = AudioDevices.defaultInputDeviceID else { throw RecorderError.noInputDevice }
        return Device(
            id: id,
            uid: AudioDevices.uid(forDeviceID: id) ?? "",
            name: AudioDevices.name(forDeviceID: id) ?? "system default"
        )
    }

    private static func makeInputUnit(device: AudioDeviceID) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.noInputDevice
        }

        var instance: AudioUnit?
        let newStatus = AudioComponentInstanceNew(component, &instance)
        guard newStatus == noErr, let unit = instance else {
            throw RecorderError.couldNotConfigure("instantiate AUHAL", newStatus)
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)

        let enableStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &enable, flagSize
        )
        let disableStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, flagSize
        )
        guard enableStatus == noErr, disableStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw RecorderError.couldNotConfigure(
                "enable input", enableStatus != noErr ? enableStatus : disableStatus
            )
        }

        // The whole point of using an AUHAL: this is set before AudioUnitInitialize, and
        // unlike AVAudioEngine's input node it survives starting the unit.
        var id = device
        let deviceStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw RecorderError.couldNotConfigure("bind device", deviceStatus)
        }

        return unit
    }

    // MARK: - Capture

    /// Real-time audio thread. Renders into the pre-allocated buffer and hands it on.
    private static let render: AURenderCallback = { refcon, flags, timestamp, bus, frames, _ in
        let recorder = Unmanaged<AudioRecorder>.fromOpaque(refcon).takeUnretainedValue()
        return recorder.capture(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
    }

    private func capture(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffer = captureBuffer, frames <= buffer.frameCapacity else { return noErr }

        // Setting frameLength also fixes up the buffer list's mDataByteSize, which is what
        // AudioUnitRender checks against the frame count it was asked for.
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }

        append(buffer)
        return noErr
    }

    private func close() -> Take? {
        closeEngine()
        // Capture has stopped and the IO thread is gone, so this is the one safe moment to
        // drop the PCM consumer. Clearing it from the main thread — which is where the
        // live session is torn down — would race a callback still reading it.
        onPCM = nil

        guard isRecording else { return nil }
        isRecording = false
        let url = fileURL
        fileURL = nil

        guard let url else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        Diagnostics.log("recording stopped bytes=\(bytes) peakLevel=\(String(format: "%.3f", peakLevel))")
        return Take(fileURL: url, peakLevel: peakLevel)
    }

    private func closeEngine() {
        if let unit {
            // Synchronous: it does not return until the IO thread has stopped, so no
            // render callback can still be running when the buffers go away below.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        captureBuffer = nil
        file = nil
        converter = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let file, let converter else { return }

        let ratio = file.processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return }
        try? file.write(from: output)
        if let onPCM { onPCM(Self.int16PCM(from: output)) }
        let level = Self.rms(of: output)
        peakLevel = max(peakLevel, level)
        report(level: level)
    }

    private func report(level: Float) {
        let target = Self.normalized(level)

        // Attack fast, release slower — bars that snap up on a syllable and fall back
        // smoothly, rather than flickering.
        smoothedLevel = target > smoothedLevel
            ? smoothedLevel + (target - smoothedLevel) * 0.75
            : smoothedLevel + (target - smoothedLevel) * 0.28

        let value = smoothedLevel
        DispatchQueue.main.async { [onLevel] in onLevel?(value) }
    }

    /// Maps raw RMS onto 0...1 the way a meter should: on a decibel scale.
    ///
    /// Linear RMS is why normal speech barely moved the bars — conversational level sits
    /// around 0.02–0.05 RMS, so a linear scale leaves it stuck near the bottom while only
    /// shouting reaches the top. Human loudness is logarithmic, so map dBFS instead and
    /// lift the quiet end with a curve.
    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        // -50 dBFS ≈ a quiet room, -8 dBFS ≈ loud speech close to the mic.
        let clamped = min(max(db, -50), -8)
        let linear = (clamped + 50) / 42
        return pow(linear, 0.65)
    }

    /// Float32 → little-endian Int16, which is what `audio/pcm;rate=16000` means.
    private static func int16PCM(from buffer: AVAudioPCMBuffer) -> Data {
        guard let channel = buffer.floatChannelData?[0] else { return Data() }
        let frames = Int(buffer.frameLength)

        var samples = [Int16]()
        samples.reserveCapacity(frames)
        for i in 0..<frames {
            let clamped = max(-1, min(1, channel[i]))
            samples.append(Int16(clamped * 32767))
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        return (sum / Float(frames)).squareRoot()
    }

    static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
