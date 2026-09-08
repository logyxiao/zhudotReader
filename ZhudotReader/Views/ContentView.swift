import SwiftUI

struct ContentView: View {
    @Environment(ReaderStore.self) private var store
    @State private var settingsPresented = false
    @State private var lanSyncPresented = false
    @State private var chaptersPresented = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView(columnVisibility: $store.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 254, max: 360)
        } detail: {
            Group {
                if store.currentDocument != nil {
                    HSplitView {
                        if let document = store.currentDocument {
                            ReaderView(document: document, pane: .primary)
                                .frame(minWidth: 320)
                        }
                        if store.showsComparisonLayout {
                            Group {
                                if let comparisonDocument = store.comparisonDocument {
                                    ReaderView(document: comparisonDocument, pane: .comparison)
                                } else {
                                    ComparisonPlaceholderView()
                                }
                            }
                            .frame(minWidth: 320)
                        }
                    }
                } else {
                    EmptyReaderView(hasLibrary: store.libraryRootURL != nil)
                }
            }
            .background(store.palette.canvas)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(store.palette.accent)
        .preferredColorScheme(store.preferences.theme == .night ? .dark : .light)
        .background {
            WindowAppearanceConfigurator(
                backgroundColor: NSColor(store.palette.app),
                isDark: store.preferences.theme == .night
            )
            .frame(width: 0, height: 0)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { lanSyncPresented.toggle() } label: {
                    Label("扫码同步阅读", systemImage: "qrcode")
                }
                .help("局域网扫码同步阅读")
                .popover(isPresented: $lanSyncPresented) { LANSyncView() }
            }
            ToolbarItem(placement: .principal) {
                LibraryTabsView()
            }

            if store.currentDocument != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    PreviewEditModePicker()

                    if store.showsComparisonLayout {
                        Button {
                            store.swapReaderPanes()
                        } label: {
                            Label("交换左右", systemImage: "arrow.left.arrow.right")
                        }
                        .help("交换左右两本书")
                        .disabled(store.comparisonDocument == nil)

                        Button {
                            store.closeComparison()
                        } label: {
                            Label("关闭对照", systemImage: "rectangle")
                        }
                        .help("关闭对照栏")
                    } else {
                        Button {
                            store.beginComparisonPick()
                        } label: {
                            Label("对照阅读", systemImage: "rectangle.split.2x1")
                        }
                        .help("左右对照阅读另一本书")
                    }

                    Button {
                        chaptersPresented.toggle()
                    } label: {
                        Label("章节目录", systemImage: "list.bullet.indent")
                    }
                    .help("章节目录")
                    .popover(isPresented: $chaptersPresented, arrowEdge: .bottom) {
                        ChapterListView()
                    }

                    Button {
                        store.presentFindBar()
                    } label: {
                        Label("查找", systemImage: "text.magnifyingglass")
                    }
                    .help("查找当前小说 · ⌘F")
                    .disabled(store.activeReadingDocument == nil)

                    Button {
                        store.optimizeActiveLayout()
                    } label: {
                        Label("排版优化", systemImage: "wand.and.stars")
                    }
                    .help("排版优化：去掉多余空行，段落整齐排列")
                    .disabled(store.activeReadingDocument == nil)

                    Button {
                        store.exportActiveDocumentToWord()
                    } label: {
                        Label("转成 Word", systemImage: "doc.richtext")
                    }
                    .help("转成 Word，保存到文稿所在目录")
                    .disabled(store.activeReadingDocument == nil || store.isExportingWord)

                    Group {
                        Picker("阅读模式", selection: $store.preferences.mode) {
                            ForEach(ReaderMode.allCases) { mode in
                                Label(mode.label, systemImage: mode.symbol).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 126)
                        .help("切换阅读模式")
                    }

                    Button {
                        settingsPresented.toggle()
                    } label: {
                        Label("阅读设置", systemImage: "textformat.size")
                    }
                    .help("阅读设置")
                    .popover(isPresented: $settingsPresented, arrowEdge: .bottom) {
                        ReaderSettingsView()
                    }
                }
            }
        }
        .toolbarBackground(store.palette.app, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onExitCommand {
            if store.findBarPresented {
                store.dismissFindBar()
            } else if store.isEditingContent {
                store.exitEditMode()
            } else if store.isPickingComparison {
                store.cancelComparisonPick()
            }
        }
        .alert("无法完成操作", isPresented: errorPresented) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "未知错误")
        }
        .alert(store.exportedWordURL == nil ? "完成" : "已导出 Word", isPresented: noticePresented) {
            if store.exportedWordURL != nil {
                Button("在 Finder 中显示") {
                    store.revealExportedWord()
                    store.noticeMessage = nil
                }
            }
            Button("好") {
                store.noticeMessage = nil
                store.exportedWordURL = nil
            }
        } message: {
            Text(store.noticeMessage ?? "")
        }
        .confirmationDialog(
            "将“\(store.pendingTrashNode?.name ?? "当前文件")”移到废纸篓？",
            isPresented: trashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                store.confirmPendingTrash()
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {
                store.cancelPendingTrash()
            }
        } message: {
            if let node = store.pendingTrashNode, node.kind == .folder {
                Text("文件夹内的 \(node.documentCount) 本书也会一起移入系统废纸篓。")
            } else {
                Text("只会移除这个文件，可以稍后从系统废纸篓恢复。")
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private var noticePresented: Binding<Bool> {
        Binding(
            get: { store.noticeMessage != nil },
            set: { if !$0 { store.noticeMessage = nil } }
        )
    }

    private var trashConfirmationPresented: Binding<Bool> {
        Binding(
            get: { store.pendingTrashNode != nil },
            set: { if !$0 { store.cancelPendingTrash() } }
        )
    }
}

private struct PreviewEditModePicker: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        Picker("视图", selection: editingBinding) {
            Text("预览").tag(false)
            Text("编辑").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 112)
        .help("预览或编辑当前聚焦的文稿")
    }

    private var editingBinding: Binding<Bool> {
        Binding(
            get: { store.isEditingContent && store.editingPane == store.activeReaderPane },
            set: { editing in
                if editing {
                    store.enterEditMode()
                } else {
                    store.exitEditMode()
                }
            }
        )
    }
}

