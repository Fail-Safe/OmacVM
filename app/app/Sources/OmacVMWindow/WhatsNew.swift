import Foundation

/// What a new version brings, for the update banner and What's New: its
/// section of CHANGELOG.md, read from the downloaded app itself
/// (Contents/Resources/omacvm/CHANGELOG.md; the app's signature was checked
/// before, so nothing here comes from the network unchecked).
public struct WhatsNew: Equatable, Sendable {
    /// The section's opening line, if it has one ("Full screen including the notch, ...").
    public var intro: String?
    /// The bullets, as Markdown (bold, code, links), continuation lines joined.
    public var items: [String]

    public init(intro: String?, items: [String]) {
        self.intro = intro
        self.items = items
    }

    public static let maxItems = 30
    public static let maxBytes = 512 * 1024

    /// The "## VERSION" section of a changelog; nil when it has none.
    public static func parse(changelog: String, version: String) -> WhatsNew? {
        guard changelog.utf8.count <= maxBytes else { return nil }
        var inSection = false, intro: [String] = [], items: [String] = []
        for raw in changelog.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("## ") {
                if inSection { break }
                let title = raw.dropFirst(3).trimmingCharacters(in: .whitespaces)
                inSection = title == version || title.hasPrefix(version + " ")
                continue
            }
            guard inSection else { continue }
            if raw.hasPrefix("- ") || raw.hasPrefix("* ") {
                items.append(String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if line.isEmpty {
                continue
            } else if raw.hasPrefix(" "), !items.isEmpty {
                items[items.count - 1] += " " + line
            } else if items.isEmpty {
                intro.append(line)
            }
        }
        guard inSection, !(intro.isEmpty && items.isEmpty) else { return nil }
        return WhatsNew(intro: intro.isEmpty ? nil : intro.joined(separator: " "), items: Array(items.prefix(maxItems)))
    }

    /// One line for the banner: the intro, else the first item's first
    /// sentence, as plain text, cut at `limit` characters.
    public func summary(limit: Int = 110) -> String? {
        guard let text = intro ?? items.first.map(Self.firstSentence) else { return nil }
        let plain = Self.plain(text)
        guard plain.count > limit else { return plain }
        let cut = plain.prefix(limit - 1)
        let end = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return end.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }

    static func firstSentence(_ s: String) -> String {
        guard let r = s.range(of: #"\.\s"#, options: .regularExpression) else { return s }
        return String(s[..<r.lowerBound]) + "."
    }

    /// Markdown's marks out: **bold**, `code`, [text](link).
    public static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "`", "__"] { t = t.replacingOccurrences(of: mark, with: "") }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
