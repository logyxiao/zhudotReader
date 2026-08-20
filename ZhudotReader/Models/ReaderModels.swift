import AppKit
import Foundation

enum DocumentFormat: String, Codable, Sendable {
    case text
    case markdown
}

enum LibraryNodeKind: String, Codable, Sendable {
    case folder
    case document
}

struct LibrarySource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
}

struct LibraryNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let kind: LibraryNodeKind
    let children: [LibraryNode]

    var documentCount: Int {
        kind == .document ? 1 : children.reduce(0) { $0 + $1.documentCount }
    }
}

struct Chapter: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let offset: Int
    let level: Int
}

struct ReaderDocument: Identifiable, @unchecked Sendable {
    let id: String
    let url: URL
    let title: String
    let format: DocumentFormat
    let sourceText: String
    let displayText: String
    let attributedText: NSAttributedString
    let chapters: [Chapter]
    let characterCount: Int
}

enum ReaderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case scroll
    case paged

    var id: String { rawValue }
    var label: String { self == .scroll ? "滚动" : "翻页" }
    var symbol: String { self == .scroll ? "scroll" : "rectangle.split.2x1" }
}

enum ReaderPane: String, Sendable {
    case primary
    case comparison
}

enum ReaderTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case day
    case protect
    case parchment
    case night

    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: "日间"
        case .protect: "护眼"
        case .parchment: "羊皮纸"
        case .night: "夜间"
        }
    }
}

enum ReaderFontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
    case serif
    case sans
    case kai

    var id: String { rawValue }
    var label: String {
        switch self {
        case .serif: "宋体"
        case .sans: "黑体"
        case .kai: "楷体"
        }
    }

    func font(size: CGFloat) -> NSFont {
        let name: String
        switch self {
        case .serif: name = "Songti SC"
        case .sans: name = "PingFang SC"
        case .kai: name = "Kaiti SC"
        }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

enum ReaderLineHeight: Double, Codable, CaseIterable, Identifiable, Sendable {
    case compact = 1.6
    case comfortable = 1.95
    case relaxed = 2.2

    var id: Double { rawValue }
    var label: String {
        switch self {
        case .compact: "紧凑"
        case .comfortable: "舒适"
        case .relaxed: "宽松"
        }
    }
}

struct ReaderPreferences: Codable, Equatable, Sendable {
    var theme: ReaderTheme = .day
    var mode: ReaderMode = .scroll
    var fontFamily: ReaderFontFamily = .serif
    var fontSize: Double = 18
    var lineHeight: ReaderLineHeight = .comfortable
    var contentWidth: Double = 760
    var pageMargin: Double = 56
}

struct ReadingProgress: Codable, Equatable, Sendable {
    var characterOffset: Int
    var updatedAt: Date
}

enum ReaderError: LocalizedError {
    case inaccessibleLibrary
    case unsupportedEncoding(String)
    case unreadableDocument(String)
    case invalidFileName
    case itemAlreadyExists(String)
    case invalidMove(String)
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .inaccessibleLibrary:
            "无法访问这个文件夹，请重新选择书库。"
        case let .unsupportedEncoding(name):
            "《\(name)》的文本编码无法识别。"
        case let .unreadableDocument(name):
            "无法读取《\(name)》。"
        case .invalidFileName:
            "名称不能为空，也不能包含“/”或“:”。"
        case let .itemAlreadyExists(name):
            "目标位置已经有一个名为“\(name)”的项目。"
        case let .invalidMove(message):
            message
        case let .fileOperationFailed(message):
            "文件操作失败：\(message)"
        }
    }
}