private struct LibraryTabsView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.libraries) { library in
                        LibraryTab(library: library)
                    }
                }
            }
            .frame(maxWidth: 520)

            Button {
                store.chooseLibrary()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 27, height: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.palette.muted)
            .background(store.palette.sidebarStrong.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .help("添加书库")
        }
    }
}

private struct LibraryTab: View {
    @Environment(ReaderStore.self) private var store
    let library: LibrarySource
    @State private var hovering = false

    var body: some View {
        let isBrowsing = store.activeLibraryID == library.id
        let isPrimary = store.primaryLibraryID == library.id && store.currentDocument != nil
        let isComparison = store.comparisonLibraryID == library.id && store.showsComparisonLayout

        ZStack(alignment: .trailing) {
            Button {
                if NSEvent.modifierFlags.contains(.option), store.currentDocument != nil {
                    store.compareLibrary(library.id)
                } else {
                    store.selectLibrary(library.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isBrowsing ? "folder.fill" : "folder")
                        .font(.system(size: 11, weight: .medium))
                    Text(library.name)
                        .font(.system(size: 11, weight: isBrowsing ? .semibold : .regular))
                        .lineLimit(1)
                    if isComparison {
                        Text("对照")
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(store.palette.accentSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else if isPrimary, store.showsComparisonLayout {
                        Text("主文")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(store.palette.faint)
                    }
                }
                .foregroundStyle(isBrowsing ? store.palette.accentDeep : store.palette.muted)
                .padding(.leading, 10)
                .padding(.trailing, 22)
                .frame(height: 27)
                .background(isBrowsing ? store.palette.paper : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isComparison
                                ? store.palette.accent.opacity(0.7)
                                : (isBrowsing ? store.palette.border : Color.clear),
                            lineWidth: 1
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isComparison ? "切换到对照栏" : (isPrimary && store.showsComparisonLayout ? "切换到主文栏" : library.url.path))

            Button {
                store.removeLibrary(library.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(store.palette.muted)
                    .frame(width: 16, height: 16)
                    .background(hovering ? store.palette.sidebarStrong : Color.clear)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .opacity(hovering ? 1 : 0)
            .help("从标签栏移除（磁盘文件保留）")
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if store.currentDocument != nil {
                Button("作为对照书库打开") {
                    store.compareLibrary(library.id)
                }
            }
            Button("从标签栏移除", role: .destructive) {
                store.removeLibrary(library.id)
            }
            Text("磁盘文件会保留")
        }
    }
}

private struct WindowAppearanceConfigurator: NSViewRepresentable {
    let backgroundColor: NSColor
    let isDark: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar?.showsBaselineSeparator = false
        window.backgroundColor = backgroundColor
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

private struct EmptyReaderView: View {
    @Environment(ReaderStore.self) private var store
    let hasLibrary: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: hasLibrary ? "book.closed" : "books.vertical")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(store.palette.accentDeep)
                .frame(width: 76, height: 70)
                .background(store.palette.paper)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(store.palette.border, lineWidth: 1)
                }

            VStack(spacing: 6) {
                Text(hasLibrary ? "从书库里打开一本书" : "选择一座本地书库")
                    .font(.custom("Songti SC", size: 25).weight(.semibold))
                    .foregroundStyle(store.palette.text)
                Text(hasLibrary ? "左侧目录里只会出现 TXT 与 Markdown 文件。" : "小说留在原处，竹点阅读只负责安静地打开它。")
                    .font(.system(size: 13))
                    .foregroundStyle(store.palette.muted)
            }

            if !hasLibrary {
                Button {
                    store.chooseLibrary()
                } label: {
                    Label("选择小说文件夹", systemImage: "folder.badge.plus")
                        .padding(.horizontal, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(store.palette.app)
    }
}

private struct ComparisonPlaceholderView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(store.palette.accentDeep)
                .frame(width: 68, height: 62)
                .background(store.palette.paper)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(store.palette.border, lineWidth: 1)
                }

            VStack(spacing: 6) {
                Text(store.isLoadingComparison ? "正在打开对照…" : "选择对照的书")
                    .font(.custom("Songti SC", size: 20).weight(.semibold))
                    .foregroundStyle(store.palette.text)
                Text("可点另一个书库标签，再选一本；或按住 Option 点标签。")
                    .font(.system(size: 12))
                    .foregroundStyle(store.palette.muted)
                    .multilineTextAlignment(.center)
            }

            if store.isLoadingComparison {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("取消对照") {
                    store.cancelComparisonPick()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(store.palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(store.palette.accent.opacity(0.45), lineWidth: 1.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 18)
        .background(store.palette.canvas)
    }
}

private struct ChapterListView: View {
    @Environment(ReaderStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("章节目录")
                        .font(.custom("Songti SC", size: 17).weight(.semibold))
                    Text(chapterListSubtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(store.palette.faint)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if let chapters = store.activeReadingDocument?.chapters, !chapters.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            Button {
                                store.jump(to: chapter)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(store.palette.faint)
                                        .frame(width: 24, alignment: .trailing)
                                    Text(chapter.title)
                                        .font(.custom("Songti SC", size: 12))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                ContentUnavailableView(
                    "没有识别到章节",
                    systemImage: "text.page",
                    description: Text("正文仍然可以正常阅读。")
                )
            }
        }
        .frame(width: 330, height: 440)
        .background(store.palette.paper)
        .foregroundStyle(store.palette.text)
    }

    private var chapterListSubtitle: String {
        let count = store.activeReadingDocument?.chapters.count ?? 0
        guard store.comparisonDocument != nil else {
            return "\(count) 个阅读节点"
        }
        return "\(count) 个阅读节点 · \(store.activeReaderPane == .primary ? "主文" : "对照")"
    }
}
