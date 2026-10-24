import Foundation
import SwiftUI

// Block-level Markdown renderer used for contentType == 1 and [md] blocks.
// It deliberately supports the common CC98 Markdown surface rather than
// pretending AttributedString's inline parser is a full document renderer.
enum NativeMarkdownRenderer {
    static func parse(_ source: String) -> [UBBBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [UBBBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let inlines = inline(paragraph.joined(separator: "\n"))
            if !inlines.isEmpty {
                blocks.append(.text(inlines, .leading))
            }
            paragraph = []
        }

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
                index += 1
                var code: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingText(line) {
                flushParagraph()
                blocks.append(.heading(heading.text, heading.level))
                index += 1
                continue
            }

            if isThematicBreak(line) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = String(candidate.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoted.append(content)
                    index += 1
                }
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            if let image = imageOnly(line) {
                flushParagraph()
                blocks.append(.image(
                    UBBBlockParser.resolveURL(image.url),
                    image.alt.isEmpty ? nil : image.alt,
                    false
                ))
                index += 1
                continue
            }

            if isTableStart(lines, at: index) {
                flushParagraph()
                var rows: [[String]] = []
                rows.append(tableCells(lines[index]))
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.contains("|"), !candidate.isEmpty else { break }
                    rows.append(tableCells(candidate))
                    index += 1
                }
                if !rows.isEmpty {
                    blocks.append(.table(rows))
                }
                continue
            }

            if listItemText(line) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let item = listItemText(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(item)
                    index += 1
                }
                if !items.isEmpty {
                    blocks.append(.list(items))
                }
                continue
            }

            paragraph.append(rawLine)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    static func inline(_ source: String) -> [UBBInline] {
        let cleaned = UBBBlockParser.cleanText(source)
        guard !cleaned.isEmpty else { return [] }
        if let attributed = try? AttributedString(
            markdown: cleaned,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return [.text(attributed)]
        }
        return [.text(AttributedString(cleaned))]
    }

    private static func headingText(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (hashes, text)
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func imageOnly(_ line: String) -> (alt: String, url: String)? {
        guard let regex = try? NSRegularExpression(pattern: "^!\\[([^\\]]*)\\]\\(([^\\)]+)\\)$") else {
            return nil
        }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let alt = ns.substring(with: match.range(at: 1))
        let url = ns.substring(with: match.range(at: 2))
        return url.isEmpty ? nil : (alt, url)
    }

    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = lines[index]
        let separator = lines[index + 1]
        guard header.contains("|"), separator.contains("-") else { return false }
        let cells = tableCells(separator)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func listItemText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        guard Int(trimmed[..<dot]) != nil else { return nil }
        let rest = trimmed[trimmed.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        return String(rest.dropFirst())
    }
}
