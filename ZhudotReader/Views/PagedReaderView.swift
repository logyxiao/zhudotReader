import AppKit
import SwiftUI

/// Read and edit share the same text storage, containers and visible text views.
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
    var isEditing = false
    var draftText = ""
    var draftEpoch = 0
    var onTextChange: ((String) -> Void)? = nil
    var onExit: (() -> Void)? = nil
    var onAttributedTextChange: ((NSAttributedString) -> Void)? = nil
    @State private var pageIndex = 0
    @State private var pageCount = 1
    @State private var turnRequest: ReaderKeyboardRequest?

    var body: some View {
        GeometryReader { geometry in
            let spread = geometry.size.width >= 760 ? 2 : 1
            VStack(spacing: 0) {
                EditablePageCanvas(
                    document: document, preferences: preferences, palette: palette,
                    locationRequest: locationRequest, keyboardRequest: turnRequest ?? keyboardRequest,
                    searchHighlight: searchHighlight, isEditing: isEditing, draftText: draftText,
                    onTextChange: onTextChange, onDoubleClick: onDoubleClick,
                    onActivate: onActivate, onExit: onExit, onProgress: onProgress,
                    onAttributedTextChange: onAttributedTextChange,
                    onPages: { index, count in pageIndex = index; pageCount = count }
                )
                HStack {
                    Button { turnRequest = ReaderKeyboardRequest(action: .viewportBackward) } label: {
                        Label("上一页", systemImage: "chevron.left")
                    }
                    .disabled(pageIndex == 0)
                    Spacer()
                    Text(spread == 2 && pageIndex + 1 < pageCount
                         ? "\(pageIndex + 1)–\(min(pageIndex + spread, pageCount)) / \(pageCount)"
                         : "\(pageIndex + 1) / \(pageCount)")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.faint)
                    Spacer()
                    Button { turnRequest = ReaderKeyboardRequest(action: .viewportForward) } label: {
                        Label("下一页", systemImage: "chevron.right")
                    }
                    .disabled(pageIndex + spread >= pageCount)
                }
                .buttonStyle(.plain).font(.custom("Songti SC", size: 11))
                .foregroundStyle(palette.muted).padding(.horizontal, 24).frame(height: 40)
            }
            .onChange(of: keyboardRequest) { _, request in turnRequest = request }
        }
    }
}

