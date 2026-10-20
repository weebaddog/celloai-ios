import AVFoundation
import Foundation
import Speech
import UIKit
import UserNotifications

enum Role { case you, cindy, alert, system }

final class Msg: ObservableObject, Identifiable {
    let id = UUID()
    let role: Role
    @Published var text: String
    @Published var tools: [String] = []
    init(_ role: Role, _ text: String = "") { self.role = role; self.text = text }
}

/// Cindy on the iPhone. Ears -> PC (Whisper + Claude) -> mouth. Used from the main thread only.
final class Cindy: ObservableObject, PcLinkDelegate {
    static let shared = Cindy()

    @Published var messages: [Msg] = []
    @Published var paired = false
    @Published var status: PcLink.Status = .offline
    @Published var statusDetail = ""
    @Published var phase = "idle"   // idle | waiting | listening | thinking | speaking
    @Published var handsFree = UserDefaults.standard.bool(forKey: "handsFree")
    @Published var pendingPair: Pairing?   // from a celloai:// link; needs the user's OK

    private var link: PcLink?
    private let ears = Ears()
    private let mouth = Mouth()
    private var current: Msg?
    private var turnActive = false
    private var followUp = false
    private var wantTalk = false
    private var inBackground = false

    private init() {
        ears.onWake = { [weak self] in self?.onWake() }
        ears.onCommand = { [weak self] pcm, viaWake in self?.onCommand(pcm, viaWake: viaWake) }
        ears.onNothing = { [weak self] in self?.idle() }
        mouth.onIdle = { [weak self] in self?.onDoneSpeaking() }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            // a phone call or Siri took the mic; pick up again afterwards
            if let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .ended {
                self?.ears.stop()
                self?.idle()
            }
        }
        if let p = Pairing.load() {
            paired = true
            connect(p)
        }
    }

    // MARK: pairing

    func pair(_ p: Pairing) {
        p.save()
        paired = true
        messages.removeAll()
        connect(p)
    }

    func unpair() {
        enableHandsFree(false)
        link?.stop()
        link = nil
        Pairing.clear()
        paired = false
        messages.removeAll()
    }

    private func connect(_ p: Pairing) {
        link?.stop()
        link = PcLink(pairing: p, delegate: self)
        link?.start()
    }

    func linkStatus(_ status: PcLink.Status, _ detail: String) {
        self.status = status
        statusDetail = detail
        if status == .connected {
            if wantTalk { wantTalk = false; tapMic() } else { idle() }
        }
        if status == .revoked {
            messages.append(Msg(.system, "\(detail). Pair again to reconnect."))
            unpair()
        }
    }

    // MARK: hands-free

    func enableHandsFree(_ on: Bool) {
        handsFree = on
        UserDefaults.standard.set(on, forKey: "handsFree")
        if on {
            SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self.idle() } }
        }
        idle()
    }

    func setBackground(_ bg: Bool) {
        inBackground = bg
        if !bg { idle() }
        // going to the background: keep the engine running only if hands-free is on (handled by idle)
        else if !handsFree { ears.pause(); ears.stop(); phase = "idle" }
    }

    /// Settle into the right resting state: wait for "Hey Cindy", or release the mic.
    private func idle() {
        if turnActive || mouth.speaking { return }
        let canHear = AVAudioApplication.shared.recordPermission == .granted && status == .connected
        if canHear && handsFree && SFSpeechRecognizer.authorizationStatus() == .authorized {
            do {
                try ears.start()
                ears.listenForWake()
                phase = "waiting"
            } catch {
                phase = "idle"
            }
        } else {
            ears.pause()
            if !handsFree { ears.stop() }
            phase = "idle"
        }
    }

    // MARK: talking

    /// Mic button / "Hey Siri, talk to Cindy": talk now, no wake word. Tapping while she talks interrupts.
    func tapMic() {
        guard status == .connected else { wantTalk = true; return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                guard ok else {
                    self.messages.append(Msg(.system, "Cindy needs the microphone. Allow it in Settings."))
                    return
                }
                self.mouth.stop()
                do { try self.ears.start() } catch { return }
                self.ears.chime()
                self.ears.listenForCommand(timeout: 6)
                self.phase = "listening"
            }
        }
    }

    func send(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard status == .connected, link?.send(text: t) == true else { return offline() }
        startTurn(t)
    }

    private func onWake() {
        ears.chime() // instant "I heard you", like Siri
        phase = "listening"
    }

    private func onCommand(_ pcm: Data, viaWake: Bool) {
        guard status == .connected, link?.send(audio: pcm, checkWake: viaWake) == true else { return offline() }
        ears.pause()
        phase = "thinking"
        followUp = viaWake
    }

    private func startTurn(_ text: String) {
        messages.append(Msg(.you, text))
        let m = Msg(.cindy)
        messages.append(m)
        current = m
        turnActive = true
        phase = "thinking"
    }

    private func offline() {
        messages.append(Msg(.system, "Can't reach your PC right now."))
        mouth.say("I can't reach your PC right now.")
        idle()
    }

    func linkMessage(_ msg: [String: Any]) {
        let text = msg["text"] as? String ?? ""
        switch msg["type"] as? String {
        case "ignored":
            idle() // the PC's Whisper says nobody said "Hey Cindy"
        case "heard":
            if !text.isEmpty { startTurn(text) }
            else if followUp { // just "Hey Cindy": now listen for the request
                ears.listenForCommand(timeout: 6)
                phase = "listening"
            } else { idle() }
            followUp = false
        case "text":
            current?.text += text
            mouth.feed(text)
            phase = "speaking"
        case "break":
            mouth.flush()
        case "tool":
            current?.tools.append(msg["name"] as? String ?? "")
        case "error":
            current?.text += " " + text
            mouth.say(text)
        case "done":
            turnActive = false
            mouth.flush()
            followUp = true
            if !mouth.speaking { onDoneSpeaking() }
        case "alert":
            messages.append(Msg(.alert, text))
            notify(text)
            mouth.say("Heads up from your PC. \(text).")
        default:
            break
        }
    }

    private func onDoneSpeaking() {
        if turnActive { return }
        if followUp && (!inBackground || handsFree) {
            followUp = false
            ears.listenForCommand(timeout: 8) // keep listening briefly, like a person would
            phase = "listening"
        } else {
            idle()
        }
    }

    private func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "Cindy: PC alert"
        c.body = text
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
