import Foundation

/// Invitation links of leaderboard groups: `https://tokenmaccer.app/join/<code>` (the website forwards to the app)
/// and `tokenmaccer://join/<code>` (opens the app directly). Plain values, no SwiftUI: the unit tests compile this file.
enum GroupInvite {
    /// Whether https://tokenmaccer.app/join/… answers (live since 02.11.2026: docs/join.html on Vercel hands the code
    /// to tokenmaccer://join/<code>). While false, shared invitations carry the tokenmaccer:// link as well.
    static let siteLive = true

    static let webBase = "https://tokenmaccer.app/join/"
    static let appBase = "tokenmaccer://join/"
    /// The server's code alphabet (no 0, o, 1, i, l) and length.
    static let alphabet = Set("23456789abcdefghjkmnpqrstuvwxyz")
    static let length = 10

    static func webLink(_ code: String) -> String { webBase + code }
    static func appLink(_ code: String) -> String { appBase + code }

    /// The code in what someone pasted or clicked: either link form (any case, with or without trailing slash,
    /// query or fragment, `www.` or not) or the bare code. nil when it is none of these.
    static func code(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        let prefixes = ["https://tokenmaccer.app/join/", "https://www.tokenmaccer.app/join/", "http://tokenmaccer.app/join/",
                        "tokenmaccer.app/join/", "tokenmaccer://join/"]
        var candidate = lower
        if let p = prefixes.first(where: { lower.hasPrefix($0) }) {
            candidate = String(lower.dropFirst(p.count))
        } else if lower.contains("/") || lower.contains(":") {
            return nil
        }
        candidate = candidate.filter { !$0.isWhitespace }
        guard candidate.count == length, candidate.allSatisfy(alphabet.contains) else { return nil }
        return candidate
    }

    /// The code of a URL the app was opened with (tokenmaccer://join/<code>), nil for any other URL.
    static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "tokenmaccer" || url.host?.lowercased().hasSuffix("tokenmaccer.app") == true
        else { return nil }
        return code(from: url.absoluteString)
    }

    /// The text that goes with a shared invitation.
    static func message(group: String, code: String) -> String {
        let web = webLink(code)
        guard !siteLive else {
            return String(localized: "Join my group “\(group)” on the TokenMaccer leaderboard for Claude Code: \(web)")
        }
        return String(localized: "Join my group “\(group)” on the TokenMaccer leaderboard for Claude Code: \(web)\nWith TokenMaccer installed, this link opens it directly: \(appLink(code))\nGet the app: \(GroupInvite.downloadURL)")
    }

    /// Where someone without the app gets it (the same page the share card of a place links to).
    static let downloadURL = "https://tokenmaccer.app"
}
