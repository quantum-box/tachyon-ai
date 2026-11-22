import SwiftUI

@main
struct AIThinkinApp: App {
    @StateObject private var store = ChatStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatScreen(store: store)
                .onChange(of: scenePhase, initial: true) {
                    if scenePhase == .active {
                        store.refreshAvailability()
                    }
                }
        }
    }
}

/// Soft colour behind the glass, so there is something for it to refract.
struct AppBackdrop: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [.teal.opacity(0.28), .green.opacity(0.14), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}