private struct EditablePageCanvas: NSViewRepresentable {
    let document: ReaderDocument
    let preferences: ReaderPreferences
    let palette: ReaderPalette
    let locationRequest: ReadingLocationRequest
    let keyboardRequest: ReaderKeyboardRequest?
    let searchHighlight: SearchHighlightRequest
    let isEditing: Bool
    let draftText: String
    let onTextChange: ((String) -> Void)?
    let onDoubleClick: (() -> Void)?
    let onActivate: (() -> Void)?
    let onExit: (() -> Void)?
    let onProgress: (Int) -> Void
    let onAttributedTextChange: ((NSAttributedString) -> Void)?
    let onPages: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PageCanvasView {
        let view = PageCanvasView()
        context.coordinator.host = view
        view.onResize = { [weak coordinator = context.coordinator] in coordinator?.scheduleLayout() }
        return view
    }
    func updateNSView(_ view: PageCanvasView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var host: PageCanvasView?
        let editingUndoManager = UndoManager()
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        var input: EditablePageCanvas?
        var documentID: String?
        var style: ReaderPreferences?
        var containers: [NSTextContainer] = []
        var ranges: [NSRange] = []
        var views: [Int: DoubleClickAwareTextView] = [:]
        var pageIndex = 0
        var spread = 1
        var pageSize = CGSize.zero
        var locationID: UUID?
        var keyboardID: UUID?
        var highlightID: UUID?
        var pendingOffset: Int?
        var pendingCaret: NSRange?
        var applying = false
        var scheduled = false
        var wasEditing = false

        override init() { super.init(); storage.addLayoutManager(manager) }

        func update(_ next: EditablePageCanvas) {
            let changedDocument = documentID != next.document.id
            let entering = next.isEditing && !wasEditing
            input = next
            guard !views.values.contains(where: { $0.hasMarkedText() }) else { return }
            let desired = next.isEditing ? next.draftText : next.document.displayText
            applying = true
            if changedDocument || storage.string != desired {
                let oldSelection = focusedView?.selectedRange()
                if next.isEditing && next.document.format == .text {
                    storage.setAttributedString(NSAttributedString(string: desired, attributes: attributes))
                } else { storage.setAttributedString(next.document.attributedText) }
                if changedDocument {
                    editingUndoManager.removeAllActions()
                    pendingOffset = next.locationRequest.offset
                } else if let selection = oldSelection {
                    pendingCaret = NSRange(location: min(selection.location, storage.length), length: 0)
                }
            } else if style != next.preferences {
                if next.document.format == .text { storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length)) }
                else { storage.setAttributedString(next.document.attributedText) }
            }
            applying = false
            documentID = next.document.id; style = next.preferences
            if locationID != next.locationRequest.id { pendingOffset = next.locationRequest.offset }
            locationID = next.locationRequest.id
            if keyboardID != next.keyboardRequest?.id, let action = next.keyboardRequest?.action {
                let delta = action == .viewportBackward ? -spread : spread
                pageIndex = max(0, min(max(0, ranges.count - 1), pageIndex + delta))
                pageIndex -= pageIndex % spread
                if ranges.indices.contains(pageIndex) { next.onProgress(ranges[pageIndex].location) }
            }
            keyboardID = next.keyboardRequest?.id
            if highlightID != next.searchHighlight.id, let current = next.searchHighlight.current {
                pendingOffset = current.location
            }
            highlightID = next.searchHighlight.id
            wasEditing = next.isEditing
            layoutPages()
            if entering {
                let view = views.values.first(where: { $0.pendingEditSelection != nil }) ?? focusedView ?? views[pageIndex]
                if let view {
                    var fallback = view.selectedRange()
                    if let index = views.first(where: { $0.value === view })?.key,
                       ranges.indices.contains(index), !NSLocationInRange(fallback.location, ranges[index]) {
                        fallback = NSRange(location: ranges[index].location, length: 0)
                    }
                    view.finishEnteringEdit(fallback: fallback)
                }
            }
        }

        var attributes: [NSAttributedString.Key: Any] {
            guard let input else { return [:] }
            return DocumentLoader().baseAttributes(preferences: input.preferences, palette: input.palette)
        }
        var focusedView: DoubleClickAwareTextView? {
            guard let view = host?.window?.firstResponder as? DoubleClickAwareTextView,
                  views.values.contains(where: { $0 === view }) else { return nil }
            return view
        }
        func scheduleLayout() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.layoutPages()
            }
        }

        func layoutPages() {
            guard let host, let input, host.bounds.width > 0, host.bounds.height > 0,
                  !views.values.contains(where: { $0.hasMarkedText() }) else { return }
            let previousAnchor = ranges.indices.contains(pageIndex) ? ranges[pageIndex].location : 0
            let nextSpread = host.bounds.width >= 760 ? 2 : 1
            let inset = max(28, input.preferences.pageMargin * 0.55)
            let columnWidth = (host.bounds.width - CGFloat(nextSpread - 1)) / CGFloat(nextSpread)
            let size = CGSize(width: max(1, columnWidth - inset * 2), height: max(1, host.bounds.height - 48))
            let resized = size != pageSize || spread != nextSpread
            if resized {
                pendingOffset = pendingOffset ?? previousAnchor
                pageSize = size; spread = nextSpread
                for container in containers { container.containerSize = size }
            }
            ranges = []
            var covered = 0
            var index = 0
            repeat {
                if index == containers.count {
                    let container = NSTextContainer(size: size)
                    container.lineFragmentPadding = 0
                    container.widthTracksTextView = false
                    container.heightTracksTextView = false
                    manager.addTextContainer(container)
                    containers.append(container)
                }
                let container = containers[index]
                manager.ensureLayout(for: container)
                let glyphs = manager.glyphRange(for: container)
                let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                ranges.append(range)
                covered = NSMaxRange(range)
                index += 1
                if range.length == 0 { break }
            } while covered < storage.length
            while containers.count > ranges.count {
                let last = containers.count - 1
                views.removeValue(forKey: last)?.removeFromSuperview()
                manager.removeTextContainer(at: last); containers.removeLast()
            }
            if let caret = pendingCaret { pendingOffset = caret.location }
            if let offset = pendingOffset {
                let page = ranges.firstIndex { NSLocationInRange(offset, $0) } ?? max(0, ranges.count - 1)
                pageIndex = page - page % spread
                pendingOffset = nil
            }
            pageIndex = min(pageIndex, max(0, ranges.count - 1))
            pageIndex -= pageIndex % spread
            let visible = Set(pageIndex..<min(pageIndex + spread, ranges.count))
            for index in Array(views.keys) where !visible.contains(index) {
                views.removeValue(forKey: index)?.removeFromSuperview()
            }
            for index in visible.sorted() {
                let view: DoubleClickAwareTextView
                if let existing = views[index] { view = existing }
                else {
                    view = DoubleClickAwareTextView(frame: .zero, textContainer: containers[index])
                    view.editingUndoManager = editingUndoManager
                    view.isRichText = true; view.isSelectable = true
                    view.isVerticallyResizable = false; view.isHorizontallyResizable = false
                    view.textContainerInset = .zero
                    view.delegate = self
                    host.addSubview(view); views[index] = view
                }
                view.frame = CGRect(x: CGFloat(index - pageIndex) * (columnWidth + 1) + inset,
                                    y: 24, width: size.width, height: size.height)
                view.backgroundColor = input.palette.nsPaper
                view.configureInlineEditing(input.isEditing, attributes: attributes, palette: input.palette, preservesFormatting: input.document.format == .markdown)
                view.onDoubleClick = input.onDoubleClick; view.onActivate = input.onActivate; view.onExit = input.onExit
            }
            host.paper = input.palette.nsPaper
            host.divider = NSColor(input.palette.border)
            host.showsDivider = spread == 2; host.needsDisplay = true
            if let caret = pendingCaret {
                let index = ranges.firstIndex { NSLocationInRange(caret.location, $0) } ?? ranges.count - 1
                if let view = views[index] {
                    view.setSelectedRange(caret)
                    host.window?.makeFirstResponder(view)
                }
                pendingCaret = nil
            }
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
            for range in input.searchHighlight.neighbors + [input.searchHighlight.current].compactMap({ $0 }) {
                let safe = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
                if safe.length > 0 {
                    manager.addTemporaryAttribute(.backgroundColor,
                        value: range == input.searchHighlight.current ? input.palette.nsFindCurrent : input.palette.nsFindWash,
                        forCharacterRange: safe)
                }
            }
            let count = ranges.count, currentPage = pageIndex
            DispatchQueue.main.async { input.onPages(currentPage, count) }
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let view = notification.object as? DoubleClickAwareTextView, view.isEditable, !view.hasMarkedText() else { return }
            if let onAttributedTextChange = input?.onAttributedTextChange { onAttributedTextChange(storage) }
            else { input?.onTextChange?(storage.string) }
            if !view.hasMarkedText() {
                pendingCaret = view.selectedRange()
                input?.onProgress(pendingCaret?.location ?? 0)
                scheduleLayout()
            }
        }
    }
}

private final class PageCanvasView: NSView {
    override var isFlipped: Bool { true }
    var onResize: (() -> Void)?
    var paper = NSColor.textBackgroundColor
    var divider = NSColor.separatorColor
    var showsDivider = false
    private var previousSize = CGSize.zero
    override func layout() {
        super.layout()
        if previousSize != bounds.size { previousSize = bounds.size; onResize?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        paper.setFill(); bounds.fill()
        if showsDivider { divider.setFill(); NSRect(x: bounds.midX - 0.5, y: 24, width: 1, height: max(0, bounds.height - 48)).fill() }
    }
}
