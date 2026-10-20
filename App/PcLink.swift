import CryptoKit
import Foundation

protocol PcLinkDelegate: AnyObject {
    func linkStatus(_ status: PcLink.Status, _ detail: String)
    func linkMessage(_ msg: [String: Any])
}

/// Encrypted WebSocket to Cindy on the PC. The PC's certificate is self-signed, so instead of normal
/// CA checks we accept exactly one certificate: the one whose SHA-256 came in the pairing QR code.
/// Everything is delivered on the main queue.
final class PcLink: NSObject, URLSessionDelegate {
    enum Status { case connecting, connected, offline, revoked }

    private let pairing: Pairing
    private weak var delegate: PcLinkDelegate?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var hostIndex = 0
    private var failures = 0
    private var running = false

    init(pairing: Pairing, delegate: PcLinkDelegate) {
        self.pairing = pairing
        self.delegate = delegate
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func start() {
        running = true
        open()
    }

    func stop() {
        running = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    @discardableResult
    func send(text: String) -> Bool {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: ["type": "say", "text": text]),
              let s = String(data: data, encoding: .utf8) else { return false }
        task.send(.string(s)) { _ in }
        return true
    }

    /// Recorded speech (16 kHz mono 16-bit). checkWake asks the PC to confirm "hey cindy" was really said.
    @discardableResult
    func send(audio pcm: Data, checkWake: Bool) -> Bool {
        guard let task else { return false }
        var frame = Data([checkWake ? 1 : 0])
        frame.append(pcm)
        task.send(.data(frame)) { _ in }
        return true
    }

    private func open() {
        let host = pairing.hosts[hostIndex % pairing.hosts.count]
        delegate?.linkStatus(.connecting, host)
        guard let url = URL(string: "wss://\(host):\(pairing.port)/") else { return }
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 4 * 1024 * 1024
        task = t
        t.resume()
        if let hello = try? JSONSerialization.data(withJSONObject: ["type": "hello", "token": pairing.token]),
           let s = String(data: hello, encoding: .utf8) {
            t.send(.string(s)) { [weak self] err in if err != nil { self?.failed(t) } }
        }
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, t === self.task else { return }
                switch result {
                case .failure:
                    self.failed(t)
                case .success(let message):
                    if case .string(let s) = message, let d = s.data(using: .utf8),
                       let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                        switch o["type"] as? String {
                        case "ready":
                            self.failures = 0
                            self.delegate?.linkStatus(.connected, o["pc"] as? String ?? self.pairing.pcName)
                        case "unpaired":
                            self.running = false
                            self.task = nil
                            self.delegate?.linkStatus(.revoked, "This iPhone was unpaired on the PC")
                            return
                        default:
                            self.delegate?.linkMessage(o)
                        }
                    }
                    self.receive(t)
                }
            }
        }
    }

    private func failed(_ t: URLSessionWebSocketTask) {
        guard running, t === task else { return }
        task = nil
        failures += 1
        hostIndex += 1
        delegate?.linkStatus(.offline, "Can't reach \(pairing.pcName). Is Cindy running on it, and are you on the same network?")
        // try every known address quickly, then back off up to 30 s
        let delay = failures < pairing.hosts.count ? 0.3 : min(30, pow(2, Double(min(failures, 5))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.task == nil else { return }
            self.open()
        }
    }

    // MARK: certificate pinning

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if hex == pairing.fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil) // not our PC
        }
    }
}
