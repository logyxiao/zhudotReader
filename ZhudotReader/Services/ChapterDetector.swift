import Foundation

enum ChapterDetector {
    private static let textPattern = #"(?m)^[ \t]*(第[零〇一二两三四五六七八九十百千万0-9]+[章节卷回部集篇]|序章|楔子|引子|前言|后记|尾声|番外(?:[一二三四五六七八九十0-9]+)?|Chapter\s+\d+|[0-9]{1,4}[\.、]\s*[^\n]{0,40})[^\n]{0,60}$"#

    static func textChapters(in text: String) -> [Chapter] {
        guard let regex = try? NSRegularExpression(pattern: textPattern, options: [.caseInsensitive]) else {
            return []
        }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let title = source.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            let level = title.contains("卷") || title.contains("部") ? 0 : 1
            return Chapter(id: "\(match.range.location)-\(title)", title: title, offset: match.range.location, level: level)
        }
    }

    static func markdownHeadings(source: String, displayText: String) -> [Chapter] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^(#{1,6})[ \t]+(.+?)[ \t]*#*$"#,
            options: []
        ) else { return [] }

        let sourceString = source as NSString
        let displayString = displayText as NSString
        var searchLocation = 0
        var chapters: [Chapter] = []

        for match in regex.matches(in: source, range: NSRange(location: 0, length: sourceString.length)) {
            let hashes = sourceString.substring(with: match.range(at: 1))
            let rawTitle = sourceString.substring(with: match.range(at: 2))
            let title = plainInlineMarkdown(rawTitle)
            let remaining = NSRange(location: searchLocation, length: max(0, displayString.length - searchLocation))
            let range = displayString.range(of: title, options: [], range: remaining)
            let offset = range.location == NSNotFound ? searchLocation : range.location
            searchLocation = min(displayString.length, offset + (title as NSString).length)
            chapters.append(
                Chapter(
                    id: "\(offset)-\(title)",
                    title: title,
                    offset: offset,
                    level: max(0, hashes.count - 1)
                )
            )
        }
        return chapters
    }

    private static func plainInlineMarkdown(_ text: String) -> String {
        let patterns = [#"\[([^\]]+)\]\([^\)]+\)"#: "$1", #"[*_`~]"#: ""]
        return patterns.reduce(text) { value, pair in
            value.replacingOccurrences(of: pair.key, with: pair.value, options: .regularExpression)
        }.trimmingCharacters(in: .whitespaces)
    }
}

