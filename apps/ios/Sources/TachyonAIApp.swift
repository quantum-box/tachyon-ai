import SwiftUI

@main
struct TachyonAIApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView(app: app, account: app.account)
        }
    }
}

/// Everything the iOS app shares between screens.
@MainActor
final class AppState: ObservableObject {
    let account: Account
    let api: TachyonAPI
    let chat: ChatModel
    let dictation: Dictation

    init() {
        let auth = AuthService()
        let api = TachyonAPI(auth: auth)
        let chat = ChatModel(api: api)
        let account = Account(auth: auth)
        self.account = account
        self.api = api
        self.chat = chat
        dictation = Dictation(auth: auth, api: api)
        account.onTenantChange = { [weak chat] in
            // History and models belong to the previous tenant.
            chat?.startNewChat()
            Task {
                await chat?.refreshSessions()
                await chat?.refreshModels()
            }
        }
        account.onChange = { [weak account, weak chat] in
            // The conversation on screen belonged to the account that just signed out.
            if account?.isLoggedIn == false {
                chat?.startNewChat()
            }
        }
    }
}

private struct RootView: View {
    let app: AppState
    @ObservedObject var account: Account

    var body: some View {
        if account.isLoggedIn {
            ChatScreen(app: app, model: app.chat, dictation: app.dictation)
        } else {
            LoginView(account: account)
                .background { AppBackdrop() }
        }
    }
}

/// Soft colour behind the glass, so there is something for it to refract.
struct AppBackdrop: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [.indigo.opacity(0.28), .purple.opacity(0.16), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .ignoresSafeArea()
    }
}
