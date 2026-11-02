import Foundation
import XCTest

/// The privacy notice the consent opens in the app (Shared/PrivacyText.swift over docs/privacy*.md): the real
/// files parse completely, nothing points to a page that does not exist inside the app.
final class PrivacyTextTests: XCTestCase {
    func testBlocks() {
        let md = """
        # Title

        [Deutsch](privacy.de.md) · Last updated: 2 November 2026

        First line
        continues here with a [link](https://example.com).

        ## Section

        | What | Contents | Visible |
        |---|---|---|
        | A | **a** | No |
        | B | `b` | Yes |

        - one
          more
        - two
        """
        XCTAssertEqual(PrivacyText.parse(md), [
            .heading(level: 1, text: "Title"),
            .paragraph("Last updated: 2 November 2026"),
            .paragraph("First line continues here with a [link](https://example.com)."),
            .heading(level: 2, text: "Section"),
            .table(header: ["What", "Contents", "Visible"], rows: [["A", "**a**", "No"], ["B", "`b`", "Yes"]]),
            .bullet("one more"),
            .bullet("two"),
        ])
    }

    func testRelativeLinksKeepTheirTextOrDropWithTheSeparator() {
        XCTAssertEqual(PrivacyText.dropRelativeLinks("[English](privacy.md) · Stand: 2. November 2026"),
                       "Stand: 2. November 2026")
        XCTAssertEqual(PrivacyText.dropRelativeLinks("see [the README](../README.md)"), "see the README")
        XCTAssertEqual(PrivacyText.dropRelativeLinks("[issues](https://github.com/x/y/issues)"),
                       "[issues](https://github.com/x/y/issues)")
        XCTAssertEqual(PrivacyText.dropRelativeLinks("<mailto:a@example.com> [m](mailto:a@example.com)"),
                       "<mailto:a@example.com> [m](mailto:a@example.com)")
    }

    func testBundledNoticesParseCompletely() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs")
        for file in ["privacy.md", "privacy.de.md"] {
            let text = try String(contentsOf: docs.appendingPathComponent(file), encoding: .utf8)
            let blocks = PrivacyText.parse(text)
            guard case .heading(1, _)? = blocks.first else { return XCTFail("\(file): starts with no title") }
            var tables = 0
            var words = 0
            for block in blocks {
                let parts: [String]
                switch block {
                case .heading(_, let t), .paragraph(let t), .bullet(let t): parts = [t]
                case .table(let header, let rows):
                    tables += 1
                    XCTAssertGreaterThan(rows.count, 0, file)
                    for row in rows { XCTAssertEqual(row.count, header.count, "\(file): \(row.first ?? "")") }
                    parts = header + rows.flatMap { $0 }
                }
                for p in parts {
                    XCTAssertFalse(p.contains("](privacy"), "\(file): relative link left: \(p)")
                    XCTAssertFalse(p.hasPrefix("|") || p.hasPrefix("#"), "\(file): unparsed line: \(p)")
                    words += p.split(separator: " ").count
                }
            }
            XCTAssertEqual(tables, 1, file)
            // every word of the file arrives in a block (markup characters aside)
            let sourceWords = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .filter { !$0.allSatisfy { "#|-:·".contains($0) } }.count
            XCTAssertGreaterThan(Double(words), Double(sourceWords) * 0.97, "\(file): text lost")
        }
    }
}
