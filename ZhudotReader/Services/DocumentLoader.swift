import AppKit
import Foundation

struct DocumentLoader {
    func load(url: URL, preferences: ReaderPreferences, palette: ReaderPalette) throws -> ReaderDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ReaderError.unreadableDocument(url.deletingPathExtension().lastPathComponent)
        }
        let source = try TextDecoder.decode(data, fileName: url.lastPathComponent)
        return makeDocument(url: url, source: source, preferences: preferences, palette: palette)
    }

    func restyle(
        _ document: ReaderDocument,
        source: String? = nil,
        preferences: ReaderPreferences,
        palette: ReaderPalette
    ) -> ReaderDocument {
        makeDocument(
            url: document.url,
            source: source ?? document.sourceText,
            preferences: preferences,
            palette: palette
        )
    }

    private func makeDocument(
        url: URL,
        source: String,
        preferences: ReaderPreferences,
        palette: ReaderPalette
    ) -> ReaderDocument {
        let format: DocumentFormat = url.pathExtension.lowercased() == "md" ? .markdown : .text
        let rendered: (text: String, attributed: NSAttributedString)
        if format == .markdown {
            rendered = renderMarkdown(source, preferences: preferences, palette: palette)
        } else {
            rendered = renderText(source, preferences: preferences, palette: palette)
        }
        let chapters = format == .markdown
            ? ChapterDetector.markdownHeadings(source: source, displayText: rendered.text)
            : ChapterDetector.textChapters(in: rendered.text)

        return ReaderDocument(
            id: url.standardizedFileURL.path,
            url: url,
            title: url.deletingPathExtension().lastPathComponent,
            format: format,
            sourceText: source,
            displayText: rendered.text,
            attributedText: rendered.attributed,
            chapters: chapters,
            characterCount: (rendered.text as NSString).length,
            contentFingerprint: (source as NSString).length &+ source.hashValue
        )
    }

    private func renderText(
        _ text: String,
        preferences: ReaderPreferences,
        palette: ReaderPalette
    ) -> (String, NSAttributedString) {
        let output = NSMutableAttributedString(string: text)
        output.addAttributes(baseAttributes(preferences: preferences, palette: palette), range: output.fullRange)
        return (text, output)
    }

    private func renderMarkdown(
        _ source: String,
        preferences: ReaderPreferences,
        palette: ReaderPalette
    ) -> (String, NSAttributedString) {
        let output = NSMutableAttributedString()
        let lines = source.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let block = markdownBlock(for: line)
            let parsed = inlineMarkdown(block.text)
            let start = output.length
            output.append(parsed)
            if index < lines.count - 1 { output.append(NSAttributedString(string: "\n")) }
            let length = output.length - start
            guard length > 0 else { continue }

            let range = NSRange(location: start, length: length)
            output.addAttributes(baseAttributes(preferences: preferences, palette: palette), range: range)
            let blockName: String
            switch block.kind {
            case let .heading(level): blockName = "heading:\(level)"
            case .quote: blockName = "quote"
            case .list: blockName = "list"
            case .rule: blockName = "rule"
            case .body: blockName = "body"
            }
            output.addAttributes([
                .readerMarkdownSource: line,
                .readerMarkdownDisplay: parsed.string,
                .readerMarkdownBlock: blockName
            ], range: range)
            applyInlineTraits(to: output, range: range, baseFont: preferences.fontFamily.font(size: preferences.fontSize))

            switch block.kind {
            case let .heading(level):
                let size = preferences.fontSize + max(2, Double(7 - level) * 1.7)
                output.addAttributes([
                    .font: boldFont(from: preferences.fontFamily.font(size: size)),
                    .foregroundColor: palette.nsText,
                    .paragraphStyle: paragraphStyle(
                        fontSize: size,
                        multiplier: 1.35,
                        before: level <= 2 ? 22 : 14,
                        after: 10
                    )
                ], range: range)
            case .quote:
                output.addAttributes([
                    .foregroundColor: palette.nsMuted,
                    .paragraphStyle: paragraphStyle(
                        fontSize: preferences.fontSize,
                        multiplier: preferences.lineHeight.rawValue,
                        headIndent: 18,
                        firstLineIndent: 18,
                        after: 8
                    )
                ], range: range)
            case .rule:
                output.addAttributes([
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: palette.nsMuted,
                    .kern: 3
                ], range: range)
            case .list:
                output.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle(
                        fontSize: preferences.fontSize,
                        multiplier: preferences.lineHeight.rawValue,
                        headIndent: 20,
                        firstLineIndent: 2,
                        after: 4
                    ),
                    range: range
                )
            case .body:
                break
            }
        }
        return (output.string, output)
    }

    private enum MarkdownBlockKind {
        case heading(Int)
        case quote
        case list
        case rule
        case body
    }

    private func markdownBlock(for line: String) -> (text: String, kind: MarkdownBlockKind) {
        if let match = line.firstMatch(of: /^(#{1,6})[ \t]+(.+?)[ \t]*#*$/) {
            return (String(match.2), .heading(match.1.count))
        }
        if let match = line.firstMatch(of: /^[ \t]*>[ \t]?(.*)$/) {
            return (String(match.1), .quote)
        }
        if let match = line.firstMatch(of: /^[ \t]*[-+*][ \t]+(.+)$/) {
            return ("•  \(match.1)", .list)
        }
        if line.trimmingCharacters(in: .whitespaces).wholeMatch(of: /[-*_]{3,}/) != nil {
            return ("────────────", .rule)
        }
        return (line, .body)
    }

    func markdownLinePresentation(_ source: String) -> NSAttributedString {
        inlineMarkdown(markdownBlock(for: source).text)
    }

    private func inlineMarkdown(_ source: String) -> NSMutableAttributedString {
        guard !source.isEmpty,
              let parsed = try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              ) else {
            return NSMutableAttributedString(string: source)
        }
        return NSMutableAttributedString(attributedString: NSAttributedString(parsed))
    }

    func baseAttributes(preferences: ReaderPreferences, palette: ReaderPalette) -> [NSAttributedString.Key: Any] {
        [
            .font: preferences.fontFamily.font(size: preferences.fontSize),
            .foregroundColor: palette.nsText,
            .paragraphStyle: paragraphStyle(
                fontSize: preferences.fontSize,
                multiplier: preferences.lineHeight.rawValue,
                firstLineIndent: preferences.fontSize * 2,
                after: preferences.fontSize * 0.42
            ),
            .kern: 0
        ]
    }

    private func paragraphStyle(
        fontSize: Double,
        multiplier: Double,
        headIndent: Double = 0,
        firstLineIndent: Double = 0,
        before: Double = 0,
        after: Double = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = multiplier
        style.minimumLineHeight = fontSize * multiplier
        style.maximumLineHeight = fontSize * multiplier
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineIndent
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private func applyInlineTraits(to text: NSMutableAttributedString, range: NSRange, baseFont: NSFont) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let existing = value as? NSFont else { return }
            var traits = existing.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
            if existing.fontDescriptor.symbolicTraits.contains(.monoSpace) { traits.insert(.monoSpace) }
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
            text.addAttribute(.font, value: NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont, range: subrange)
        }
    }

    private func boldFont(from font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
}

