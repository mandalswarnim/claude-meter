import Foundation

/// Reads the OAuth access token that Claude Code itself stores.
/// Primary source: the "Claude Code-credentials" item in the login Keychain,
/// read via /usr/bin/security (which is on that item's access list, so no
/// password prompt). Fallback: ~/.claude/.credentials.json.
/// This app never writes or refreshes credentials — Claude Code owns them.
enum Credentials {
    struct Token {
        var accessToken: String
        var expiresAt: Date?
    }

    static func token() -> Token? {
        let keychain = fromKeychain()
        let file = fromFile()
        // Prefer whichever expires later (Claude Code rotates the Keychain copy).
        switch (keychain, file) {
        case let (k?, f?):
            return (k.expiresAt ?? .distantPast) >= (f.expiresAt ?? .distantPast) ? k : f
        case let (k?, nil): return k
        case let (nil, f?): return f
        default: return nil
        }
    }

    private static func fromKeychain() -> Token? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return parse(data)
    }

    private static func fromFile() -> Token? {
        let url = Store.realHome.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    private static func parse(_ data: Data) -> Token? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        return Token(accessToken: access, expiresAt: expires)
    }
}
