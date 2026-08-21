import AppKit
import SwiftUI

@main
struct ZhudotReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ReaderStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onAppear { IncomingDocuments.attach(store) }
                .onOpenURL { store.openIncomingURL($0) }
        .frame(minWidth: store.showsComparisonLayout ? 1180 : 900, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文稿…") {
                    store.chooseDocuments()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("新建 TXT 文件") {
                    store.createDocument(format: .text)
                }
                .keyboardShortcut("n")
                .disabled(store.libraryRootURL == nil)
                Button("新建 Markdown 文件") {
                    store.createDocument(format: .markdown)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.libraryRootURL == nil)
                Button("新建文件夹") {
                    store.createFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(store.libraryRootURL == nil)
                Divider()
                Button("添加书库…") {
                    store.chooseLibrary()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("保存") {
                    store.saveDraftNow()
                }
                .keyboardShortcut("s")
                .disabled(!store.isEditingContent)
            }
            CommandGroup(after: .pasteboard) {
                Button("查找…") {
                    store.presentFindBar()
                }
                .keyboardShortcut("f")
                .disabled(store.activeReadingDocument == nil)
                Button("查找与替换…") {
                    store.presentFindBar(showsReplace: true)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(store.activeReadingDocument == nil)
                Button("查找下一个") {
                    store.advanceFind(by: 1)
                }
                .keyboardShortcut("g")
                .disabled(store.activeReadingDocument == nil)
                Button("查找上一个") {
                    store.advanceFind(by: -1)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(store.activeReadingDocument == nil)
                Divider()
                Button("替换") {
                    store.replaceCurrentFind()
                }
                .disabled(!store.findBarPresented || store.findHits.isEmpty)
                Button("全部替换") {
                    store.replaceAllFind()
                }
                .disabled(!store.findBarPresented || store.findQuery.isEmpty)
            }
            CommandMenu("阅读") {
                Button("对照阅读") {
                    store.beginComparisonPick()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(store.currentDocument == nil)
                Button("交换左右") {
                    store.swapReaderPanes()
                }
                .disabled(store.comparisonDocument == nil)
                Button("关闭对照") {
                    store.closeComparison()
                }
                .disabled(!store.showsComparisonLayout)
                Divider()
                Button("进入编辑") { store.enterEditMode() }
                    .disabled(store.activeReadingDocument == nil || store.isEditingContent)
                Button("退出编辑") { store.exitEditMode() }
                    .disabled(!store.isEditingContent)
                Button("排版优化") { store.optimizeActiveLayout() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(store.activeReadingDocument == nil)
                Button("转成 Word") { store.exportActiveDocumentToWord() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.activeReadingDocument == nil || store.isExportingWord)
                Divider()
                Button("上一章节") { store.moveChapter(by: -1) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(store.currentDocument == nil)
                Button("下一章节") { store.moveChapter(by: 1) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(store.currentDocument == nil)
                Divider()
                Picker("阅读模式", selection: Bindable(store).preferences.mode) {
                    ForEach(ReaderMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .disabled(store.isEditingContent)
            }
        }
    }
}

@MainActor
enum IncomingDocuments {
    private static weak var store: ReaderStore?
    private static var pending: [URL] = []

    static func attach(_ store: ReaderStore) {
        self.store = store
        let urls = pending
        pending = []
        if !urls.isEmpty {
            store.openIncomingURLs(urls)
        }
    }

    static func deliver(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let store {
            store.openIncomingURLs(files)
        } else {
            pending.append(contentsOf: files)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            IncomingDocuments.deliver(urls)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in
            IncomingDocuments.deliver([URL(fileURLWithPath: filename)])
        }
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
}
