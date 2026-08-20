import AppKit
import SwiftUI

struct DocumentEditorView: NSViewRepresentable {
    let documentID: String
    let text: String
    let preferences: ReaderPreferences
    let palette: ReaderPalette
    let onTextChange: (String) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange, onExit: onExit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true

        let textView = EditorTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
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
        textView.font = preferences.fontFamily.font(size: preferences.fontSize)
        textView.textColor = palette.nsText
        textView.insertionPointColor = palette.nsAccent
        textView.textContainerInset = NSSize(width: preferences.pageMargin, height: 34)

        if context.coordinator.documentID != documentID {
            context.coordinator.documentID = documentID
            context.coordinator.isApplying = true
            textView.string = text
            context.coordinator.isApplying = false
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: EditorTextView?
        weak var scrollView: NSScrollView?
        var documentID: String?
        var isApplying = false
        var onTextChange: (String) -> Void
        var onExit: () -> Void

        init(onTextChange: @escaping (String) -> Void, onExit: @escaping () -> Void) {
            self.onTextChange = onTextChange
            self.onExit = onExit
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
    var onDoubleClick: (() -> Void)?
    var onActivate: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
