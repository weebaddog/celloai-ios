import AppIntents
import SwiftUI
import UserNotifications

@main
struct CindyApp: App {
    @StateObject private var cindy = Cindy.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if cindy.paired { ChatView() } else { PairView() }
            }
            .environmentObject(cindy)
            .onOpenURL { url in
                // a celloai://pair link (e.g. the PC's QR scanned with the Camera app); ask before trusting it
                if let p = Pairing.parse(url.absoluteString) { cindy.pendingPair = p }
            }
            .alert("Pair with \(cindy.pendingPair?.pcName ?? "this PC")?",
                   isPresented: Binding(get: { cindy.pendingPair != nil }, set: { if !$0 { cindy.pendingPair = nil } })) {
                Button("Pair") { if let p = cindy.pendingPair { cindy.pair(p) }; cindy.pendingPair = nil }
                Button("Cancel", role: .cancel) { cindy.pendingPair = nil }
            } message: {
                Text("Only do this if you just showed a pairing code on your own PC.")
            }
            .task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }
        .onChange(of: scenePhase) { _, phase in
            cindy.setBackground(phase == .background)
        }
    }
}

/// "Hey Siri, talk to Cindy" opens the app already listening.
struct TalkToCindy: AppIntent {
    static var title: LocalizedStringResource = "Talk to Cindy"
    static var description = IntentDescription("Start talking to Cindy.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Cindy.shared.tapMic()
        return .result()
    }
}

struct CindyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToCindy(),
                    phrases: ["Talk to \(.applicationName)", "Ask \(.applicationName)", "Hey \(.applicationName)"],
                    shortTitle: "Talk to Cindy",
                    systemImageName: "waveform")
    }
}
