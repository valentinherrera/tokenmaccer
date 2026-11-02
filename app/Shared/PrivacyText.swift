import Foundation

/// The privacy notice (docs/privacy.md and docs/privacy.de.md, bundled with the app) as blocks the app shows in a
/// sheet, so the notice is readable before joining without any network request and whether or not the hosted
/// copy is reachable. Handles the Markdown the notice uses: headings, paragraphs, bullets, one kind of table and
/// inline emphasis, code and links. Relative links (the language switch) are dropped, they lead nowhere in the app.
enum PrivacyText {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case table(header: [String], rows: [[String]])
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        var lastWasBullet = false

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            guard let header = table.first else { return }
            blocks.append(.table(header: header, rows: Array(table.dropFirst())))
            table = []
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = dropRelativeLinks(raw.trimmingCharacters(in: .whitespaces))
            if line.hasPrefix("|") {
                flushParagraph()
                lastWasBullet = false
                let cells = cellsOf(line)
                // the |---|---| line under the header
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty {
                flushParagraph()
                lastWasBullet = false
            } else if let level = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(level: level, text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                lastWasBullet = false
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                lastWasBullet = true
            } else if lastWasBullet, case .bullet(let text)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(text + " " + line)
            } else {
                paragraph.append(line)
            }
        }
        flushTable()
        flushParagraph()
        return blocks
    }

    /// "[Deutsch](privacy.de.md) · Last updated" -> "Last updated"; any other relative link keeps its text.
    static func dropRelativeLinks(_ s: String) -> String {
        guard s.contains("](") else { return s }
        let relative = #"\[([^\]]*)\]\((?![A-Za-z][A-Za-z0-9+.-]*:)[^)]*\)"#
        let withSeparator = s.replacingOccurrences(of: relative + #"\s*·\s*"#, with: "", options: .regularExpression)
        return withSeparator.replacingOccurrences(of: relative, with: "$1", options: .regularExpression)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func cellsOf(_ line: String) -> [String] {
        var parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
