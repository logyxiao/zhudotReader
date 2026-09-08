import AppKit
import SwiftUI

struct ScrollReaderView: NSViewRepresentable {
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

    private var styleSignature: String {
        "\(preferences.theme.rawValue)-\(preferences.fontFamily.rawValue)-\(preferences.fontSize)-\(preferences.lineHeight.rawValue)-\(preferences.pageMargin)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ReaderScrollView()
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = DoubleClickAwareTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: preferences.pageMargin, height: 34)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        scrollView.applyReaderScroller(palette: palette)

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.observeScroll()
        textView.onDoubleClick = onDoubleClick
        textView.onActivate = onActivate
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.onProgress = onProgress
        textView.onDoubleClick = onDoubleClick
        textView.onActivate = onActivate
        context.coordinator.lineScrollDistance = CGFloat(
            preferences.fontSize * preferences.lineHeight.rawValue
        )
        scrollView.backgroundColor = palette.nsPaper
        scrollView.applyReaderScroller(palette: palette)
        textView.backgroundColor = palette.nsPaper
        textView.textContainerInset = NSSize(width: preferences.pageMargin, height: 34)

        let coordinator = context.coordinator
        coordinator.onTextChange = onTextChange
        coordinator.onAttributedTextChange = onAttributedTextChange
        textView.onExit = onExit
        let attributes = DocumentLoader().baseAttributes(preferences: preferences, palette: palette)
        let entering = isEditing && !coordinator.wasEditing
        textView.configureInlineEditing(isEditing, attributes: attributes, palette: palette, preservesFormatting: document.format == .markdown)
        let changedDocument = coordinator.documentID != document.id
        let changedStyle = coordinator.styleSignature != styleSignature
        let desired = isEditing ? draftText : document.displayText
        if changedDocument || (!textView.hasMarkedText() && textView.string != desired) {
            coordinator.isRestoring = true
            let selection = textView.selectedRange()
            let origin = scrollView.contentView.bounds.origin
            if isEditing && document.format == .text {
                textView.textStorage?.setAttributedString(NSAttributedString(string: desired, attributes: attributes))
            } else {
                textView.textStorage?.setAttributedString(document.attributedText)
            }
            if changedDocument {
                textView.undoManager?.removeAllActions()
                DispatchQueue.main.async { coordinator.restore(locationRequest.offset) }
            } else {
                textView.setSelectedRange(NSRange(location: min(selection.location, (desired as NSString).length), length: 0))
                scrollView.contentView.scroll(to: origin)
                DispatchQueue.main.async { coordinator.isRestoring = false }
            }
        } else if changedStyle && !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            let origin = scrollView.contentView.bounds.origin
            if document.format == .text {
                textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (desired as NSString).length))
            } else {
                textView.textStorage?.setAttributedString(document.attributedText)
            }
            textView.setSelectedRange(selection)
            scrollView.contentView.scroll(to: origin)
        } else if coordinator.locationRequestID != locationRequest.id {
            coordinator.restore(locationRequest.offset)
        }
        coordinator.documentID = document.id
        if !textView.hasMarkedText() { coordinator.styleSignature = styleSignature }
        coordinator.wasEditing = isEditing
        if entering {
            var fallback = textView.selectedRange()
            if let manager = textView.layoutManager, let container = textView.textContainer {
                let rect = textView.visibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
                let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
                let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                if !NSLocationInRange(fallback.location, visible) { fallback = NSRange(location: visible.location, length: 0) }
            }
            textView.finishEnteringEdit(fallback: fallback)
        }
        context.coordinator.locationRequestID = locationRequest.id

        if context.coordinator.keyboardRequestID != keyboardRequest?.id {
            context.coordinator.keyboardRequestID = keyboardRequest?.id
            if let action = keyboardRequest?.action {
                context.coordinator.handle(action)
            }
        }

        if context.coordinator.highlightID != searchHighlight.id {
            context.coordinator.highlightID = searchHighlight.id
            context.coordinator.apply(searchHighlight, palette: palette)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var wasEditing = false
        var onTextChange: ((String) -> Void)?
        var onAttributedTextChange: ((NSAttributedString) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let textView, textView.isEditable, !textView.hasMarkedText() else { return }
            if let onAttributedTextChange { onAttributedTextChange(textView.attributedString()) }
            else { onTextChange?(textView.string) }
            reportProgress()
        }
        weak var textView: DoubleClickAwareTextView?
        weak var scrollView: NSScrollView?
        var documentID: String?
        var styleSignature: String?
        var locationRequestID: UUID?
        var keyboardRequestID: UUID?
        var highlightID: UUID?
        var onProgress: (Int) -> Void
        var isRestoring = false
        var lineScrollDistance: CGFloat = 35
        private var observer: NSObjectProtocol?

        init(onProgress: @escaping (Int) -> Void) {
            self.onProgress = onProgress
        }

        func observeScroll() {
            guard let clipView = scrollView?.contentView else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.reportProgress()
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        func restore(_ offset: Int) {
            guard let textView else { return }
            isRestoring = true
            let safeOffset = min(max(0, offset), textView.string.utf16.count)
            textView.scrollRangeToVisible(NSRange(location: safeOffset, length: 0))
            DispatchQueue.main.async { [weak self] in self?.isRestoring = false }
        }

        func handle(_ action: ReaderKeyboardAction) {
            guard let scrollView else { return }
            let distance: CGFloat
            switch action {
            case .viewportBackward: distance = -scrollView.contentView.bounds.height
            case .viewportForward: distance = scrollView.contentView.bounds.height
            case .lineBackward: distance = -lineScrollDistance
            case .lineForward: distance = lineScrollDistance
            }
            scroll(by: distance)
        }

        func apply(_ highlight: SearchHighlightRequest, palette: ReaderPalette) {
            textView?.applySearchHighlights(
                current: highlight.current,
                neighbors: highlight.neighbors,
                wash: palette.nsFindWash,
                active: palette.nsFindCurrent
            )
        }

        private func scroll(by distance: CGFloat) {
            guard let scrollView, let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            let maximumY = max(0, documentView.bounds.height - clipView.bounds.height)
            let targetY = min(max(0, clipView.bounds.minY + distance), maximumY)
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }

        private func reportProgress() {
            guard !isRestoring,
                  let textView,
                  let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            guard layoutManager.numberOfGlyphs > 0 else { onProgress(0); return }
            let point = NSPoint(x: 2, y: max(0, scrollView.contentView.bounds.minY - textView.textContainerOrigin.y))
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            let character = layoutManager.characterIndexForGlyph(at: min(glyph, layoutManager.numberOfGlyphs - 1))
            onProgress(character)
        }
    }
}

