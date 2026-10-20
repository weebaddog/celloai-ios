import AVFoundation
import Foundation
import Speech

/// The iPhone's ears. One AVAudioEngine tap with three modes:
///  - wake: Apple's on-device recognizer watches for "Hey Cindy" (rough check; the PC confirms it)
///  - command: records what you say until you pause, for Whisper on your PC to transcribe
///  - off: mic open but ignored (while Cindy talks, so she doesn't hear herself)
/// Callbacks arrive on the main queue.
final class Ears {
    enum Mode { case off, wake, command }

    var onWake: (() -> Void)?
    var onCommand: ((Data, Bool) -> Void)?
    var onNothing: (() -> Void)?

    private let q = DispatchQueue(label: "cindy.ears")
    private let engine = AVAudioEngine()
    private let chimePlayer = AVAudioPlayerNode()
    private let chimeFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var converter: AVAudioConverter?
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date()
    private static let wakeRx = try! NSRegularExpression(pattern: "\\bhey\\W+(cindy|cindi|sindy|cyndi|cyndy)\\b", options: .caseInsensitive)

    // touched only on q
    private var mode: Mode = .off
    private var pre: [Data] = []          // last ~1.5 s, so "hey cindy" itself goes to the PC for checking
    private var cmd = Data()
    private var viaWake = false
    private var startTimeout = 6.0
    private var heardSpeech = false
    private var silent = 0.0
    private var elapsed = 0.0
    private var noise = 300.0

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: pcmFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            self?.q.async { self?.process(buf) }
        }
        if chimePlayer.engine == nil {
            engine.attach(chimePlayer)
            engine.connect(chimePlayer, to: engine.mainMixerNode, format: chimeFormat)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        q.async { self.mode = .off; self.endWakeTask() }
    }

    func listenForWake() { q.async { self.enter(.wake) } }
    func pause() { q.async { self.enter(.off) } }

    /// Record one request without the wake word (mic button, or follow-up after a reply).
    func listenForCommand(timeout: Double) {
        q.async {
            self.viaWake = false
            self.startTimeout = timeout
            self.enter(.command)
        }
    }

    /// Two soft rising notes: "I'm listening".
    func chime() {
        guard engine.isRunning else { return }
        let format = chimeFormat
        let sr = format.sampleRate
        let n = AVAudioFrameCount(sr * 0.18)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
        buf.frameLength = n
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(n) {
                let half = Int(n) / 2
                let t = Double(i % half) / sr
                let f = i < half ? 784.0 : 1175.0
                p[i] = Float(0.25 * sin(2 * .pi * f * t) * min(1, t / 0.01) * exp(-t * 18))
            }
        }
        chimePlayer.scheduleBuffer(buf, completionHandler: nil)
        if !chimePlayer.isPlaying { chimePlayer.play() }
    }

    // MARK: audio thread (q)

    private func enter(_ m: Mode) {
        if m == .command {
            cmd = Data()
            if viaWake { pre.forEach { cmd.append($0) } }
            heardSpeech = false; silent = 0; elapsed = 0
        }
        if m == .wake { beginWakeTask() } else { endWakeTask() }
        mode = m
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let chunk = convert(buf) else { return }
        let seconds = Double(chunk.count / 2) / 16000
        let rms: Double = chunk.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            guard !s.isEmpty else { return 0 }
            var sum = 0.0
            for v in s { sum += Double(v) * Double(v) }
            return (sum / Double(s.count)).squareRoot()
        }
        let voiced = rms > max(noise * 3, 500)

        switch mode {
        case .off:
            break
        case .wake:
            if !voiced { noise = 0.98 * noise + 0.02 * rms }
            pre.append(chunk)
            while pre.reduce(0, { $0 + $1.count }) > 48_000 { pre.removeFirst() }
            request?.append(buf)
            if Date().timeIntervalSince(taskStarted) > 50 { beginWakeTask() } // recognizer sessions are time-limited
        case .command:
            cmd.append(chunk)
            elapsed += seconds
            if voiced { heardSpeech = true; silent = 0 } else { silent += seconds }
            let finished = (heardSpeech && silent >= 0.8) || elapsed >= 15 || (!heardSpeech && elapsed >= startTimeout)
            if finished {
                let pcm = cmd, wasWake = viaWake, spoke = heardSpeech
                mode = .off
                pre.removeAll()
                DispatchQueue.main.async {
                    // after a wake word we always send (the PC checks it); otherwise only real speech
                    if spoke || wasWake { self.onCommand?(pcm, wasWake) } else { self.onNothing?() }
                }
            }
        }
    }

    private func convert(_ buf: AVAudioPCMBuffer) -> Data? {
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }

    private func beginWakeTask() {
        endWakeTask()
        guard let r = recognizer, r.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true } // never sent to Apple
        req.contextualStrings = ["Hey Cindy", "Cindy"]
        request = req
        taskStarted = Date()
        task = r.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.q.async {
                guard self.mode == .wake, req === self.request else { return }
                if let text = result?.bestTranscription.formattedString,
                   Ears.wakeRx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    self.viaWake = true
                    self.startTimeout = 4
                    self.enter(.command)
                    DispatchQueue.main.async { self.onWake?() }
                } else if error != nil || result?.isFinal == true {
                    // session ended (silence timeout etc.): start a fresh one shortly
                    self.q.asyncAfter(deadline: .now() + 0.3) { if self.mode == .wake { self.beginWakeTask() } }
                }
            }
        }
    }

    private func endWakeTask() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}

/// Text -> speech, fed in streamed chunks and spoken sentence by sentence so replies start quickly.
final class Mouth: NSObject, AVSpeechSynthesizerDelegate {
    var onIdle: (() -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var buffer = ""
    private var pending = 0
    private lazy var voice: AVSpeechSynthesisVoice? = {
        // most natural installed English voice, preferring a female one (Cindy)
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { a, b in
                (a.language == "en-US" ? 1 : 0, a.quality.rawValue, a.gender == .female ? 1 : 0)
                    < (b.language == "en-US" ? 1 : 0, b.quality.rawValue, b.gender == .female ? 1 : 0)
            }
    }()

    var speaking: Bool { pending > 0 }

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    func feed(_ chunk: String) {
        buffer += chunk
        while let r = buffer.range(of: "[.!?…](\\s+)|\\n+", options: .regularExpression) {
            say(String(buffer[..<r.upperBound]))
            buffer = String(buffer[r.upperBound...])
        }
    }

    func flush() {
        say(buffer)
        buffer = ""
    }

    func say(_ text: String) {
        let clean = text.replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = voice
        pending += 1
        synth.speak(u)
    }

    func stop() {
        buffer = ""
        pending = 0
        synth.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finished() }

    private func finished() {
        DispatchQueue.main.async {
            guard self.pending > 0 else { return }
            self.pending -= 1
            if self.pending == 0 { self.onIdle?() }
        }
    }
}