private extension NSMutableAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}


extension NSAttributedString.Key {
    static let readerMarkdownSource = Self("ZhudotMarkdownSource")
    static let readerMarkdownDisplay = Self("ZhudotMarkdownDisplay")
    static let readerMarkdownBlock = Self("ZhudotMarkdownBlock")
}

/// Keep untouched Markdown lines byte-for-byte. Changed lines are written from
/// their visible text and semantic attributes, so hidden syntax is never exposed
/// just to enter editing and links/emphasis are not flattened into plain text.
enum MarkdownDraftWriter {
    static func source(from text: NSAttributedString) -> String {
        let lines = text.string.components(separatedBy: "\n")
        var offset = 0
        return lines.map { line in
            let length = (line as NSString).length
            let range = NSRange(location: offset, length: length)
            defer { offset += length + 1 }
            let attributes = offset < text.length ? text.attributes(at: offset, effectiveRange: nil) : [:]
            if let original = attributes[.readerMarkdownSource] as? String,
               let visible = attributes[.readerMarkdownDisplay] as? String, visible == line {
                return original
            }
            if let original = attributes[.readerMarkdownSource] as? String,
               let visible = attributes[.readerMarkdownDisplay] as? String,
               let preserved = preservedEdit(source: original, visible: visible, edited: text.attributedSubstring(from: range)) {
                return preserved
            }
            guard length > 0 else { return "" }
            let block = attributes[.readerMarkdownBlock] as? String ?? "body"
            var content = range
            var prefix = ""
            if block.hasPrefix("heading:"), let level = Int(block.dropFirst(8)), (1...6).contains(level) {
                prefix = String(repeating: "#", count: level) + " "
            } else if block == "quote" {
                prefix = "> "
            } else if block == "list", line.hasPrefix("•  ") {
                content.location += 3; content.length -= 3
                prefix = "- "
            }
            // An edited rule or a deleted bullet becomes an ordinary paragraph.
            return prefix + inline(text.attributedSubstring(from: content))
        }.joined(separator: "\n")
    }

