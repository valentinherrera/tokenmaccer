import AppKit
import SwiftUI

// Renders the leaderboard widget from fixtures (no files, no network): every state, medium and large, light and dark.
// Build: xcrun swiftc app/Shared/*.swift app/Preview/LeaderboardWidget/main.swift -o render-board
// Usage: render-board <output dir> [-AppleLocale de_DE]
@MainActor
func render() {
    let args = CommandLine.arguments
    guard args.count > 1 else {
        print("usage: render-board <output dir>")
        exit(2)
    }
    let out = URL(fileURLWithPath: args[1])
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let names = ["Mara Lindqvist", "octo-dev", "Jonas", "Priya Raman", "Theo", "Ana Sofía Castellanos de la Vega",
                 "kenji", "Lena B.", "Sam", "Ruth"]
    func fixture(meRank: Int, count: Int = 120, fetched: Bool = true, avatars: Bool = true, groups: Bool = false)
        -> LeaderboardWidgetData?
    {
        var boards: [[String: Any]] = []
        var pics: [String: String] = [:]
        for p in Selection.periods {
            for u in ["tokens", "usd"] {
                var rows: [[String: Any]] = []
                for r in Array(1...8) + (meRank > 8 ? [meRank] : []) {
                    let me = r == meRank
                    let login = me ? "you-gh" : "user\(r)"
                    let value = u == "usd" ? 2400.0 / Double(r) : 812_000_000.0 / Double(r)
                    rows.append(["rank": r, "displayName": me ? "You Here" : names[(r - 1) % names.count],
                                 "githubLogin": login, "value": value, "isMe": me])
                    if avatars, r != 4, let png = avatar(login) { pics[login] = png.base64EncodedString() }
                }
                boards.append(["period": p, "unit": u, "participants": count, "entries": rows])
            }
        }
        var obj: [String: Any] = ["boards": fetched ? boards : [], "avatars": fetched ? pics : [:]]
        if fetched { obj["fetchedAt"] = 1_793_000_000 }
        // two groups: the title shows the switch symbol and a click goes global → groups → global
        if groups { obj["groups"] = [["id": "g1", "name": "Friday Hackers", "boards": boards],
                                      ["id": "g2", "name": "Team", "boards": boards]] }
        return LeaderboardWidgetData.decode(try! JSONSerialization.data(withJSONObject: obj))
    }
    let empty = LeaderboardWidgetData.decode(Data(#"{"fetchedAt": 1793000000, "boards": [], "avatars": {}}"#.utf8))

    let scenes: [(String, LeaderboardWidgetData?, Unit, String?)] = [
        ("outside", fixture(meRank: 23), .tokens, nil),
        ("inside", fixture(meRank: 2), .usd, nil),
        ("fifth", fixture(meRank: 5, avatars: false), .tokens, nil),
        ("waiting", fixture(meRank: 1, fetched: false), .tokens, nil),
        ("empty", empty, .tokens, nil),
        ("notjoined", nil, .tokens, nil),
        ("globalgroups", fixture(meRank: 23, groups: true), .tokens, nil),
        ("group", fixture(meRank: 2, groups: true), .tokens, "g1"),
    ]
    let sizes: [(String, Size, CGSize)] = [
        ("medium", .medium, CGSize(width: 364, height: 170)),
        ("large", .large, CGSize(width: 364, height: 382)),
    ]
    var n = 0
    for (name, data, unit, group) in scenes {
        for (sizeName, size, frame) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let v = LeaderboardWidgetView(data: data, group: group, period: "7D", unit: unit, size: size)
                    .padding(14)
                    .frame(width: frame.width, height: frame.height)
                    .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95))
                    .environment(\.colorScheme, scheme)
                let r = ImageRenderer(content: v)
                r.scale = 2
                guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: out.appendingPathComponent("board_\(name)_\(sizeName)_\(scheme == .dark ? "dark" : "light").png"))
                n += 1
            }
        }
    }
    print("rendered \(n) images to \(out.path)")
}

/// A symmetric 5x5 pattern per login, in place of a GitHub picture.
func avatar(_ login: String) -> Data? {
    let hue = CGFloat(login.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
    let base = NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1)
    let img = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor(white: 0.95, alpha: 1).setFill()
        rect.fill()
        base.setFill()
        let cell = rect.width / 5
        for x in 0..<3 {
            for y in 0..<5 where (login.unicodeScalars.reduce(x * 7 + y * 3) { $0 + Int($1.value) }) % 2 == 0 {
                NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
                NSRect(x: CGFloat(4 - x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
            }
        }
        return true
    }
    guard let tiff = img.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
}

MainActor.assumeIsolated { render() }
