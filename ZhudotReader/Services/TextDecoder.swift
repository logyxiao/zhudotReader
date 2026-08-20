import CoreFoundation
import Foundation

enum TextDecoder {
    static func decode(_ data: Data, fileName: String) throws -> String {
        let encodings: [String.Encoding] = bomEncoding(for: data) + [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            chineseEncoding(CFStringEncodings.GB_18030_2000),
            chineseEncoding(CFStringEncodings.GB_2312_80),
            chineseEncoding(CFStringEncodings.big5)
        ]

        for encoding in unique(encodings) {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            let text = decoded
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            if !text.contains("\u{FFFD}") {
                return text
            }
        }
        throw ReaderError.unsupportedEncoding(fileName)
    }

    private static func bomEncoding(for data: Data) -> [String.Encoding] {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return [.utf8] }
        if bytes.starts(with: [0xFF, 0xFE]) { return [.utf16LittleEndian] }
        if bytes.starts(with: [0xFE, 0xFF]) { return [.utf16BigEndian] }
        return []
    }

    private static func chineseEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return String.Encoding(rawValue: raw)
    }

    private static func unique(_ encodings: [String.Encoding]) -> [String.Encoding] {
        var seen = Set<UInt>()
        return encodings.filter { seen.insert($0.rawValue).inserted }
    }
}
