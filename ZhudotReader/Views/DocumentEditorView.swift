import AppKit
import SwiftUI

struct DocumentEditorView: NSViewRepresentable {
    let documentID: String
    let text: String
    let preferences: ReaderPreferences
    let palette: ReaderPalette
    let draftEpoch: Int
    let searchHighlight: SearchHighlightRequest
    let onTextChange: (String) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange, onExit: onExit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ReaderScrollView()
        scrollView.drawsBackground = true

        let textView = EditorTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.usesFindPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: preferences.pageMargin, height: 34)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = preferences.fontFamily.font(size: preferences.fontSize)
        textView.textColor = palette.nsText
        textView.insertionPointColor = palette.nsAccent
        textView.delegate = context.coordinator
        textView.onExit = { [weak coordinator = context.coordinator] in
            coordinator?.onExit()
        }
        scrollView.documentView = textView
        scrollView.applyReaderScroller(palette: palette)

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onExit = onExit
        textView.onExit = { [weak coordinator = context.coordinator] in
            coordinator?.onExit()
        }

        scrollView.backgroundColor = palette.nsPaper
        scrollView.applyReaderScroller(palette: palette)
        textView.backgroundColor = palette.nsPaper
        let attributes = DocumentLoader().baseAttributes(preferences: preferences, palette: palette)
        if !textView.hasMarkedText() {
            textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: (textView.string as NSString).length))
            textView.typingAttributes = attributes
            textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        }
        textView.insertionPointColor = palette.nsAccent
        textView.textContainerInset = NSSize(width: preferences.pageMargin, height: 34)

        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
            context.coordinator.draftEpoch = draftEpoch
            context.coordinator.highlightID = searchHighlight.id
            context.coordinator.isApplying = true
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.coordinator.isApplying = false
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                context.coordinator.apply(searchHighlight, palette: palette)
            }
        } else if context.coordinator.draftEpoch != draftEpoch {
            context.coordinator.draftEpoch = draftEpoch
            context.coordinator.highlightID = searchHighlight.id
            let selected = textView.selectedRange()
            context.coordinator.isApplying = true
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.coordinator.isApplying = false
            if NSMaxRange(selected) <= (text as NSString).length {
                textView.setSelectedRange(selected)
            }
            context.coordinator.apply(searchHighlight, palette: palette)
        } else if context.coordinator.highlightID != searchHighlight.id {
            context.coordinator.highlightID = searchHighlight.id
            context.coordinator.apply(searchHighlight, palette: palette)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: EditorTextView?
        weak var scrollView: NSScrollView?
        var documentID: String?
        var draftEpoch = 0
        var highlightID: UUID?
        var isApplying = false
        var onTextChange: (String) -> Void
        var onExit: () -> Void

        init(onTextChange: @escaping (String) -> Void, onExit: @escaping () -> Void) {
            self.onTextChange = onTextChange
            self.onExit = onExit
        }

        func apply(_ highlight: SearchHighlightRequest, palette: ReaderPalette) {
            textView?.applySearchHighlights(
                current: highlight.current,
                neighbors: highlight.neighbors,
                wash: palette.nsFindWash,
                active: palette.nsFindCurrent
            )
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else { return }
            onTextChange(textView.string)
        }
    }
}

final class EditorTextView: NSTextView {
    var onExit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onExit?()
    }
}

final class DoubleClickAwareTextView: NSTextView {
    var editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }
    var onExit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onExit?() }

    private(set) var pendingEditSelection: NSRange?
    private var pendingEditOrigin: NSPoint?
    private var focusTransition = UUID()

    func configureInlineEditing(_ editing: Bool, attributes: [NSAttributedString.Key: Any], palette: ReaderPalette, preservesFormatting: Bool = false) {
        if isEditable != editing { isEditable = editing }
        allowsUndo = true
        usesFindBar = false
        usesFindPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        insertionPointColor = palette.nsAccent
        if !hasMarkedText(), !preservesFormatting || string.isEmpty { typingAttributes = attributes }
    }

    func finishEnteringEdit(fallback: NSRange) {
        let selection = pendingEditSelection ?? fallback
        let origin = pendingEditOrigin ?? enclosingScrollView?.contentView.bounds.origin
        pendingEditSelection = nil
        pendingEditOrigin = nil
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
        window?.makeFirstResponder(self)
        func restoreViewport() {
            if let origin, let scroll = enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        restoreViewport()
        let transition = UUID()
        focusTransition = transition
        // Becoming first responder can schedule another AppKit scroll. Preserve the
        // actual viewport after that pass too, without issuing a reader jump request.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditable, self.focusTransition == transition,
                  self.window?.firstResponder === self,
                  self.selectedRange().location == min(selection.location, length) else { return }
            if let origin, let scroll = self.enclosingScrollView {
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }

    // Documents are text files: paste text without importing another application's fonts.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    var onDoubleClick: (() -> Void)?
    var onActivate: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if event.clickCount == 2 && !isEditable {
            // Place the insertion point in the existing layout before enabling editing.
            let point = convert(event.locationInWindow, from: nil)
            pendingEditSelection = NSRange(location: characterIndexForInsertion(at: point), length: 0)
            pendingEditOrigin = enclosingScrollView?.contentView.bounds.origin
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
