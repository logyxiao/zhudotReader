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
            characterCount: (rendered.text as NSString).length
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

    private func baseAttributes(preferences: ReaderPreferences, palette: ReaderPalette) -> [NSAttributedString.Key: Any] {
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