    private static func preservedEdit(source: String, visible: String, edited: NSAttributedString) -> String? {
        let old = Array(visible), new = Array(edited.string)
        var prefix = 0, suffix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let start = String(old.prefix(prefix)).utf16.count
        let end = visible.utf16.count - String(old.suffix(suffix)).utf16.count
        let inserted = String(new[prefix..<(new.count - suffix)])
        let raw = Array(source.utf16), shown = Array(visible.utf16)
        let difference = shown.difference(from: raw)
        var removed = Set<Int>(), insertedIndices = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): insertedIndices.insert(offset)
            }
        }
        var mapping = [Int?](repeating: nil, count: shown.count)
        var a = 0, b = 0
        while a < raw.count || b < shown.count {
            if removed.contains(a), a < raw.count { a += 1 }
            else if insertedIndices.contains(b), b < shown.count { b += 1 }
            else if a < raw.count, b < shown.count { mapping[b] = a; a += 1; b += 1 }
            else { break }
        }
        let sourceRange: NSRange
        if start == end {
            let anchor = start < mapping.count ? mapping[start] : mapping.last.flatMap { $0 }.map { $0 + 1 }
            guard let anchor else { return nil }
            sourceRange = NSRange(location: anchor, length: 0)
        } else {
            guard start < mapping.count, end > 0, let first = mapping[start], let last = mapping[end - 1] else { return nil }
            sourceRange = NSRange(location: first, length: last - first + 1)
        }
        let candidate = (source as NSString).replacingCharacters(in: sourceRange, with: escaped(inserted))
        let rendered = DocumentLoader().markdownLinePresentation(candidate)
        guard rendered.string == edited.string, rendered.length == edited.length else { return nil }
        // A boundary insertion must inherit the same emphasis/link as the caret,
        // not accidentally move inside a hidden Markdown delimiter.
        for index in 0..<edited.length {
            let intent = NSAttributedString.Key("NSInlinePresentationIntent")
            let lhs = (rendered.attribute(intent, at: index, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
            let rhs = (edited.attribute(intent, at: index, effectiveRange: nil) as? NSNumber)?.intValue ?? 0
            guard lhs == rhs else { return nil }
            let leftLink = rendered.attribute(.link, at: index, effectiveRange: nil).map { String(describing: $0) }
            let rightLink = edited.attribute(.link, at: index, effectiveRange: nil).map { String(describing: $0) }
            guard leftLink == rightLink else { return nil }
        }
        return candidate
    }

    private struct Run {
        var text: String
        let intent: Int
        let link: String?
    }

    private static func inline(_ text: NSAttributedString) -> String {
        var runs: [Run] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let value = (text.string as NSString).substring(with: range)
            let intent = (attributes[NSAttributedString.Key("NSInlinePresentationIntent")] as? NSNumber)?.intValue ?? 0
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            if let last = runs.last, last.intent == intent, last.link == link {
                runs[runs.count - 1].text += value
            } else { runs.append(Run(text: value, intent: intent, link: link)) }
        }
        return runs.map { run in
            var result: String
            if run.intent & 4 != 0 {
                let longest = run.text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let delimiter = String(repeating: "`", count: longest + 1)
                let needsSpace = run.text.hasPrefix("`") || run.text.hasSuffix("`") ||
                    (run.text.hasPrefix(" ") && run.text.hasSuffix(" ") && !run.text.allSatisfy { $0 == " " })
                result = delimiter + (needsSpace ? " " : "") + run.text + (needsSpace ? " " : "") + delimiter
            } else {
                // Delimiters cannot enclose leading/trailing whitespace in Markdown.
                let leading = String(run.text.prefix(while: { $0.isWhitespace }))
                let remainder = run.text.dropFirst(leading.count)
                let trailing = String(remainder.reversed().prefix(while: { $0.isWhitespace }).reversed())
                let core = String(remainder.dropLast(trailing.count))
                let emphasis = run.intent & 3
                let marker = emphasis == 3 ? "***" : (emphasis == 2 ? "**" : (emphasis == 1 ? "*" : ""))
                var middle = escaped(core)
                if !core.isEmpty {
                    middle = marker + middle + marker
                    if run.intent & 32 != 0 { middle = "~~" + middle + "~~" }
                }
                result = escaped(leading) + middle + escaped(trailing)
            }
            if let link = run.link {
                let destination = link.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                result = "[" + result + "](<" + destination + ">)"
            }
            return result
        }.joined()
    }

    private static func escaped(_ text: String) -> String {
        let punctuation = Set("\\`*_{}[]<>()#+-.!|~")
        return text.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
    }
}