final class ReaderScrollView: NSScrollView {
    override func tile() {
        // AppKit may adopt the system's legacy style when a view enters a window.
        // Keep the overlay policy stable before computing the text container width.
        if scrollerStyle != .overlay { scrollerStyle = .overlay }
        super.tile()
    }
}

final class ReaderScroller: NSScroller {
    private var knobColor = NSColor(white: 0.35, alpha: 0.34)
    private var activeKnobColor = NSColor(white: 0.28, alpha: 0.55)

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        8
    }

    func apply(_ palette: ReaderPalette) {
        let nextKnob = palette.nsScrollerKnob
        let nextActive = palette.nsScrollerKnobActive
        guard !knobColor.isEqual(nextKnob) || !activeKnobColor.isEqual(nextActive) else { return }
        knobColor = nextKnob
        activeKnobColor = nextActive
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        var knob = rect(for: .knob)
        guard knob.height > 1, knob.width > 1 else { return }

        let thickness: CGFloat = 3
        knob.origin.x = bounds.midX - thickness / 2
        knob.origin.y += 2
        knob.size.width = thickness
        knob.size.height = max(12, knob.height - 4)

        (isHighlighted ? activeKnobColor : knobColor).setFill()
        NSBezierPath(roundedRect: knob, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}

extension NSScrollView {
    func applyReaderScroller(palette: ReaderPalette) {
        scrollerStyle = .overlay
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true

        if let scroller = verticalScroller as? ReaderScroller {
            scroller.apply(palette)
            tile()
            return
        }

        let scroller = ReaderScroller()
        scroller.controlSize = .mini
        scroller.scrollerStyle = .overlay
        scroller.apply(palette)
        verticalScroller = scroller
        tile()
    }
}

extension NSTextView {
    func applySearchHighlights(
        current: NSRange?,
        neighbors: [NSRange],
        wash: NSColor,
        active: NSColor
    ) {
        let length = (string as NSString).length
        let full = NSRange(location: 0, length: length)
        layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        guard length > 0 else { return }

        func clamped(_ range: NSRange) -> NSRange? {
            guard range.location < length else { return nil }
            let length = min(range.length, length - range.location)
            guard length > 0 else { return nil }
            return NSRange(location: range.location, length: length)
        }

        for range in neighbors {
            if let range = clamped(range) {
                layoutManager?.addTemporaryAttribute(.backgroundColor, value: wash, forCharacterRange: range)
            }
        }
        if let current, let range = clamped(current) {
            layoutManager?.addTemporaryAttribute(.backgroundColor, value: active, forCharacterRange: range)
            setSelectedRange(range)
            scrollRangeToVisible(range)
        }
    }
}
