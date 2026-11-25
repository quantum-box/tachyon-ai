import CommonCrypto
import Foundation
import Security
import SQLite3

/// Reads the cookies of a local Google Chrome profile, so sites the user is signed
/// in to in Chrome are signed in in the browser pane too.
///
/// Chrome encrypts cookie values with a key it keeps in the login keychain
/// ("Chrome Safe Storage"); reading that key makes macOS ask the user first.
enum ChromeCookies {
    struct Profile: Identifiable, Hashable {
        /// The profile's folder name, such as "Default" or "Profile 1".
        let id: String
        let name: String
    }

    /// One row of Chrome's `cookies` table, still encrypted.
    struct Row: Sendable {
        let host: String
        let name: String
        let path: String
        let value: String
        let encrypted: Data
        /// Microseconds since 1601-01-01; 0 for a session cookie.
        let expiresUTC: Int64
        let secure: Bool
        let httpOnly: Bool
        /// -1 unspecified, 0 none, 1 lax, 2 strict.
        let sameSite: Int
    }

    enum Failure: LocalizedError {
        case noProfiles
        case database(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noProfiles:
                return "Chrome のプロフィールが見つかりません。"
            case .database(let message):
                return "Chrome の Cookie を読めませんでした (\(message))。"
            case .keychain(errSecUserCanceled), .keychain(errSecAuthFailed):
                return "キーチェーンへのアクセスが許可されませんでした。"
            case .keychain(errSecItemNotFound):
                return "キーチェーンに Chrome の鍵 (Chrome Safe Storage) が見つかりません。"
            case .keychain(let status):
                return "キーチェーンから Chrome の鍵を読めませんでした (\(status))。"
            }
        }
    }

    /// Chrome's data folder in the real home folder (the app's sandbox has its own).
    /// The entitlements let the sandboxed app read it.
    static var defaultRoot: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    // MARK: - Profiles

    /// The profiles in `root` that have cookies, with the names Chrome shows.
    static func profiles(in root: URL) throws -> [Profile] {
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, info) in cache {
                names[folder] = (info as? [String: Any])?["name"] as? String
            }
        }
        // Reading the folder itself fails when the sandbox does not allow it.
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let profiles = folders
            .filter { cookieFile(in: root.appendingPathComponent($0)) != nil }
            .map { Profile(id: $0, name: names[$0] ?? $0) }
            .sorted { ($0.id == "Default" ? 0 : 1, $0.name) < ($1.id == "Default" ? 0 : 1, $1.name) }
        guard !profiles.isEmpty else { throw Failure.noProfiles }
        return profiles
    }

    static func cookieFile(in profile: URL) -> URL? {
        ["Cookies", "Network/Cookies"]
            .map { profile.appendingPathComponent($0) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    // MARK: - Reading

    /// Every cookie of the profile, and whether values carry Chrome's host hash
    /// (database version 24 and later put a SHA-256 of the host before the value).
    static func rows(in profile: URL) throws -> (rows: [Row], hasHostHash: Bool) {
        guard let file = cookieFile(in: profile) else { throw Failure.noProfiles }
        // `immutable` reads the file as it is, without the lock Chrome holds while running.
        let uri = file.absoluteString + "?immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open"
            sqlite3_close(db)
            throw Failure.database(message)
        }
        defer { sqlite3_close(db) }

        var version = 0
        try query(db, "SELECT value FROM meta WHERE key = 'version'") { row in
            version = Int(text(row, 0)) ?? 0
        }

        var rows: [Row] = []
        try query(db, """
            SELECT host_key, name, path, value, encrypted_value, expires_utc, is_secure, is_httponly, samesite
            FROM cookies
            """) { row in
            rows.append(Row(
                host: text(row, 0), name: text(row, 1), path: text(row, 2), value: text(row, 3),
                encrypted: blob(row, 4), expiresUTC: sqlite3_column_int64(row, 5),
                secure: sqlite3_column_int(row, 6) != 0, httpOnly: sqlite3_column_int(row, 7) != 0,
                sameSite: Int(sqlite3_column_int(row, 8))))
        }
        return (rows, version >= 24)
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ each: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { each(statement) }
    }

    private static func text(_ row: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ row: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }

    // MARK: - Decrypting

    /// The AES key Chrome derives from its keychain password. Blocks while macOS asks the user.
    static func key() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else { throw Failure.keychain(status) }
        return deriveKey(password: password)
    }

    static func deriveKey(password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        password.withUnsafeBytes { raw in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                raw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                &key, key.count)
        }
        return Data(key)
    }

    /// A cookie value: `v10`/`v11` values are AES-128-CBC with an IV of 16 spaces.
    static func decrypt(_ data: Data, key: Data, hasHostHash: Bool) -> String? {
        guard data.count > 3, data.prefix(3) == Data("v10".utf8) || data.prefix(3) == Data("v11".utf8) else {
            return nil
        }
        let cipher = data.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var length = 0
        let status = key.withUnsafeBytes { keyBytes in
            cipher.withUnsafeBytes { cipherBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, iv,
                    cipherBytes.baseAddress, cipher.count,
                    &plain, plain.count, &length)
            }
        }
        guard status == kCCSuccess else { return nil }
        var value = plain.prefix(length)
        if hasHostHash {
            guard value.count >= 32 else { return nil }
            value = value.dropFirst(32)
        }
        return String(bytes: value, encoding: .utf8)
    }

    /// The cookies, decrypted, leaving out expired ones and any that fail to decrypt.
    static func cookies(_ rows: [Row], key: Data, hasHostHash: Bool) -> [HTTPCookie] {
        let now = Date()
        return rows.compactMap { row in
            let value = row.encrypted.isEmpty
                ? row.value : decrypt(row.encrypted, key: key, hasHostHash: hasHostHash)
            guard let value else { return nil }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: row.host,
                .path: row.path.isEmpty ? "/" : row.path,
                .name: row.name,
                .value: value,
            ]
            if row.expiresUTC > 0 {
                // Chrome counts from 1601; Unix time from 1970.
                let expires = Date(timeIntervalSince1970: Double(row.expiresUTC) / 1_000_000 - 11_644_473_600)
                guard expires > now else { return nil }
                properties[.expires] = expires
            }
            if row.secure { properties[.secure] = "TRUE" }
            if row.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            switch row.sameSite {
            case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            default: break
            }
            return HTTPCookie(properties: properties)
        }
    }
}
