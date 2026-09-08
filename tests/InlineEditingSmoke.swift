import AppKit
import SwiftUI
import Observation

@MainActor @Observable private final class EditingFixture {
    var editing = false
    var draft: String
    var document: ReaderDocument
    var request = ReadingLocationRequest(offset: 0)
    var preferences = ReaderPreferences()
    init() {
        let source = (1...80).map { "第\($0)段，窗外的风吹过树梢。中文输入与 emoji 😀 都应保留。这里有一些足够长的文字，用于检查换行和段落缩进。" }.joined(separator: "\n")
        draft = source
        document = ReaderDocument(id: "fixture", url: URL(fileURLWithPath: "/tmp/inline-fixture.txt"), title: "测试", format: .text, sourceText: source, displayText: source, attributedText: NSAttributedString(string: source, attributes: DocumentLoader().baseAttributes(preferences: ReaderPreferences(), palette: .palette(for: .day))), chapters: [], characterCount: (source as NSString).length, contentFingerprint: source.hashValue)
    }
}
private struct EditingFixtureView: View {
    let model: EditingFixture
    let paged: Bool
    var body: some View {
        if paged {
            PagedReaderView(document: model.document, preferences: model.preferences, palette: .palette(for: .day), locationRequest: model.request, keyboardRequest: nil, searchHighlight: .none, onProgress: { _ in }, isEditing: model.editing, draftText: model.draft, onTextChange: { model.draft = $0 })
        } else {
            ScrollReaderView(document: model.document, preferences: model.preferences, palette: .palette(for: .day), locationRequest: model.request, keyboardRequest: nil, searchHighlight: .none, onProgress: { _ in }, isEditing: model.editing, draftText: model.draft, onTextChange: { model.draft = $0 })
        }
    }
}

@main struct InlineEditingSmoke {
    @MainActor static func tick() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    @MainActor static func textViews(_ view: NSView) -> [DoubleClickAwareTextView] {
        (view as? DoubleClickAwareTextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        for (paged, width) in [(false, 1000.0), (false, 420.0), (true, 1000.0), (true, 420.0)] {
            let model = EditingFixture()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: EditingFixtureView(model: model, paged: paged))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            tick(); tick()
            // Toolbar entry on a later page must not leave an offscreen caret at zero.
            model.request = ReadingLocationRequest(offset: 1800)
            tick(); tick()
            model.editing = true
            tick()
            let toolbarView = textViews(host).first { $0.window?.firstResponder === $0 }
            precondition((toolbarView?.selectedRange().location ?? 0) > 0, "Toolbar entry placed caret at document start")
            model.editing = false
            model.request = ReadingLocationRequest(offset: 0)
            tick(); tick()
            let before = textViews(host).sorted { $0.frame.minX < $1.frame.minX }
            precondition(before.count == (paged && width >= 760 ? 2 : 1), "Unexpected columns")
            let ids = before.map(ObjectIdentifier.init)
            let frames = before.map(\.frame)
            let storage = before[0].attributedString().copy() as! NSAttributedString
            let first = before[0]
            window.makeFirstResponder(first)
            first.setSelectedRange(NSRange(location: 3, length: 0))
            model.editing = true
            tick()
            let after = textViews(host).sorted { $0.frame.minX < $1.frame.minX }
            precondition(after.map(ObjectIdentifier.init) == ids, "Entering edit replaced text views")
            precondition(after.map(\.frame) == frames, "Entering edit changed geometry")
            precondition(after[0].attributedString().isEqual(to: storage), "Entering edit changed typography")
            precondition(after.allSatisfy(\.isEditable))
            let original = model.draft
            first.insertText("新字😀", replacementRange: first.selectedRange())
            tick()
            precondition(model.draft == (original as NSString).replacingCharacters(in: NSRange(location: 3, length: 0), with: "新字😀"), "Edit changed unrelated text")
            first.undoManager?.undo()
            tick()
            precondition(model.draft == original, "Undo failed")
            first.setSelectedRange(NSRange(location: 3, length: 0))
            first.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: first.selectedRange())
            tick()
            precondition(model.draft == original, "Saved uncommitted input method composition")
            first.insertText("中", replacementRange: first.markedRange())
            tick()
            precondition(model.draft == (original as NSString).replacingCharacters(in: NSRange(location: 3, length: 0), with: "中"), "Input method commit failed")
            let committed = model.draft
            if paged {
                let current = textViews(host)[0]
                current.setSelectedRange(NSRange(location: 0, length: 0))
                window.makeFirstResponder(current)
                let insertion = String(repeating: "新增段落会跨页。\n", count: 50)
                current.insertText(insertion, replacementRange: current.selectedRange())
                tick(); tick()
                precondition(model.draft == insertion + committed, "Cross-page insertion lost text")
                precondition(textViews(host).contains { $0.window?.firstResponder === $0 }, "Cross-page edit lost focus")
            }
            window.close()
            print("PASS \(paged ? "paged" : "scroll") width=\(width): view identity, layout, typography, Unicode, undo, pagination")
        }
        let left = EditingFixture(), right = EditingFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HStack(spacing: 1) {
            EditingFixtureView(model: left, paged: false)
            EditingFixtureView(model: right, paged: false)
        })
        window.contentView = host; window.makeKeyAndOrderFront(nil); tick(); tick()
        let views = textViews(host)
        precondition(views.count == 2)
        let rightOriginal = right.draft, leftOriginal = left.draft
        left.editing = true; tick()
        window.makeFirstResponder(views[0])
        views[0].insertText("左栏", replacementRange: NSRange(location: 0, length: 0)); tick()
        precondition(left.draft == "左栏" + leftOriginal && right.draft == rightOriginal)
        right.editing = true; tick()
        window.makeFirstResponder(views[1])
        views[1].insertText("右栏", replacementRange: NSRange(location: 0, length: 0)); tick()
        views[1].undoManager?.undo(); tick()
        precondition(right.draft == rightOriginal && left.draft == "左栏" + leftOriginal, "Undo crossed reader panes")
        window.close()
        print("PASS comparison panes: independent contents and undo histories")
    }
}
