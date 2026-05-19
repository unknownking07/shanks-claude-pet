import Foundation
import CommonCrypto
import SQLite3
import Security

/// Reads the claude.ai `sessionKey` cookie directly from a Chromium-based browser
/// (Chrome, Brave, Arc, Edge) on macOS, decrypting it with the key stored in the
/// user's Keychain. Avoids the manual DevTools-copy-paste step.
///
/// Each Chromium browser:
///  - Stores cookies in a SQLite DB under `~/Library/Application Support/<browser>/Default/Cookies`
///  - Encrypts each cookie value with AES-128-CBC, key = PBKDF2-HMAC-SHA1 over a
///    password kept in the user's login Keychain (service "<Browser> Safe Storage")
///  - Prefixes the encrypted blob with "v10" or "v11"
///
/// macOS will prompt for Keychain access on first read; user clicks "Always Allow".
enum BrowserCookieReader {

    enum BrowserKind: String, CaseIterable {
        case chrome = "Chrome"
        case brave = "Brave"
        case arc = "Arc"
        case edge = "Edge"

        var cookieDB: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .chrome:
                return home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies")
            case .brave:
                return home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies")
            case .arc:
                return home.appendingPathComponent("Library/Application Support/Arc/User Data/Default/Cookies")
            case .edge:
                return home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default/Cookies")
            }
        }

        var keychainService: String { "\(rawValue) Safe Storage" }
        var keychainAccount: String { rawValue }
    }

    /// CHEAP poll: does any installed Chromium browser have a claude.ai sessionKey row
    /// in its cookie DB? This only opens SQLite — it does NOT touch the Keychain, so
    /// it's safe to call on a timer without re-prompting the user.
    static func anyClaudeSessionPresent() -> BrowserKind? {
        for browser in BrowserKind.allCases {
            guard FileManager.default.fileExists(atPath: browser.cookieDB.path) else { continue }
            if (try? sessionRowExists(in: browser)) == true {
                return browser
            }
        }
        return nil
    }

    /// EXPENSIVE: actually decrypt the cookie. Triggers the Keychain prompt on first use.
    /// Call this ONCE after `anyClaudeSessionPresent()` returns non-nil.
    static func readClaudeSessionKey() -> (browser: BrowserKind, value: String)? {
        for browser in BrowserKind.allCases {
            guard FileManager.default.fileExists(atPath: browser.cookieDB.path) else { continue }
            do {
                let value = try readSessionKey(from: browser)
                NSLog("[BrowserCookieReader] Decrypted sessionKey from %@", browser.rawValue)
                return (browser, value)
            } catch {
                NSLog("[BrowserCookieReader] %@ failed: %@", browser.rawValue, error.localizedDescription)
                continue
            }
        }
        return nil
    }

    private static func sessionRowExists(in browser: BrowserKind) throws -> Bool {
        let src = browser.cookieDB
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shanks-poll-\(browser.rawValue.lowercased())-\(UUID().uuidString).db")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: src, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return false
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM cookies WHERE host_key LIKE '%claude.ai%' AND name = 'sessionKey' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW
    }

    static func readSessionKey(from browser: BrowserKind) throws -> String {
        // Copy DB to temp so we don't hit a write-locked file while the browser is running.
        let src = browser.cookieDB
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shanks-\(browser.rawValue.lowercased())-cookies-\(UUID().uuidString).db")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: src, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let encrypted = try fetchEncryptedCookie(dbPath: tmp.path, host: "claude.ai", name: "sessionKey")
        let kcPassword = try keychainPassword(service: browser.keychainService, account: browser.keychainAccount)
        return try decryptChromium(encrypted: encrypted, kcPassword: kcPassword)
    }

    // MARK: - SQLite

    private static func fetchEncryptedCookie(dbPath: String, host: String, name: String) throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ReaderError.sqliteOpen
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
        SELECT encrypted_value FROM cookies
        WHERE host_key LIKE ? AND name = ?
        ORDER BY expires_utc DESC
        LIMIT 1
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ReaderError.sqlitePrepare
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, "%\(host)%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw ReaderError.cookieNotFound
        }
        guard let blob = sqlite3_column_blob(stmt, 0) else {
            throw ReaderError.cookieNotFound
        }
        let length = Int(sqlite3_column_bytes(stmt, 0))
        guard length > 0 else { throw ReaderError.cookieNotFound }
        return Data(bytes: blob, count: length)
    }

    // MARK: - Keychain

    private static func keychainPassword(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw ReaderError.keychain(status: status)
        }
        guard let data = result as? Data, let pwd = String(data: data, encoding: .utf8) else {
            throw ReaderError.keychainDecode
        }
        return pwd
    }

    // MARK: - Decrypt

    private static func decryptChromium(encrypted: Data, kcPassword: String) throws -> String {
        guard encrypted.count > 3 else { throw ReaderError.cipherShort }
        // Strip 3-byte version prefix ("v10" or "v11")
        let ciphertext = encrypted.subdata(in: 3..<encrypted.count)

        let salt = Data("saltysalt".utf8)
        let iv = Data(repeating: 0x20, count: 16)  // 16 spaces
        let pwdData = Data(kcPassword.utf8)

        var derivedKey = Data(count: 16)
        let kdfStatus = derivedKey.withUnsafeMutableBytes { dkBuf -> Int32 in
            salt.withUnsafeBytes { saltBuf in
                pwdData.withUnsafeBytes { pwdBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pwdBuf.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        dkBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        16
                    )
                }
            }
        }
        guard kdfStatus == kCCSuccess else { throw ReaderError.pbkdf2 }

        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var bytesOut = 0
        let cryptStatus = plaintext.withUnsafeMutableBytes { ptBuf -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { ctBuf in
                iv.withUnsafeBytes { ivBuf in
                    derivedKey.withUnsafeBytes { keyBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, keyBuf.count,
                            ivBuf.baseAddress,
                            ctBuf.baseAddress, ctBuf.count,
                            ptBuf.baseAddress, ptBuf.count,
                            &bytesOut
                        )
                    }
                }
            }
        }
        guard cryptStatus == kCCSuccess else { throw ReaderError.aes(status: cryptStatus) }

        plaintext.count = bytesOut
        guard let str = String(data: plaintext, encoding: .utf8), !str.isEmpty else {
            throw ReaderError.notUTF8
        }
        return str
    }

    enum ReaderError: Error, LocalizedError {
        case sqliteOpen
        case sqlitePrepare
        case cookieNotFound
        case keychain(status: OSStatus)
        case keychainDecode
        case cipherShort
        case pbkdf2
        case aes(status: CCCryptorStatus)
        case notUTF8

        var errorDescription: String? {
            switch self {
            case .sqliteOpen: return "couldn't open browser cookie DB"
            case .sqlitePrepare: return "SQLite prepare failed"
            case .cookieNotFound: return "no claude.ai sessionKey cookie in this browser yet"
            case .keychain(let status): return "Keychain access denied (status \(status))"
            case .keychainDecode: return "Keychain returned unexpected data"
            case .cipherShort: return "encrypted cookie blob too short"
            case .pbkdf2: return "PBKDF2 key derivation failed"
            case .aes(let status): return "AES decrypt failed (status \(status))"
            case .notUTF8: return "decrypted bytes weren't UTF-8"
            }
        }
    }
}
