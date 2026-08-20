import AppKit
import SwiftUI

enum ReaderKeyboardAction: Equatable {
    case viewportBackward
    case viewportForward
    case lineBackward
    case lineForward
}

struct ReaderKeyboardRequest: Equatable {
    let id = UUID()
    let action: ReaderKeyboardAction
}

struct ReaderView: View {
    @Environment(ReaderStore.self) private var store
    let document: ReaderDocument
    let pane: ReaderPane
    @State private var keyboardRequest: ReaderKeyboardRequest?

    var body: some View {
        VStack(spacing: 0) {
            readerHeader
            Divider().overlay(store.palette.border)

            Group {
                if isEditing {
                    DocumentEditorView(
                        documentID: document.id,
                        text: store.draftText,
                        preferences: store.preferences,
                        palette: store.palette,
                        onTextChange: store.updateDraft,
                        onExit: store.exitEditMode
                    )
                    .id("edit-\(document.id)")
                } else if store.preferences.mode == .scroll {
                    ScrollReaderView(
                        document: document,
                        preferences: store.preferences,
                        palette: store.palette,
                        locationRequest: store.locationRequest(in: pane),
                        keyboardRequest: keyboardRequest,
                        onProgress: { store.updateReadingOffset($0, in: pane) },
                        onDoubleClick: { store.enterEditMode(pane) },
                        onActivate: { store.activateReader(pane) }
                    )
                    .id("scroll-\(document.id)")
                } else {
                    PagedReaderView(
                        document: document,
                        preferences: store.preferences,
                        palette: store.palette,
                        locationRequest: store.locationRequest(in: pane),
                        keyboardRequest: keyboardRequest,
                        onProgress: { store.updateReadingOffset($0, in: pane) },
                        onDoubleClick: { store.enterEditMode(pane) },
                        onActivate: { store.activateReader(pane) }
                    )
                    .id("paged-\(document.id)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(store.palette.border)
            readerStatus
        }
        .background(store.palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isActive ? store.palette.accent.opacity(0.6) : store.palette.border,
                    lineWidth: isActive && store.showsComparisonLayout ? 1.5 : 1
                )
        }
        .shadow(color: Color.black.opacity(store.preferences.theme == .night ? 0.22 : 0.06), radius: 22, y: 10)
        .padding(.horizontal, store.preferences.mode == .scroll ? scrollHorizontalPadding : 20)
        .padding(.vertical, 18)
        .background(store.palette.canvas)
        .background {
            if !isEditing && isActive {
                ReaderKeyboardMonitor { key in
                    handleKeyboard(key)
                }
            }
        }
        .onExitCommand {
            if isEditing {
                store.exitEditMode()
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                store.activateReader(pane)
            }
        )
        .animation(.easeOut(duration: 0.18), value: store.preferences.mode)
        .animation(.easeOut(duration: 0.18), value: store.preferences.theme)
    }

    private var readerHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(store.palette.faint)
                    .lineLimit(1)
                Text(document.title)
                    .font(.custom("Songti SC", size: 18).weight(.semibold))
                    .foregroundStyle(store.palette.text)
                    .lineLimit(1)
            }
            Spacer()
            if store.showsComparisonLayout {
                Text(pane == .primary ? "主文" : "对照")
                    .font(.custom("Songti SC", size: 10).weight(.medium))
                    .foregroundStyle(isActive ? store.palette.accentDeep : store.palette.faint)
            }
            Text(isEditing ? "编辑" : (document.format == .markdown ? "MARKDOWN" : "TXT"))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(store.palette.accentDeep)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(store.palette.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .help(isEditing ? "Esc 退出编辑" : "双击正文进入编辑")
            if pane == .comparison {
                Button {
                    store.closeComparison()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.palette.faint)
                .help("关闭对照栏")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 62)
    }

    private var readerStatus: some View {
        HStack(spacing: 8) {
            if isEditing {
                Text(store.isDraftDirty ? "未保存" : "编辑中 · Esc 退出")
            } else if let chapter = store.chapter(in: pane) {
                Text(chapter.title)
                    .lineLimit(1)
            } else {
                Text("正文 · 双击进入编辑")
            }
            Spacer()
            Text("\((isEditing ? store.draftText as NSString : document.displayText as NSString).length.formatted()) 字符")
            if !isEditing {
                Text("·")
                Text("\(store.readingPercentage(in: pane))%")
            }
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundStyle(store.palette.faint)
        .padding(.horizontal, 20)
        .frame(height: 32)
    }

    private var scrollHorizontalPadding: CGFloat {
        if store.showsComparisonLayout { return 10 }
        return max(20, (NSScreen.main?.frame.width ?? 1280 - store.preferences.contentWidth) / 8)
    }

    private var isEditing: Bool {
        pane == store.editingPane && store.isEditingContent
    }

    private var isActive: Bool {
        store.activeReaderPane == pane
    }

    private func handleKeyboard(_ key: ReaderKey) -> Bool {
        if key == .pageUp || key == .pageDown {
            return store.moveDocument(by: key == .pageUp ? -1 : 1, in: pane)
        }

        let action: ReaderKeyboardAction?
        switch (store.preferences.mode, key) {
        case (.scroll, .left): action = .viewportBackward
        case (.scroll, .right): action = .viewportForward
        case (.scroll, .up): action = .lineBackward
        case (.scroll, .down): action = .lineForward
        case (.paged, .left): action = .viewportBackward
        case (.paged, .right): action = .viewportForward
        default: action = nil
        }
        guard let action else { return false }
        keyboardRequest = ReaderKeyboardRequest(action: action)
        return true
    }
}

enum ReaderKey: Equatable {
    case left
    case right
    case up
    case down
    case pageUp
    case pageDown

    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 126: self = .up
        case 125: self = .down
        case 116: self = .pageUp
        case 121: self = .pageDown
        default: return nil
        }
    }
}

private struct ReaderKeyboardMonitor: NSViewRepresentable {
    let onKey: (ReaderKey) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onKey: onKey)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        weak var hostView: NSView?
        var onKey: (ReaderKey) -> Bool
        private var monitor: Any?

        init(onKey: @escaping (ReaderKey) -> Bool) {
            self.onKey = onKey
        }

        func startMonitoring() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let window = hostView?.window,
                      event.window === window,
                      window.attachedSheet == nil,
                      !Self.isEditingText(in: window),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let key = ReaderKey(keyCode: event.keyCode),
                      onKey(key) else {
                    return event
                }
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private static func isEditingText(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder else { return false }
            if let textView = responder as? NSTextView {
                return textView.isEditable || textView.isFieldEditor
            }
            return responder is NSTextField
        }
    }
}
