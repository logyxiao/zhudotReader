import Foundation

enum WordDocumentExporter {
    static func export(source: String, sourceURL: URL) throws -> URL {
        let title = novelTitle(for: sourceURL)
        let output = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(sanitizedFileName(title)).docx")
        let bytes = try package(source: source, title: title)
        try bytes.write(to: output, options: .atomic)
        return output
    }

    static func novelTitle(for url: URL) -> String {
        let fileName = url.lastPathComponent
        let base = url.deletingPathExtension().lastPathComponent
        let isZhengwen = base == "正文" && ["md", "txt"].contains(url.pathExtension.lowercased())
        if isZhengwen {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/" {
                return parent
            }
        }
        return fileName.isEmpty ? "未命名" : base
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "：")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    private static func package(source: String, title: String) throws -> Data {
        var body = titleParagraphXML(title)
        body += blankParagraphXML
        for paragraph in parseParagraphs(source) {
            body += paragraphXML(paragraph)
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="宋体" w:eastAsia="宋体" w:hAnsi="宋体"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>
        """

        var archive = StoredZipArchive()
        archive.addFile("[Content_Types].xml", contentTypes)
        archive.addFile("_rels/.rels", rels)
        archive.addFile("word/_rels/document.xml.rels", documentRels)
        archive.addFile("word/document.xml", document)
        archive.addFile("word/styles.xml", styles)
        return archive.packed()
    }
}

private enum WordParagraph: Equatable {
    case heading(String)
    case title(String)
    case body(String)
    case blank
}

private extension WordDocumentExporter {
    static let headingRun = #"<w:rPr><w:rFonts w:ascii="宋体" w:eastAsia="宋体" w:hAnsi="宋体"/><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>"#
    static let bodyRun = #"<w:rPr><w:rFonts w:ascii="宋体" w:eastAsia="宋体" w:hAnsi="宋体"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>"#
    static let blankParagraphXML = #"<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/></w:pPr></w:p>"#

    static func titleParagraphXML(_ title: String) -> String {
        let run = #"<w:rPr><w:rFonts w:ascii="宋体" w:eastAsia="宋体" w:hAnsi="宋体"/><w:b/><w:sz w:val="44"/><w:szCs w:val="44"/></w:rPr>"#
        return #"<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/><w:jc w:val="center"/>\#(run)</w:pPr><w:r>\#(run)\#(textXML(title))</w:r></w:p>"#
    }

    static func paragraphXML(_ paragraph: WordParagraph) -> String {
        switch paragraph {
        case let .heading(title):
            return #"<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/><w:jc w:val="center"/>\#(headingRun)</w:pPr><w:r>\#(headingRun)\#(textXML(title))</w:r></w:p>"#
        case let .title(title):
            return #"<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/>\#(bodyRun)</w:pPr><w:r><w:rPr><w:rFonts w:ascii="宋体" w:eastAsia="宋体" w:hAnsi="宋体"/><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>\#(textXML(title))</w:r></w:p>"#
        case let .body(text):
            return #"<w:p><w:pPr><w:spacing w:line="360" w:lineRule="auto"/><w:ind w:firstLineChars="200" w:firstLine="480"/>\#(bodyRun)</w:pPr><w:r>\#(bodyRun)\#(textXML(text))</w:r></w:p>"#
        case .blank:
            return blankParagraphXML
        }
    }

    static func parseParagraphs(_ text: String) -> [WordParagraph] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var out: [WordParagraph] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if out.last != .blank {
                    out.append(.blank)
                }
                continue
            }
            if let number = chapterNumber(in: trimmed) {
                out.append(.heading("第\(chineseNumber(number))章"))
                continue
            }
            if let heading = markdownHeading(in: trimmed) {
                out.append(.title(cleanInline(heading)))
                continue
            }
            out.append(.body(cleanInline(trimmed)))
        }

        while out.first == .blank { out.removeFirst() }
        while out.last == .blank { out.removeLast() }
        return out
    }

    static func chapterNumber(in line: String) -> UInt32? {
        guard let regex = try? NSRegularExpression(pattern: #"^###\s*(\d{1,3})\.?\s*$"#) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let numberRange = Range(match.range(at: 1), in: line) else { return nil }
        return UInt32(line[numberRange])
    }

    static func markdownHeading(in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^#{1,6}\s+(.*)$"#) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let titleRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[titleRange])
    }

    static func cleanInline(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\([^)]*\)|\*\*([^*]+)\*\*|\*([^*]+)\*|`([^`]+)`|\[([^\]]+)\]\([^)]*\)"#
        ) else { return trimmed }

        let nsText = trimmed as NSString
        var result = ""
        var cursor = 0
        let full = NSRange(location: 0, length: nsText.length)
        regex.enumerateMatches(in: trimmed, range: full) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let captured = (2...5).compactMap { index -> String? in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return nsText.substring(with: range)
            }.first ?? {
                let range = match.range(at: 1)
                return range.location == NSNotFound ? "" : nsText.substring(with: range)
            }()
            result += captured
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }
        return result
    }

    static func chineseNumber(_ value: UInt32) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if value == 0 { return "零" }
        var out = ""
        if value >= 100 {
            out += digits[Int(value / 100)]
            out += "百"
            let rest = value % 100
            if rest != 0 && rest < 10 {
                out += "零"
            }
        }
        let rest = value % 100
        if rest >= 10 {
            let tens = rest / 10
            if !(value < 100 && tens == 1) {
                out += digits[Int(tens)]
            }
            out += "十"
            if rest % 10 != 0 {
                out += digits[Int(rest % 10)]
            }
        } else if rest > 0 {
            out += digits[Int(rest)]
        }
        return out
    }

    static func textXML(_ text: String) -> String {
        let cleaned = text.unicodeScalars.filter { scalar in
            scalar == "\t"
                || scalar == "\n"
                || (scalar.value >= 0x20 && scalar.value != 0x7F)
        }.reduce(into: "") { $0.unicodeScalars.append($1) }
        let escaped = cleaned
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let needsPreserve = escaped.hasPrefix(" ") || escaped.hasSuffix(" ")
        if needsPreserve {
            return #"<w:t xml:space="preserve">\#(escaped)</w:t>"#
        }
        return "<w:t>\(escaped)</w:t>"
    }
}

private struct StoredZipArchive {
    private var files: [(name: String, data: Data)] = []

    mutating func addFile(_ name: String, _ text: String) {
        files.append((name, Data(text.utf8)))
    }

    func packed() -> Data {
        var local = Data()
        var central = Data()
        var offset: UInt32 = 0

        for file in files {
            let nameData = Data(file.name.utf8)
            let crc = CRC32.hash(file.data)
            let size = UInt32(file.data.count)
            var header = Data()
            header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            appendUInt16(&header, 20)
            appendUInt16(&header, 0x0800)
            appendUInt16(&header, 0)
            appendUInt16(&header, 0)
            appendUInt16(&header, 0)
            appendUInt32(&header, crc)
            appendUInt32(&header, size)
            appendUInt32(&header, size)
            appendUInt16(&header, UInt16(nameData.count))
            appendUInt16(&header, 0)
            header.append(nameData)
            header.append(file.data)

            var directory = Data()
            directory.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            appendUInt16(&directory, 20)
            appendUInt16(&directory, 20)
            appendUInt16(&directory, 0x0800)
            appendUInt16(&directory, 0)
            appendUInt16(&directory, 0)
            appendUInt16(&directory, 0)
            appendUInt32(&directory, crc)
            appendUInt32(&directory, size)
            appendUInt32(&directory, size)
            appendUInt16(&directory, UInt16(nameData.count))
            appendUInt16(&directory, 0)
            appendUInt16(&directory, 0)
            appendUInt16(&directory, 0)
            appendUInt16(&directory, 0)
            appendUInt32(&directory, 0)
            appendUInt32(&directory, offset)
            directory.append(nameData)

            offset += UInt32(header.count)
            local.append(header)
            central.append(directory)
        }

        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        appendUInt16(&eocd, 0)
        appendUInt16(&eocd, 0)
        appendUInt16(&eocd, UInt16(files.count))
        appendUInt16(&eocd, UInt16(files.count))
        appendUInt32(&eocd, UInt32(central.count))
        appendUInt32(&eocd, offset)
        appendUInt16(&eocd, 0)

        var output = Data()
        output.append(local)
        output.append(central)
        output.append(eocd)
        return output
    }
}

private enum CRC32 {
    static func hash(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private func appendUInt16(_ data: inout Data, _ value: UInt16) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func appendUInt32(_ data: inout Data, _ value: UInt32) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}
