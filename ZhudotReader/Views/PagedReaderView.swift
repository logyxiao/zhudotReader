import AppKit
import SwiftUI

struct PagedReaderView: View {
    let document: ReaderDocument
    let preferences: ReaderPreferences
    let palette: ReaderPalette
    let locationRequest: ReadingLocationRequest
    let keyboardRequest: ReaderKeyboardRequest?
    let searchHighlight: SearchHighlightRequest
    let onProgress: (Int) -> Void
    var onDoubleClick: (() -> Void)? = nil
    var onActivate: (() -> Void)? = nil

    @State private var pages: [NSRange] = []
    @State private var pageIndex = 0

    var body: some View {
        GeometryReader { geometry in
            let spread = geometry.size.width >= 760 ? 2 : 1
            let key = PageLayoutKey(
                documentID: document.id,
                contentLength: document.attributedText.length,
                contentFingerprint: document.contentFingerprint,
                width: rounded(geometry.size.width),
                height: rounded(geometry.size.height),
                spread: spread,
                fontSize: preferences.fontSize,
                lineHeight: preferences.lineHeight.rawValue,
                margin: preferences.pageMargin
            )

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<spread, id: \.self) { column in
                        pageColumn(at: pageIndex + column)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if column < spread - 1 {
                            Divider()
                                .overlay(palette.border)
                                .padding(.vertical, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Button {
                        turn(by: -spread, spread: spread)
                    } label: {
                        Label("上一页", systemImage: "chevron.left")
                    }
                    .disabled(pageIndex == 0)

                    Spacer()
                    Text(pageLabel(spread: spread))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    Spacer()

                    Button {
                        turn(by: spread, spread: spread)
                    } label: {
                        Label("下一页", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .disabled(pageIndex + spread >= pages.count)
                }
                .buttonStyle(.plain)
                .font(.custom("Songti SC", size: 11))
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 24)
                .frame(height: 40)
            }
            .task(id: key) {
                await paginate(size: geometry.size, spread: spread, key: key)
            }
            .onChange(of: locationRequest) { _, request in
                locate(request.offset, spread: spread)
            }
            .onChange(of: searchHighlight) { _, highlight in
                if let current = highlight.current {
                    locate(current.location, spread: spread)
                }
            }
            .onChange(of: keyboardRequest) { _, request in
                guard let request else { return }
                if request.action == .viewportBackward {
                    turn(by: -spread, spread: spread)
                } else if request.action == .viewportForward {
                    turn(by: spread, spread: spread)
                }
            }
        }
    }

    @ViewBuilder
    private func pageColumn(at index: Int) -> some View {
        if pages.indices.contains(index) {
            StaticPageTextView(
                attributedText: document.attributedText.attributedSubstring(from: pages[index]),
                backgroundColor: palette.nsPaper,
                washColor: palette.nsFindWash,
                activeColor: palette.nsFindCurrent,
                currentRange: relative(searchHighlight.current, in: pages[index]),
                neighborRanges: searchHighlight.neighbors.compactMap { relative($0, in: pages[index]) },
                onDoubleClick: onDoubleClick,
                onActivate: onActivate
            )
            .padding(.horizontal, max(28, preferences.pageMargin * 0.55))
            .padding(.vertical, 24)
        } else if pages.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func paginate(size: CGSize, spread: Int, key: PageLayoutKey) async {
        let controlsHeight: CGFloat = 40
        let dividerWidth: CGFloat = spread == 2 ? 1 : 0
        let columnWidth = max(220, (size.width - dividerWidth) / CGFloat(spread))
        let horizontalInset = max(28, preferences.pageMargin * 0.55)
        let pageSize = CGSize(
            width: max(120, columnWidth - horizontalInset * 2),
            height: max(120, size.height - controlsHeight - 48)
        )
        pages = []
        pageIndex = 0
        let result = await TextPaginationCache.shared.pages(
            for: key,
            document: document,
            pageSize: pageSize
        )
        guard !Task.isCancelled else { return }
        pages = result
        locate(locationRequest.offset, spread: spread)
    }

    private func locate(_ offset: Int, spread: Int) {
        guard !pages.isEmpty else { return }
        let found = pages.firstIndex { NSLocationInRange(offset, $0) || offset <= $0.location } ?? (pages.count - 1)
        pageIndex = max(0, found - found % spread)
    }

    private func relative(_ range: NSRange?, in page: NSRange) -> NSRange? {
        guard let range else { return nil }
        let intersection = NSIntersectionRange(range, page)
        guard intersection.length > 0 else { return nil }
        return NSRange(location: intersection.location - page.location, length: intersection.length)
    }

    private func turn(by amount: Int, spread: Int) {
        guard !pages.isEmpty else { return }
        let next = min(max(0, pageIndex + amount), max(0, pages.count - 1))
        pageIndex = next - next % spread
        if pages.indices.contains(pageIndex) {
            onProgress(pages[pageIndex].location)
        }
    }

    private func pageLabel(spread: Int) -> String {
        guard !pages.isEmpty else { return "正在排版" }
        let end = min(pageIndex + spread, pages.count)
        return spread == 2 && end > pageIndex + 1
            ? "\(pageIndex + 1)–\(end) / \(pages.count)"
            : "\(pageIndex + 1) / \(pages.count)"
    }

    private func rounded(_ value: CGFloat) -> Int {
        Int((value / 2).rounded() * 2)
    }
}

private struct PageLayoutKey: Hashable, Sendable {
    let documentID: String
    let contentLength: Int
    let contentFingerprint: Int
    let width: Int
    let height: Int
    let spread: Int
    let fontSize: Double
    let lineHeight: Double
    let margin: Double
}

private actor TextPaginationCache {
    static let shared = TextPaginationCache()

    private var cachedPages: [PageLayoutKey: [NSRange]] = [:]
    private var order: [PageLayoutKey] = []
    private let limit = 12

    func pages(
        for key: PageLayoutKey,
        document: ReaderDocument,
        pageSize: CGSize
    ) -> [NSRange] {
        if let pages = cachedPages[key] {
            touch(key)
            return pages
        }

        let pages = TextPaginator.paginate(document.attributedText, pageSize: pageSize)
        guard !Task.isCancelled else { return [] }
        cachedPages[key] = pages
        touch(key)
        while order.count > limit {
            cachedPages.removeValue(forKey: order.removeFirst())
        }
        return pages
    }

    private func touch(_ key: PageLayoutKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

private enum TextPaginator {
    static func paginate(_ text: NSAttributedString, pageSize: CGSize) -> [NSRange] {
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        var ranges: [NSRange] = []
        var coveredCharacters = 0

        while coveredCharacters < storage.length {
            guard !Task.isCancelled else { return [] }
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(for: container)
            let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard characterRange.length > 0 else { break }
            ranges.append(characterRange)
            coveredCharacters = NSMaxRange(characterRange)
        }
        return ranges
    }
}

private struct StaticPageTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let backgroundColor: NSColor
    let washColor: NSColor
    let activeColor: NSColor
    let currentRange: NSRange?
    let neighborRanges: [NSRange]
    var onDoubleClick: (() -> Void)? = nil
    var onActivate: (() -> Void)? = nil

    func makeNSView(context: Context) -> DoubleClickAwareTextView {
        let textView = DoubleClickAwareTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.onDoubleClick = onDoubleClick
        textView.onActivate = onActivate
        return textView
    }

    func updateNSView(_ textView: DoubleClickAwareTextView, context: Context) {
        textView.backgroundColor = backgroundColor
        textView.onDoubleClick = onDoubleClick
        textView.onActivate = onActivate
        if !textView.attributedString().isEqual(to: attributedText) {
            textView.textStorage?.setAttributedString(attributedText)
        }
        textView.applySearchHighlights(
            current: currentRange,
            neighbors: neighborRanges,
            wash: washColor,
            active: activeColor
        )
    }
}
