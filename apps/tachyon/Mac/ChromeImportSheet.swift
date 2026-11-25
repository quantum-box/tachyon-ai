import SwiftUI
import WebKit

/// Copies every cookie of one Chrome profile into the browser pane, so the sites
/// signed in there are signed in here too.
struct ChromeImportSheet: View {
    /// Called after cookies were added, to reload the open page.
    let onImported: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [ChromeCookies.Profile] = []
    @State private var profile: ChromeCookies.Profile?
    @State private var isWorking = false
    @State private var message: String?
    @State private var failure: String?
    /// Cookies imported, once the import has finished.
    @State private var imported: Int?

    var body: some View {
        if let imported {
            done(imported)
        } else {
            form
        }
    }

    private func done(_ count: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: count)
            Text("読み込みました").font(.title3.weight(.semibold))
            Text("「\(profile?.name ?? "Chrome")」の Cookie を \(count) 件読み込みました。右のブラウザでもログインした状態になっています。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 420)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chrome からログイン状態を読み込む").font(.headline)
            Text("選んだプロフィールの Cookie をすべてコピーし、右のブラウザでもログインした状態にします。パスワードは読み込みません。読み込むときに、macOS が「Chrome Safe Storage」へのアクセスを確認します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !profiles.isEmpty {
                Picker("プロフィール", selection: $profile) {
                    ForEach(profiles) { Text($0.name).tag(Optional($0)) }
                }
            }

            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            } else if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("読み込む", action: importProfile)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile == nil || isWorking)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            do {
                profiles = try ChromeCookies.profiles(in: ChromeCookies.defaultRoot)
                profile = profiles.first
            } catch {
                failure = (error as? ChromeCookies.Failure)?.errorDescription
                    ?? "Chrome のデータが見つかりません。Google Chrome は入っていますか？"
            }
        }
    }

    private func importProfile() {
        guard let profile else { return }
        let folder = ChromeCookies.defaultRoot.appendingPathComponent(profile.id)
        isWorking = true
        failure = nil
        message = "キーチェーンの確認を待っています…"
        Task {
            do {
                // Asking for the key shows a macOS prompt and blocks until the user answers.
                let cookies = try await Task.detached {
                    let (rows, hasHostHash) = try ChromeCookies.rows(in: folder)
                    let key = try ChromeCookies.key()
                    return ChromeCookies.cookies(rows, key: key, hasHostHash: hasHostHash)
                }.value
                let store = WKWebsiteDataStore.default().httpCookieStore
                for cookie in cookies {
                    await store.setCookie(cookie)
                }
                message = nil
                withAnimation { imported = cookies.count }
                onImported()
            } catch {
                message = nil
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }
}
