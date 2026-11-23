import SwiftUI

/// Who is signed in, and the sign-in flow, as something views can observe.
@MainActor
final class Account: ObservableObject {
    let auth: AuthService

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var isLoggingIn = false
    @Published var loginError: String?

    /// The tenants the signed-in user belongs to.
    @Published private(set) var tenants: [Tenant] = []
    @Published private(set) var tenantID: String?

    /// Called after signing in or out.
    var onChange: (() -> Void)?
    /// Called after switching to another tenant: everything on screen belongs to the old one.
    var onTenantChange: (() -> Void)?

    /// False when config.json pins the tenant.
    var canChooseTenant: Bool { !auth.tenantIsPinned }

    func refreshTenants() async {
        tenantID = auth.tenantID
        guard isLoggedIn, let list = try? await auth.tenants() else { return }
        tenants = list
    }

    func selectTenant(_ id: String) {
        guard id != tenantID, canChooseTenant else { return }
        auth.selectTenant(id)
        tenantID = auth.tenantID
        onTenantChange?()
    }

    init(auth: AuthService) {
        self.auth = auth
        isLoggedIn = auth.isLoggedIn
        tenantID = auth.tenantID
    }

    /// Opens the sign-in window. Only ever started by the user pressing a button.
    func login() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        loginError = nil
        Task {
            do {
                try await auth.login()
            } catch AuthService.AuthError.cancelled {
                // The user closed the sign-in window; nothing to report.
            } catch {
                loginError = error.localizedDescription
            }
            isLoggingIn = false
            isLoggedIn = auth.isLoggedIn
            tenantID = auth.tenantID
            onChange?()
            await refreshTenants()
        }
    }

    func logout() {
        auth.logout()
        isLoggedIn = false
        tenants = []
        tenantID = nil
        onChange?()
    }
}

/// The screen shown while signed out: what the app is, and a button to sign in.
struct LoginView: View {
    @ObservedObject var account: Account

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 108, height: 108)
                .glassEffect(.regular, in: .circle)

            VStack(spacing: 8) {
                Text("Tachyon AI").font(.largeTitle.weight(.bold))
                Text("Tachyon のエージェントと会話できます。")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let error = account.loginError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: account.login) {
                ZStack {
                    // Kept in the layout while hidden so the button does not change size.
                    Text("ログイン").fontWeight(.semibold).opacity(account.isLoggingIn ? 0 : 1)
                    if account.isLoggingIn {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: 320, minHeight: 28)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(account.isLoggingIn)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
