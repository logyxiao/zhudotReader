import AppKit
import SwiftUI

@main struct EditingInteractionSmoke {
    @MainActor static func tick(_ seconds: TimeInterval = 0.3) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor static func textViews(_ view: NSView) -> [DoubleClickAwareTextView] {
        (view as? DoubleClickAwareTextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
    }
    @MainActor static func pageRange(_ view: NSTextView) -> NSRange {
        let manager = view.layoutManager!, container = view.textContainer!
        return manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
    }
    @MainActor static func click(_ target: DoubleClickAwareTextView, window: NSWindow) -> Int {
        let visible = target.visibleRect
        let point = NSPoint(x: target.textContainerOrigin.x + min(90, visible.width * 0.3),
                            y: visible.minY + min(130, visible.height * 0.45))
        let expected = target.characterIndexForInsertion(at: point)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: target.convert(point, to: nil),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                      clickCount: 2, pressure: 1)!
        // Exercise the real double-click handler and ReaderStore/ReaderView routing,
        // not an artificial change to a fixture's isEditing boolean.
        target.mouseDown(with: event)
        return expected
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zhudot-interaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let markdownURL = folder.appendingPathComponent("roundtrip.md")
        let markdown = "# 标题\n\n正文 **加粗** 与 *斜体* 和 [链接](https://example.com/a?q=1) 与 `代码`。\n> 引用\n- 列表\n---\n"
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        let markdownDocument = try DocumentLoader().load(url: markdownURL, preferences: ReaderPreferences(), palette: .palette(for: .day))
        precondition(MarkdownDraftWriter.source(from: markdownDocument.attributedText) == markdown, "Untouched Markdown changed")
        for (find, replacement) in [("加粗", "加粗新字😀"), ("加粗", ""), ("链接", "新链接"), ("代码", "代`码"), ("正文", "正文 * [x](y) <tag> #"), ("斜体", "斜\n体")] {
            let edited = NSMutableAttributedString(attributedString: markdownDocument.attributedText)
            let range = (edited.string as NSString).range(of: find)
            edited.replaceCharacters(in: range, with: replacement)
            let encoded = MarkdownDraftWriter.source(from: edited)
            let decoded = DocumentLoader().restyle(markdownDocument, source: encoded, preferences: ReaderPreferences(), palette: .palette(for: .day))
            precondition(decoded.displayText == edited.string, "Markdown round trip failed: \(find) -> \(replacement)\n\(encoded)")
            precondition(encoded.contains("https://example.com/a?q=1"), "Unrelated link target lost")
        }
        print("PASS Markdown source preservation, emphasis/link/code edits, Unicode, literal syntax, paragraph splitting")
        for ext in ["txt", "md"] {
            for mode in [ReaderMode.scroll, .paged] {
                for comparison in [false, true] {
                    let store = ReaderStore(restoreSession: false)
                    store.preferences.mode = mode
                    let source = (ext == "md" ? "# 第一章\n\n" : "第一章\n\n") + (1...100).map { index in
                        ext == "md"
                        ? "第\(index)段，窗外的风吹过树梢。**加粗文字**、*斜体*与[链接](https://example.com)要保留。中文和 emoji 😀，阅读编辑的换行位置一致。"
                        : "第\(index)段，窗外的风吹过树梢。中文和 emoji 😀，阅读编辑的换行位置应当一致。这里还有一些足够长的文字，让测试能覆盖正文中段的实际双击事件。"
                    }.joined(separator: "\n")
                    let leftURL = folder.appendingPathComponent("主文.\(ext)")
                    let rightURL = folder.appendingPathComponent("对照.\(ext)")
                    try source.write(to: leftURL, atomically: true, encoding: .utf8)
                    try source.write(to: rightURL, atomically: true, encoding: .utf8)
                    store.libraries = [LibrarySource(id: folder.path, name: "测试书库", url: folder)]
                    store.primaryLibraryID = folder.path
                    store.comparisonLibraryID = comparison ? folder.path : nil
                    store.activeLibraryID = folder.path
                    store.currentDocument = try DocumentLoader().load(url: leftURL, preferences: store.preferences, palette: store.palette)
                    if comparison { store.comparisonDocument = try DocumentLoader().load(url: rightURL, preferences: store.preferences, palette: store.palette) }
                    store.columnVisibility = .detailOnly
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let host = NSHostingView(rootView: ContentView().environment(store))
                    window.contentView = host; window.makeKeyAndOrderFront(nil)
                    tick(); tick()
                    store.locationRequest = ReadingLocationRequest(offset: 2300)
                    store.comparisonLocationRequest = ReadingLocationRequest(offset: 2600)
                    tick(); tick()
                    let before = textViews(host).sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
                    let expectedCount = mode == .paged || comparison ? 2 : 1
                    precondition(before.count == expectedCount, "Unexpected initial column count: \(before.count)")
                    let target = before.last!
                    let identities = Set(before.map(ObjectIdentifier.init))
                    let frames = before.map { $0.convert($0.bounds, to: host) }
                    let page = pageRange(target)
                    let viewport = target.enclosingScrollView?.contentView.bounds.origin
                    let originalText = target.string
                    let attributes = NSAttributedString(attributedString: target.attributedString())
                    let caret = click(target, window: window)
                    precondition(caret > 0, "Fixture did not click middle of document")
                    tick(); tick()
                    let after = textViews(host).sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
                    precondition(store.isEditingContent && store.editingPane == (comparison ? .comparison : .primary))
                    precondition(store.preferences.mode == mode && store.showsComparisonLayout == comparison)
                    precondition(Set(after.map(ObjectIdentifier.init)) == identities, "Double click replaced reader views (\(ext))")
                    precondition(after.map { $0.convert($0.bounds, to: host) } == frames, "Double click changed column geometry")
                    precondition(target.enclosingScrollView?.contentView.bounds.origin == viewport, "Double click jumped viewport")
                    precondition(pageRange(target) == page, "Double click changed pages")
                    precondition(target.attributedString().isEqual(to: attributes), "Double click changed typography")
                    precondition(target.selectedRange().location == caret, "Double click lost clicked caret: \(caret) vs \(target.selectedRange())")
                    let inserted = "原位修改😀"
                    target.insertText(inserted, replacementRange: target.selectedRange())
                    tick()
                    var expected = (originalText as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: inserted)
                    precondition(store.draftDocument?.displayText == expected)
                    if ext == "md" {
                        precondition(store.draftText.hasPrefix("# 第一章\n\n"), "Markdown heading was flattened")
                        precondition(store.draftText.contains("https://example.com"), "Link destination lost")
                    }
                    store.saveDraftNow(); tick(0.6)
                    let savedURL = comparison ? rightURL : leftURL
                    let saved = try DocumentLoader().load(url: savedURL, preferences: store.preferences, palette: store.palette)
                    precondition(saved.displayText == expected, "Saved document differs from visible edit")
                    if comparison {
                        let untouched = try String(contentsOf: leftURL, encoding: .utf8)
                        precondition(untouched == source, "Edited the wrong pane")
                    }
                    if comparison {
                        // Switch to the other book before the debounce save fires.
                        let selection = target.selectedRange()
                        target.insertText("右栏待保存", replacementRange: selection)
                        expected = (expected as NSString).replacingCharacters(in: selection, with: "右栏待保存")
                        let leftView = after.first!
                        let leftCaret = click(leftView, window: window)
                        tick(); tick()
                        precondition(store.isEditingContent && store.editingPane == .primary, "Failed to switch editing panes")
                        precondition(leftView.selectedRange().location == leftCaret, "Pane switch lost clicked caret")
                        precondition(Set(textViews(host).map(ObjectIdentifier.init)) == identities, "Pane switch replaced a column")
                        let rightSaved = try DocumentLoader().load(url: rightURL, preferences: store.preferences, palette: store.palette)
                        precondition(rightSaved.displayText == expected, "Pane switch lost unsaved right edits")
                    }
                    store.exitEditMode(); tick(); tick()
                    precondition(!store.isEditingContent && textViews(host).count == expectedCount)
                    precondition(store.document(in: comparison ? .comparison : .primary)?.displayText == expected)
                    window.close()
                    print("PASS actual ContentView double click: \(ext), \(mode), comparison=\(comparison), caret=\(caret), columns=\(expectedCount), save round-trip")
                }
            }
        }
    }
}
