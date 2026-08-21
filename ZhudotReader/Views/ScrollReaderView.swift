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

    private var styleSignature: String {
        "\(preferences.theme.rawValue)-\(preferences.fontFamily.rawValue)-\(preferences.fontSize)-\(preferences.lineHeight.rawValue)-\(preferences.pageMargin)-\(document.contentFingerprint)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = DoubleClickAwareTextView(frame: .zero)
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

            if context.coordinator.documentID != document.id ||
                context.coordinator.styleSignature != styleSignature {
            context.coordinator.isRestoring = true
            textView.textStorage?.setAttributedString(document.attributedText)
            context.coordinator.documentID = document.id
            context.coordinator.styleSignature = styleSignature
            context.coordinator.highlightID = searchHighlight.id
            DispatchQueue.main.async {
                context.coordinator.restore(locationRequest.offset)
                context.coordinator.apply(searchHighlight, palette: palette)
            }
        } else if context.coordinator.locationRequestID != locationRequest.id {
            context.coordinator.restore(locationRequest.offset)
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

    final class Coordinator: NSObject {
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

            let visibleY = scrollView.contentView.bounds.minY + textView.textContainerInset.height
            let point = NSPoint(x: textView.textContainerInset.width + 2, y: visibleY)
            let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
            let character = layoutManager.characterIndexForGlyph(at: glyph)
            onProgress(character)
        }
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
            return
        }

        let scroller = ReaderScroller()
        scroller.controlSize = .mini
        scroller.scrollerStyle = .overlay
        scroller.apply(palette)
        verticalScroller = scroller
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
