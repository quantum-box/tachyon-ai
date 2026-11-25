import AuthenticationServices
import Security

/// Passkeys in the browser pane. WebKit hands `navigator.credentials` to
/// AuthenticationServices in this process, which serves any site only to apps holding
/// Apple's browser passkey entitlement; without it the pane's passkey requests fail.
@MainActor
enum Passkeys {
    static let entitlement = "com.apple.developer.web-browser.public-key-credential"

    /// Whether this build was signed with the entitlement (the Xcode build, once Apple
    /// has granted it). `scripts/build-app.sh` builds are not.
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        else { return false }
        return (value as? Bool) ?? false
    }()

    private static var asked = false

    /// Asks once for access to the passkeys of the keychain and of password managers
    /// such as 1Password (System Settings > Privacy & Security > Passkey Access for Web
    /// Browsers). Called when the pane opens its first web page.
    static func requestAccessIfNeeded() {
        guard isEntitled, !asked else { return }
        asked = true
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        guard manager.authorizationStateForPlatformCredentials == .notDetermined else { return }
        manager.requestAuthorizationForPublicKeyCredentials { _ in }
    }
}
