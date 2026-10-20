import SwiftUI
import VisionKit

struct PairView: View {
    @EnvironmentObject var cindy: Cindy
    @State private var link = ""
    @State private var error = ""
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Cindy").font(.largeTitle.bold())
            Text("Connect to Cindy on your PC. Right-click her tray icon, choose \"Pair a phone…\", then scan the code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                scanning = true
            } label: {
                Label("Scan pairing code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!DataScannerViewController.isSupported)
            Text("You can also scan it with the Camera app.").font(.footnote).foregroundStyle(.secondary)
            TextField("…or paste the pairing link", text: $link)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Pair") {
                if let p = Pairing.parse(link) { cindy.pair(p) } else { error = "That isn't a valid pairing link." }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            Spacer()
        }
        .padding(24)
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                if let p = Pairing.parse(code) { cindy.pair(p) } else { error = "That QR code isn't a pairing code from your PC." }
            }
            .ignoresSafeArea()
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var cindy: Cindy
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if cindy.messages.isEmpty {
                                Text(cindy.handsFree ? "Say \"Hey Cindy\" anytime, even with the app in the background."
                                                     : "Tap the mic and talk, or turn on \"Hey Cindy\".")
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 48)
                            }
                            ForEach(cindy.messages) { Bubble(msg: $0).id($0.id) }
                        }
                        .padding()
                    }
                    .onChange(of: cindy.messages.count) {
                        if let last = cindy.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                MicButton()
                HStack {
                    TextField("Type instead…", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendTyped)
                    Button(action: sendTyped) { Image(systemName: "paperplane.fill") }
                }
                .padding(12)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Cindy").font(.headline)
                        StatusLine()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Hey Cindy (hands-free)", isOn: Binding(get: { cindy.handsFree }, set: { cindy.enableHandsFree($0) }))
                        Button("Unpair this iPhone", role: .destructive) { cindy.unpair() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sendTyped() {
        cindy.send(text: typed)
        typed = ""
    }
}

private struct StatusLine: View {
    @EnvironmentObject var cindy: Cindy
    var body: some View {
        let (color, text): (Color, String) = switch cindy.status {
        case .connected: (.green, "Connected to \(cindy.statusDetail)")
        case .connecting: (.orange, "Connecting…")
        default: (.red, "Offline")
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MicButton: View {
    @EnvironmentObject var cindy: Cindy
    @State private var pulse = false

    var body: some View {
        let listening = cindy.phase == "listening"
        VStack(spacing: 4) {
            Button { cindy.tapMic() } label: {
                Image(systemName: listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(Circle().fill(listening ? Color.red : Color.accentColor))
                    .scaleEffect(listening && pulse ? 1.12 : 1)
            }
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever()) { pulse = true } }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var caption: String {
        if cindy.status != .connected { return cindy.statusDetail }
        switch cindy.phase {
        case "listening": return "Listening…"
        case "thinking": return "Thinking…"
        case "waiting": return "Say \"Hey Cindy\""
        default: return ""
        }
    }
}

private struct Bubble: View {
    @ObservedObject var msg: Msg

    var body: some View {
        if msg.role == .cindy && msg.text.isEmpty && msg.tools.isEmpty {
            EmptyView()
        } else {
            HStack {
                if msg.role == .you { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    if msg.role == .alert {
                        Label("Security alert", systemImage: "exclamationmark.triangle.fill").font(.caption.bold())
                    }
                    if !msg.tools.isEmpty {
                        Text(msg.tools.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !msg.text.isEmpty { Text(msg.text.trimmingCharacters(in: .whitespaces)) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 18).fill(background))
                if msg.role != .you { Spacer(minLength: 40) }
            }
        }
    }

    private var background: Color {
        switch msg.role {
        case .you: Color.accentColor.opacity(0.25)
        case .cindy: Color(.secondarySystemBackground)
        case .alert: Color.red.opacity(0.2)
        case .system: Color.clear
        }
    }
}

/// QR scanner (VisionKit); hands back the first QR code's text.
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        if !vc.isScanning { try? vc.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                if let v = b.payloadStringValue, !done {
                    done = true
                    onCode(v)
                }
            }
        }
    }
}
