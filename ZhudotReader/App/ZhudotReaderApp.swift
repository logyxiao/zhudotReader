import SwiftUI

@main
struct ZhudotReaderApp: App {
    @State private var store = ReaderStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        .frame(minWidth: store.showsComparisonLayout ? 1180 : 900, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
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
