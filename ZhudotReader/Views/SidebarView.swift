import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(ReaderStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider()

            if store.libraryRootURL == nil {
                sidebarEmptyState
            } else {
                libraryTrees
            }

            Divider()
            footer
        }
        .background(store.palette.sidebar)
        .foregroundStyle(store.palette.text)
    }

    @ViewBuilder
    private var libraryTrees: some View {
        if store.keepsDualSidebar,
           let primaryID = store.primaryLibraryID,
           let comparisonID = store.comparisonLibraryID {
            ZStack {
                LibraryOutlineList(libraryID: primaryID, nodes: store.libraryNodes)
                    .opacity(store.activeReaderPane == .primary ? 1 : 0)
                    .allowsHitTesting(store.activeReaderPane == .primary)
                    .accessibilityHidden(store.activeReaderPane != .primary)
                    .id("primary-\(primaryID)")

                LibraryOutlineList(libraryID: comparisonID, nodes: store.comparisonSidebarNodes)
                    .opacity(store.activeReaderPane == .comparison ? 1 : 0)
                    .allowsHitTesting(store.activeReaderPane == .comparison)
                    .accessibilityHidden(store.activeReaderPane != .comparison)
                    .id("comparison-\(comparisonID)")
            }
            .transaction { $0.animation = nil }
        } else {
            LibraryOutlineList(
                libraryID: store.activeLibraryID ?? "",
                nodes: store.focusedSidebarNodes
            )
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 10) {
            Image("BrandIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(store.libraryName)
                    .font(.custom("Songti SC", size: 13).weight(.semibold))
                    .lineLimit(1)
                Text(store.libraryRootURL == nil ? "本地小说阅读" : "本地书库")
                    .font(.system(size: 9))
                    .foregroundStyle(store.palette.faint)
            }
            Spacer()

            if store.libraryRootURL != nil {
                Menu {
                    LibraryCreationMenu(node: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("新建文件或文件夹")

                Button {
                    store.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新书库")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
    }

    private var footer: some View {
        HStack {
            Label("\(store.documentCount) 本", systemImage: "books.vertical")
            if store.isPickingComparison {
                Text("选择对照")
                    .foregroundStyle(store.palette.accentDeep)
            }
            Spacer()
            if store.libraryRootURL != nil {
                Button {
                    store.createDocument()
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .buttonStyle(.plain)
                .help("新建 TXT 文件")

                Button {
                    store.createFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .help("新建文件夹")
            } else {
                Button {
                    store.chooseLibrary()
                } label: {
                    Image(systemName: "plus.rectangle.on.folder")
                }
                .buttonStyle(.plain)
                .help("添加小说文件夹")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(store.palette.faint)
        .padding(.horizontal, 13)
        .frame(height: 34)
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(store.palette.faint)
            Text("还没有书库")
                .font(.custom("Songti SC", size: 14).weight(.semibold))
            Button("选择文件夹") { store.chooseLibrary() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LibraryOutlineList: View {
    @Environment(ReaderStore.self) private var store
    let libraryID: String
    let nodes: [LibraryNode]
    @State private var rootDropTargeted = false

    var body: some View {
        List {
            ForEach(nodes) { node in
                LibraryTreeNodeView(node: node, libraryID: libraryID)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if nodes.isEmpty, !store.isLoading {
                emptyLibraryHint
            }
        }
        .background(rootDropTargeted ? store.palette.accentSoft.opacity(0.55) : Color.clear)
        .contextMenu {
            LibraryCreationMenu(node: nil)
        }
        .onDrop(
            of: [LibraryDragPayload.type],
            isTargeted: $rootDropTargeted
        ) { providers in
            handleLibraryDrop(providers) { payload in
                store.moveNodeToLibraryRoot(path: payload.path, libraryID: payload.libraryID)
            }
        }
    }

    private var emptyLibraryHint: some View {
        VStack(spacing: 10) {
            Text("书库是空的")
                .font(.custom("Songti SC", size: 13).weight(.semibold))
            Text("可以新建 TXT、Markdown 或文件夹。")
                .font(.system(size: 11))
                .foregroundStyle(store.palette.faint)
            HStack(spacing: 8) {
                Button("新建文件") { store.createDocument() }
                Button("新建文件夹") { store.createFolder() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
    }
}

private struct LibraryTreeNodeView: View {
    @Environment(ReaderStore.self) private var store
    let node: LibraryNode
    var libraryID: String?
    @State private var deleteConfirmationPresented = false
    @State private var renameValue = ""
    @State private var dropTargeted = false
    @State private var renameCancelled = false
    @FocusState private var renameFocused: Bool

    private var isRenaming: Bool { store.renamingNodeID == node.id }

    var body: some View {
        Group {
            if node.kind == .folder {
                DisclosureGroup(isExpanded: folderExpansion) {
                    ForEach(node.children) { child in
                        LibraryTreeNodeView(node: child, libraryID: libraryID)
                    }
                } label: {
                    folderLabel
                        .onDrag {
                            LibraryDragPayload.provider(for: node, libraryID: libraryID ?? store.activeLibraryID)
                        }
                        .contextMenu { folderContextMenu }
                }
                .onDrop(
                    of: [LibraryDragPayload.type],
                    isTargeted: $dropTargeted
                ) { providers in
                    handleLibraryDrop(providers) { payload in
                        store.moveNode(path: payload.path, libraryID: payload.libraryID, to: node.url)
                    }
                }
                .contextMenu { folderContextMenu }
            } else {
                documentRow
                    .onDrag { LibraryDragPayload.provider(for: node, libraryID: libraryID ?? store.activeLibraryID) }
                    .contextMenu { documentContextMenu }
            }
        }
        .confirmationDialog(
            "将“\(node.name)”移到废纸篓？",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                store.trashNode(node)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(node.kind == .folder ? "文件夹内的 \(node.documentCount) 本书也会一起移入系统废纸篓。" : "可以稍后从系统废纸篓恢复。")
        }
        .onChange(of: store.renamingNodeID) { _, id in
            if id == node.id { startInlineRename() }
        }
        .onChange(of: renameFocused) { _, focused in
            guard !focused, store.renamingNodeID == node.id else { return }
            if renameCancelled {
                renameCancelled = false
                store.cancelRename()
            } else {
                store.commitRename(node, to: renameValue)
            }
        }
        .onAppear {
            if isRenaming { startInlineRename() }
        }
    }

    private var folderLabel: some View {
        Group {
            if isRenaming {
                renameField(icon: folderExpansion.wrappedValue ? "folder.fill" : "folder")
            } else {
                Button {
                    folderExpansion.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: folderExpansion.wrappedValue ? "folder.fill" : "folder")
                            .foregroundStyle(folderExpansion.wrappedValue ? store.palette.accentDeep : store.palette.muted)
                        Text(node.name)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(node.documentCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(store.palette.faint)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .padding(.horizontal, 3)
                    .background(dropTargeted ? store.palette.accentSoft : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var documentRow: some View {
        Group {
            if isRenaming {
                renameField(icon: node.url.pathExtension.lowercased() == "md" ? "text.document" : "doc.text")
                    .padding(.horizontal, 6)
                    .frame(height: 28)
            } else {
                ZStack(alignment: .trailing) {
                    Button {
                        if NSEvent.modifierFlags.contains(.option) {
                            store.openComparisonDocument(node)
                        } else {
                            store.openDocument(node)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: node.url.pathExtension.lowercased() == "md" ? "text.document" : "doc.text")
                                .foregroundStyle(
                                    store.selectedDocumentID == node.id || store.comparisonDocument?.id == node.id
                                        ? store.palette.accentDeep
                                        : store.palette.faint
                                )
                            Text(node.name)
                                .font(.custom("Songti SC", size: 11))
                                .lineLimit(1)
                            Spacer()
                            Text(node.url.pathExtension.uppercased())
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundStyle(store.palette.faint)
                        }
                        .padding(.leading, 6)
                        .padding(.trailing, 30)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .background {
                            if store.selectedDocumentID == node.id {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(store.palette.accentSoft)
                            } else if store.comparisonDocument?.id == node.id {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(store.palette.accent.opacity(0.55), lineWidth: 1)
                            } else if store.isPickingComparison {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(store.palette.accent.opacity(0.22), lineWidth: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .highPriorityGesture(
                        TapGesture(count: 2).onEnded {
                            store.openDocument(node, enterEdit: true)
                        }
                    )

                    Button {
                        if store.comparisonDocument?.id == node.id {
                            store.closeComparison()
                        } else {
                            store.openComparisonDocument(node)
                        }
                    } label: {
                        Image(systemName: store.comparisonDocument?.id == node.id ? "xmark" : "rectangle.split.2x1")
                            .font(.system(size: 9, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        store.comparisonDocument?.id == node.id
                            ? store.palette.accentDeep
                            : store.palette.faint
                    )
                    .help(store.comparisonDocument?.id == node.id ? "关闭对照栏" : "在对照栏打开")
                    .padding(.trailing, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var documentContextMenu: some View {
        if store.comparisonDocument?.id == node.id {
            Button("关闭对照栏", systemImage: "xmark.rectangle") {
                store.closeComparison()
            }
        } else {
            Button("在对照栏打开", systemImage: "rectangle.split.2x1") {
                store.openComparisonDocument(node)
            }
        }
        Divider()
        LibraryCreationMenu(node: node)
        Divider()
        Button("重命名", systemImage: "pencil") {
            store.beginRename(node)
        }
        Button(store.isEditingContent && store.document(in: store.editingPane)?.id == node.id ? "退出编辑" : "编辑", systemImage: "square.and.pencil") {
            if store.isEditingContent, store.document(in: store.editingPane)?.id == node.id {
                store.exitEditMode()
            } else if store.comparisonDocument?.id == node.id {
                store.enterEditMode(.comparison)
            } else {
                store.openDocument(node, enterEdit: true)
            }
        }
        Button("在 Finder 中显示", systemImage: "folder") {
            store.revealInFinder(node)
        }
        Button("转成 Word", systemImage: "doc.richtext") {
            store.exportNodeToWord(node)
        }
        Divider()
        Button("移到废纸篓…", systemImage: "trash", role: .destructive) {
            deleteConfirmationPresented = true
        }
    }

    @ViewBuilder
    private var folderContextMenu: some View {
        LibraryCreationMenu(node: node)
        Divider()
        Button("重命名", systemImage: "pencil") {
            store.beginRename(node)
        }
        Button("在 Finder 中显示", systemImage: "folder") {
            store.revealInFinder(node)
        }
        Divider()
        Button("移到废纸篓…", systemImage: "trash", role: .destructive) {
            deleteConfirmationPresented = true
        }
    }

    private func renameField(icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(store.palette.accentDeep)
            TextField("名称", text: $renameValue)
                .textFieldStyle(.plain)
                .font(.custom("Songti SC", size: 11))
                .focused($renameFocused)
                .onSubmit {
                    store.commitRename(node, to: renameValue)
                }
                .onExitCommand {
                    renameCancelled = true
                    renameFocused = false
                    store.cancelRename()
                }
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: 24)
    }

    private func startInlineRename() {
        renameCancelled = false
        renameValue = node.name
        renameFocused = true
    }

    private var folderExpansion: Binding<Bool> {
        Binding(
            get: { store.expandedFolderIDs.contains(node.id) },
            set: { store.setFolderExpanded(node.id, isExpanded: $0) }
        )
    }
}

private struct LibraryCreationMenu: View {
    @Environment(ReaderStore.self) private var store
    let node: LibraryNode?

    var body: some View {
        Button("新建 TXT 文件", systemImage: "doc.badge.plus") {
            store.createDocument(in: node, format: .text)
        }
        Button("新建 Markdown 文件", systemImage: "text.document") {
            store.createDocument(in: node, format: .markdown)
        }
        Button("新建文件夹", systemImage: "folder.badge.plus") {
            store.createFolder(in: node)
        }
    }
}

private struct LibraryDragPayload: Codable {
    static let type = UTType(exportedAs: "com.zhudot.reader.library-node")

    let path: String
    let libraryID: String

    static func provider(for node: LibraryNode, libraryID: String?) -> NSItemProvider {
        let payload = LibraryDragPayload(path: node.id, libraryID: libraryID ?? "")
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return NSItemProvider(item: data as NSData, typeIdentifier: type.identifier)
    }
}

private func handleLibraryDrop(
    _ providers: [NSItemProvider],
    action: @escaping @MainActor (LibraryDragPayload) -> Void
) -> Bool {
    guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(LibraryDragPayload.type.identifier) }) else {
        return false
    }
    provider.loadDataRepresentation(forTypeIdentifier: LibraryDragPayload.type.identifier) { data, _ in
        guard let data,
              let payload = try? JSONDecoder().decode(LibraryDragPayload.self, from: data) else { return }
        Task { @MainActor in action(payload) }
    }
    return true
}
