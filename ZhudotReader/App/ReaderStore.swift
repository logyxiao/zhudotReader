import AppKit
import UniformTypeIdentifiers
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ReaderStore {
    private enum Keys {
        static let preferences = "zhudot.reader.preferences"
        static let lastDocumentPath = "zhudot.reader.lastDocumentPath"
        static let lastDocumentsByLibrary = "zhudot.reader.lastDocumentsByLibrary"
        static let activeLibraryID = "zhudot.reader.activeLibraryID"
        static let progress = "zhudot.reader.progress"
    }

    private struct DocumentFileStamp: Equatable {
        let modificationDate: Date?
        let fileSize: Int?
    }

    private struct DocumentCacheEntry {
        let document: ReaderDocument
        let fileStamp: DocumentFileStamp
        let preferences: ReaderPreferences
    }

    let lanSync = LANReadingSync()

    func startLANSync() {
        guard let shared = activeReadingDocument, !isEditingContent else { return }
        let documentID = shared.id
        lanSync.start(snapshot: { [weak self] in
            guard let self, let pane = self.paneDisplayingDocument(documentID),
                  let document = self.document(in: pane) else { return nil }
            return ["title": document.title, "text": document.displayText,
                    "version": String(document.contentFingerprint),
                    "count": document.characterCount, "offset": self.readingOffset(in: pane),
                    "chapters": document.chapters.map { ["title": $0.title, "offset": $0.offset] as [String: Any] }]
        }, progress: { [weak self] offset in
            guard let self, let pane = self.paneDisplayingDocument(documentID), !self.isEditingContent else { return }
            if pane == .primary { self.requestLocation(offset) }
            else { self.requestComparisonLocation(offset) }
            self.updateReadingOffset(offset, in: pane)
        })
    }

    private func paneDisplayingDocument(_ id: String) -> ReaderPane? {
        if currentDocument?.id == id { return .primary }
        if comparisonDocument?.id == id { return .comparison }
        return nil
    }

    var libraries: [LibrarySource] = []
    var activeLibraryID: String?
    var primaryLibraryID: String?
    var comparisonLibraryID: String?
    var libraryNodes: [LibraryNode] = []
    var comparisonSidebarNodes: [LibraryNode] = []
    var selectedDocumentID: String?
    var expandedFolderIDs: Set<String> = []
    var currentDocument: ReaderDocument?
    var comparisonDocument: ReaderDocument?
    var isPickingComparison = false
    var activeReaderPane: ReaderPane = .primary
    var isEditingContent = false
    var editingPane: ReaderPane = .primary
    var draftText = ""
    var isDraftDirty = false
    var renamingNodeID: String?
    var isLoading = false
    var isLoadingComparison = false
    var errorMessage: String?
    var noticeMessage: String?
    var exportedWordURL: URL?
    var isExportingWord = false
    var pendingTrashNode: LibraryNode?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var readingOffset = 0
    var locationRequest = ReadingLocationRequest(offset: 0)
    var comparisonReadingOffset = 0
    var comparisonLocationRequest = ReadingLocationRequest(offset: 0)
    var findBarPresented = false
    var findQuery = ""
    var findReplacement = ""
    var findShowsReplace = false
    var findMatchCase = false
    var findHits: [NSRange] = []
    var findIndex = 0
    var findPane: ReaderPane = .primary
    var findFocusToken = UUID()
    var findHighlight = SearchHighlightRequest.none
    var draftEpoch = 0

    var preferences: ReaderPreferences {
        didSet {
            guard preferences != oldValue else { return }
            persistPreferences()
            if preferences.theme != oldValue.theme
                || preferences.fontFamily != oldValue.fontFamily
                || preferences.fontSize != oldValue.fontSize
                || preferences.lineHeight != oldValue.lineHeight {
                scheduleDocumentRestyle()
            }
        }
    }

    var palette: ReaderPalette { .palette(for: preferences.theme) }

    var activeLibrary: LibrarySource? {
        libraries.first { $0.id == activeLibraryID }
    }

    var libraryRootURL: URL? { activeLibrary?.url }

    var libraryName: String {
        activeLibrary?.name ?? "竹点阅读"
    }

    var documentCount: Int {
        focusedSidebarNodes.reduce(0) { $0 + $1.documentCount }
    }

    var focusedSidebarNodes: [LibraryNode] {
        if showsComparisonLayout,
           activeReaderPane == .comparison,
           comparisonLibraryID != primaryLibraryID {
            return comparisonSidebarNodes
        }
        return libraryNodes
    }

    var keepsDualSidebar: Bool {
        showsComparisonLayout
            && primaryLibraryID != nil
            && comparisonLibraryID != nil
            && primaryLibraryID != comparisonLibraryID
    }

    var readingPercentage: Int {
        guard let currentDocument, currentDocument.characterCount > 0 else { return 0 }
        return Int((Double(readingOffset) / Double(currentDocument.characterCount) * 100).rounded())
    }

    var currentChapter: Chapter? {
        currentDocument?.chapters.last { $0.offset <= readingOffset }
    }

    var activeReadingDocument: ReaderDocument? {
        document(in: activeReaderPane)
    }

    var showsComparisonLayout: Bool {
        comparisonDocument != nil || isPickingComparison
    }

    var findCounterLabel: String {
        if findQuery.isEmpty { return "—" }
        if findHits.isEmpty { return "无匹配" }
        let suffix = findHits.count >= TextSearch.matchLimit ? "+" : ""
        return "\(findIndex + 1)/\(findHits.count)\(suffix)"
    }

    var findJumpWindow: [FindJumpItem] {
        guard !findHits.isEmpty, let text = findHaystack() else { return [] }
        let start = max(0, findIndex - 40)
        let end = min(findHits.count, findIndex + 41)
        return (start..<end).map { index in
            FindJumpItem(
                index: index,
                snippet: TextSearch.snippet(in: text, range: findHits[index])
            )
        }
    }

    func searchHighlight(in pane: ReaderPane) -> SearchHighlightRequest {
        findBarPresented && findPane == pane ? findHighlight : .none
    }

    @ObservationIgnored private let bookmarkStore = SecurityScopedBookmarkStore()
    @ObservationIgnored private let scanner = LibraryScanner()
    @ObservationIgnored private let documentLoader = DocumentLoader()
    @ObservationIgnored private var libraryNodeCache: [String: [LibraryNode]] = [:]
    @ObservationIgnored private var documentCache: [String: DocumentCacheEntry] = [:]
    @ObservationIgnored private var documentCacheOrder: [String] = []
    @ObservationIgnored private var primaryDocumentRequestID = UUID()
    @ObservationIgnored private var comparisonDocumentRequestID = UUID()
    @ObservationIgnored private var lastDocumentByLibrary: [String: String]
    @ObservationIgnored private var progressByPath: [String: ReadingProgress]
    @ObservationIgnored private var progressSaveTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var findSearchTask: Task<Void, Never>?
    @ObservationIgnored private var restyleTask: Task<Void, Never>?

    private static let documentCacheCharacterLimit = 4_000_000

    init() {
        preferences = Self.loadPreferences()
        lastDocumentByLibrary = Self.loadLastDocuments()
        progressByPath = Self.loadProgress()
        restoreTask = Task { [weak self] in
            await self?.restoreLibraries()
        }
        IncomingDocuments.attach(self)
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "选择小说文件夹"
        panel.message = "竹点阅读只读取文件夹中的 TXT 与 Markdown 文件。"
        panel.prompt = "选择书库"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await installLibrary(url) }
    }

    func chooseDocuments() {
        let panel = NSOpenPanel()
        panel.title = "打开文稿"
        panel.message = "选择 TXT 或 Markdown 文件，用竹点阅读打开。"
        panel.prompt = "打开"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedDocumentTypes

        guard panel.runModal() == .OK else { return }
        openIncomingURLs(panel.urls)
    }

    func openIncomingURLs(_ urls: [URL]) {
        for url in urls {
            openIncomingURL(url)
        }
    }

    func openIncomingURL(_ url: URL) {
        Task {
            await restoreTask?.value
            await openExternalFile(url)
        }
    }

    func refreshLibrary() {
        guard activeLibrary != nil else { return }
        Task {
            await reloadAfterFileOperation(
                preferredDocumentPath: selectedDocumentID,
                preferredComparisonPath: comparisonDocument?.id
            )
        }
    }

    func selectLibrary(_ libraryID: String) {
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
        if showsComparisonLayout {
            if libraryID == primaryLibraryID, libraryID == comparisonLibraryID {
                focusPane(activeReaderPane == .primary ? .comparison : .primary)
            } else if libraryID == comparisonLibraryID {
                focusPane(.comparison)
            } else if libraryID == primaryLibraryID {
                focusPane(.primary)
            } else {
                Task { await activateComparisonLibrary(library) }
            }
            return
        }
        guard libraryID != activeLibraryID else { return }
        Task { await activateLibrary(library) }
    }

    func compareLibrary(_ libraryID: String) {
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
        Task { await activateComparisonLibrary(library) }
    }

    func removeLibrary(_ libraryID: String) {
        guard let index = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        let removed = libraries.remove(at: index)
        bookmarkStore.remove(removed.url)
        libraryNodeCache.removeValue(forKey: libraryID)
        lastDocumentByLibrary.removeValue(forKey: libraryID)
        persistLastDocuments()

        if comparisonLibraryID == libraryID {
            closeComparison()
        }
        guard primaryLibraryID == libraryID else { return }
        primaryDocumentRequestID = UUID()
        comparisonDocumentRequestID = UUID()
        currentDocument = nil
        comparisonDocument = nil
        isPickingComparison = false
        activeReaderPane = .primary
        selectedDocumentID = nil
        readingOffset = 0
        comparisonReadingOffset = 0
        isEditingContent = false
        draftText = ""
        isDraftDirty = false
        renamingNodeID = nil
        libraryNodes = []
        comparisonSidebarNodes = []
        activeLibraryID = nil
        primaryLibraryID = nil
        let nextIndex = min(index, max(0, libraries.count - 1))
        if libraries.indices.contains(nextIndex) {
            Task { await activateLibrary(libraries[nextIndex]) }
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.activeLibraryID)
        }
    }

    func openDocument(_ node: LibraryNode, enterEdit: Bool = false) {
        guard node.kind == .document else { return }
        if enterEdit, currentDocument?.id == node.id {
            enterEditMode(.primary)
            return
        }
        if enterEdit, comparisonDocument?.id == node.id {
            enterEditMode(.comparison)
            return
        }
        if isPickingComparison || (showsComparisonLayout && shouldOpenInComparisonPane) {
            openComparisonDocument(node, enterEdit: enterEdit)
            return
        }
        if comparisonDocument?.id == node.id, currentDocument?.id != node.id {
            activateReader(.comparison)
            if enterEdit {
                enterEditMode(.comparison)
            }
            return
        }
        activeReaderPane = .primary
        Task {
            if currentDocument?.id != node.id {
                await loadDocument(at: node.url, libraryID: owningLibraryID(for: node.url) ?? activeLibraryID)
            }
            if enterEdit {
                enterEditMode(.primary)
            }
        }
    }

    func openComparisonDocument(_ node: LibraryNode, enterEdit: Bool = false) {
        guard node.kind == .document else { return }
        if currentDocument == nil {
            isPickingComparison = false
            openDocument(node, enterEdit: enterEdit)
            return
        }
        if currentDocument?.id == node.id {
            if enterEdit {
                enterEditMode(.primary)
                return
            }
            if comparisonDocument == nil {
                beginComparisonPick()
            }
            return
        }
        let sourceLibraryID = owningLibraryID(for: node.url) ?? comparisonLibraryID ?? activeLibraryID
        if comparisonDocument?.id == node.id {
            if let sourceLibraryID {
                comparisonLibraryID = sourceLibraryID
            }
            focusPane(.comparison)
            if enterEdit {
                enterEditMode(.comparison)
            }
            return
        }
        if comparisonDocument == nil {
            isPickingComparison = true
        }
        if let sourceLibraryID {
            comparisonLibraryID = sourceLibraryID
            if let cached = libraryNodeCache[sourceLibraryID] {
                publishSidebarNodes(cached, for: sourceLibraryID)
            }
        }
        focusPane(.comparison)
        Task {
            await loadComparisonDocument(at: node.url, libraryID: sourceLibraryID)
            if enterEdit {
                enterEditMode(.comparison)
            }
        }
    }

    func beginComparisonPick() {
        guard currentDocument != nil else { return }
        if comparisonDocument != nil {
            activeReaderPane = .comparison
            return
        }
        isPickingComparison = true
        activeReaderPane = .primary
    }

    func cancelComparisonPick() {
        isPickingComparison = false
        isLoadingComparison = false
        if comparisonDocument == nil {
            comparisonLibraryID = nil
            comparisonSidebarNodes = []
            focusPane(.primary)
        }
    }

    func closeComparison() {
        if isEditingContent, editingPane == .comparison {
            Task {
                await finishEditing()
                tearDownComparison()
            }
            return
        }
        tearDownComparison()
    }

    private func tearDownComparison() {
        comparisonDocumentRequestID = UUID()
        comparisonDocument = nil
        comparisonLibraryID = nil
        isPickingComparison = false
        isLoadingComparison = false
        comparisonReadingOffset = 0
        requestComparisonLocation(0)
        comparisonSidebarNodes = []
        if findPane == .comparison {
            dismissFindBar()
        }
        focusPane(.primary)
    }

    func swapReaderPanes() {
        guard let primary = currentDocument, let comparison = comparisonDocument else { return }
        Task {
            if isEditingContent {
                await finishEditing()
            }
            let primaryOffset = readingOffset
            let comparisonOffset = comparisonReadingOffset
            currentDocument = comparison
            comparisonDocument = primary
            let shouldSwapTrees = primaryLibraryID != comparisonLibraryID && !comparisonSidebarNodes.isEmpty
            swap(&primaryLibraryID, &comparisonLibraryID)
            if shouldSwapTrees {
                swap(&libraryNodes, &comparisonSidebarNodes)
            }
            selectedDocumentID = comparison.id
            readingOffset = comparisonOffset
            comparisonReadingOffset = primaryOffset
            requestLocation(comparisonOffset)
            requestComparisonLocation(primaryOffset)
            if let primaryLibraryID {
                lastDocumentByLibrary[primaryLibraryID] = comparison.id
                persistLastDocuments()
            }
            if findBarPresented {
                findPane = findPane == .primary ? .comparison : .primary
                scheduleFindSearch(immediate: true)
            }
            focusPane(.primary)
        }
    }

    func activateReader(_ pane: ReaderPane) {
        focusPane(pane)
    }

    func focusPane(_ pane: ReaderPane) {
        guard pane == .primary || comparisonDocument != nil || isPickingComparison else { return }
        if activeReaderPane != pane {
            activeReaderPane = pane
        }
        let libraryID = pane == .primary ? primaryLibraryID : comparisonLibraryID
        if let libraryID, activeLibraryID != libraryID {
            activeLibraryID = libraryID
        }
    }

    private var shouldOpenInComparisonPane: Bool {
        activeReaderPane == .comparison || activeLibraryID == comparisonLibraryID
    }

    func enterEditMode(_ pane: ReaderPane? = nil) {
        let target = pane ?? (activeReaderPane == .comparison && comparisonDocument != nil ? .comparison : .primary)
        guard document(in: target) != nil else { return }
        if isEditingContent {
            if editingPane == target { return }
            Task {
                await finishEditing()
                beginEditing(target)
            }
            return
        }
        beginEditing(target)
    }

    private func beginEditing(_ pane: ReaderPane) {
        guard let document = document(in: pane) else { return }
        focusPane(pane)
        editingPane = pane
        draftText = document.sourceText
        isDraftDirty = false
        isEditingContent = true
    }

    func exitEditMode() {
        guard isEditingContent else { return }
        Task { await finishEditing() }
    }

    func updateDraft(_ text: String) {
        guard isEditingContent else { return }
        draftText = text
        isDraftDirty = true
        scheduleDraftSave()
    }

    func saveDraftNow() {
        Task { await saveDraftIfNeeded() }
    }

    func createDocument(in parent: LibraryNode? = nil, format: DocumentFormat = .text) {
        Task {
            do {
                let directory = try insertionDirectory(relativeTo: parent)
                let ext = format == .markdown ? "md" : "txt"
                let filename = uniqueItemName(in: directory, base: "未命名", ext: ext)
                let url = directory.appendingPathComponent(filename)
                try validateManagedURL(url)
                guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
                    throw ReaderError.fileOperationFailed("无法创建文件。")
                }
                expandAncestors(of: url)
                await reloadAfterFileOperation(
                    preferredDocumentPath: url.standardizedFileURL.path,
                    preferredComparisonPath: comparisonDocument?.id
                )
                renamingNodeID = url.standardizedFileURL.path
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createFolder(in parent: LibraryNode? = nil) {
        Task {
            do {
                let directory = try insertionDirectory(relativeTo: parent)
                let name = uniqueItemName(in: directory, base: "未命名文件夹", ext: nil)
                let url = directory.appendingPathComponent(name)
                try validateManagedURL(url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                expandAncestors(of: url)
                await reloadAfterFileOperation(
                    preferredDocumentPath: currentDocument?.id,
                    preferredComparisonPath: comparisonDocument?.id
                )
                renamingNodeID = url.standardizedFileURL.path
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func beginRename(_ node: LibraryNode) {
        renamingNodeID = node.id
    }

    func commitRename(_ node: LibraryNode, to proposedName: String) {
        guard renamingNodeID == node.id else { return }
        renamingNodeID = nil
        renameNode(node, to: proposedName)
    }

    func cancelRename() {
        renamingNodeID = nil
    }

    func setFolderExpanded(_ folderID: String, isExpanded: Bool) {
        if isExpanded {
            expandedFolderIDs.insert(folderID)
        } else {
            expandedFolderIDs.remove(folderID)
        }
    }

    func collapseFolders(in nodes: [LibraryNode]) {
        var folderIDs: Set<String> = []

        func collectFolderIDs(from nodes: [LibraryNode]) {
            for node in nodes where node.kind == .folder {
                folderIDs.insert(node.id)
                collectFolderIDs(from: node.children)
            }
        }

        collectFolderIDs(from: nodes)
        expandedFolderIDs.subtract(folderIDs)
    }

    func revealInFinder(_ node: LibraryNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func exportActiveDocumentToWord() {
        guard let document = activeReadingDocument else { return }
        let source = isEditingThis(document) ? draftText : document.sourceText
        exportToWord(sourceURL: document.url, source: source)
    }

    func exportNodeToWord(_ node: LibraryNode) {
        guard node.kind == .document else { return }
        if currentDocument?.id == node.id {
            let source = isEditingContent && editingPane == .primary ? draftText : currentDocument?.sourceText
            exportToWord(sourceURL: node.url, source: source ?? "")
            return
        }
        if comparisonDocument?.id == node.id {
            let source = isEditingContent && editingPane == .comparison ? draftText : comparisonDocument?.sourceText
            exportToWord(sourceURL: node.url, source: source ?? "")
            return
        }
        Task {
            do {
                if let libraryID = owningLibraryID(for: node.url),
                   let library = libraries.first(where: { $0.id == libraryID }) {
                    bookmarkStore.access(library.url)
                }
                let data = try Data(contentsOf: node.url)
                let source = try TextDecoder.decode(data, fileName: node.name)
                exportToWord(sourceURL: node.url, source: source)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealExportedWord() {
        guard let exportedWordURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedWordURL])
    }

    func optimizeActiveLayout() {
        let pane = activeReaderPane
        guard let document = document(in: pane) else { return }
        let editingThis = isEditingContent && editingPane == pane
        let source = editingThis ? draftText : document.sourceText
        let tidied = TextTidy.optimize(source)
        guard tidied != source else {
            exportedWordURL = nil
            noticeMessage = "排版已经很整齐，没有多余空行。"
            return
        }
        if editingThis {
            draftText = tidied
            isDraftDirty = true
            draftEpoch += 1
            applyDocumentSource(tidied, in: pane)
            scheduleDraftSave()
            exportedWordURL = nil
            noticeMessage = "已优化排版，退出编辑后保存。"
            refreshFindHitsIfNeeded()
            return
        }
        Task { await writeTidiedDocument(tidied, in: pane, url: document.url) }
    }

    func tidyNode(_ node: LibraryNode) {
        guard node.kind == .document else { return }
        if let pane = paneShowing(node.id) {
            let editingThis = isEditingContent && editingPane == pane
            if !editingThis {
                activateReader(pane)
                optimizeActiveLayout()
                return
            }
        }
        Task {
            do {
                try validateManagedURL(node.url)
                if let libraryID = owningLibraryID(for: node.url),
                   let library = libraries.first(where: { $0.id == libraryID }) {
                    bookmarkStore.access(library.url)
                }
                let data = try Data(contentsOf: node.url)
                let source = try TextDecoder.decode(data, fileName: node.name)
                let tidied = TextTidy.optimize(source)
                guard tidied != source else {
                    exportedWordURL = nil
                    noticeMessage = "「\(node.name)」排版已经很整齐。"
                    return
                }
                try await Task.detached {
                    try Data(tidied.utf8).write(to: node.url, options: .atomic)
                }.value
                await reloadAfterFileOperation(
                    preferredDocumentPath: currentDocument?.id,
                    preferredComparisonPath: comparisonDocument?.id
                )
                exportedWordURL = nil
                noticeMessage = "已优化「\(node.name)」的排版并保存。"
            } catch {
                errorMessage = ReaderError.fileOperationFailed(error.localizedDescription).localizedDescription
            }
        }
    }

    private func paneShowing(_ documentID: String) -> ReaderPane? {
        if currentDocument?.id == documentID { return .primary }
        if comparisonDocument?.id == documentID { return .comparison }
        return nil
    }

    private func writeTidiedDocument(_ tidied: String, in pane: ReaderPane, url: URL) async {
        do {
            try validateManagedURL(url)
            if let libraryID = owningLibraryID(for: url),
               let library = libraries.first(where: { $0.id == libraryID }) {
                bookmarkStore.access(library.url)
            }
            let previousOffset = readingOffset(in: pane)
            try await Task.detached {
                try Data(tidied.utf8).write(to: url, options: .atomic)
            }.value
            applyDocumentSource(tidied, in: pane)
            if let updated = document(in: pane) {
                let clamped = min(previousOffset, updated.characterCount)
                updateReadingOffset(clamped, in: pane)
                if pane == .primary {
                    requestLocation(clamped)
                } else {
                    requestComparisonLocation(clamped)
                }
            }
            exportedWordURL = nil
            noticeMessage = "已优化排版并保存。"
            refreshFindHitsIfNeeded()
        } catch {
            errorMessage = ReaderError.fileOperationFailed(error.localizedDescription).localizedDescription
        }
    }

    private func exportToWord(sourceURL: URL, source: String) {
        Task {
            if isEditingContent, document(in: editingPane)?.url.standardizedFileURL == sourceURL.standardizedFileURL {
                await saveDraftIfNeeded()
            }
            isExportingWord = true
            errorMessage = nil
            do {
                try validateManagedURL(sourceURL)
                if let libraryID = owningLibraryID(for: sourceURL),
                   let library = libraries.first(where: { $0.id == libraryID }) {
                    bookmarkStore.access(library.url)
                }
                let output = try await Task.detached(priority: .userInitiated) {
                    try WordDocumentExporter.export(source: source, sourceURL: sourceURL)
                }.value
                exportedWordURL = output
                noticeMessage = "已导出「\(output.lastPathComponent)」到文稿所在目录。"
            } catch {
                errorMessage = ReaderError.fileOperationFailed(error.localizedDescription).localizedDescription
            }
            isExportingWord = false
        }
    }

    func renameNode(_ node: LibraryNode, to proposedName: String) {
        Task {
            do {
                let name = try validatedName(proposedName, for: node)
                let destination = node.url.deletingLastPathComponent().appendingPathComponent(name)
                try moveItem(node, to: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func moveNode(_ node: LibraryNode, to destinationFolder: URL) {
        Task {
            do {
                let destination = destinationFolder.appendingPathComponent(node.url.lastPathComponent)
                try moveItem(node, to: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func moveNode(path: String, libraryID: String, to destinationFolder: URL) {
        guard libraries.contains(where: { $0.id == libraryID }),
              let node = findNode(path: path, in: nodes(forLibraryID: libraryID)) else {
            errorMessage = "只能在当前书库内移动文件。"
            return
        }
        moveNode(node, to: destinationFolder)
    }

    func moveNodeToLibraryRoot(path: String, libraryID: String) {
        guard let root = libraries.first(where: { $0.id == libraryID })?.url else {
            errorMessage = "找不到文件所属的书库。"
            return
        }
        moveNode(path: path, libraryID: libraryID, to: root)
    }

    func trashNode(_ node: LibraryNode) {
        let preferredDocumentPath = replacementDocumentPath(
            for: currentDocument?.id,
            removing: node,
            in: nodes(for: .primary)
        )
        let preferredComparisonPath = replacementDocumentPath(
            for: comparisonDocument?.id,
            removing: node,
            in: nodes(for: .comparison)
        )

        Task {
            do {
                try validateManagedURL(node.url)
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: node.url, resultingItemURL: &trashedURL)
                removeState(forPathPrefix: node.id)
                await reloadAfterFileOperation(
                    preferredDocumentPath: preferredDocumentPath,
                    preferredComparisonPath: preferredComparisonPath
                )
            } catch {
                errorMessage = ReaderError.fileOperationFailed(error.localizedDescription).localizedDescription
            }
        }
    }

    func requestTrash(_ node: LibraryNode) {
        pendingTrashNode = node
    }

    func requestTrashActiveDocument() {
        guard !isEditingContent,
              let document = activeReadingDocument,
              let node = findNode(path: document.id, in: nodes(for: activeReaderPane)),
              node.kind == .document else { return }
        requestTrash(node)
    }

    func confirmPendingTrash() {
        guard let node = pendingTrashNode else { return }
        pendingTrashNode = nil
        trashNode(node)
    }

    func cancelPendingTrash() {
        pendingTrashNode = nil
    }

    func updateReadingOffset(_ offset: Int) {
        updateReadingOffset(offset, in: .primary)
    }

    func updateReadingOffset(_ offset: Int, in pane: ReaderPane) {
        guard let document = document(in: pane) else { return }
        let clamped = min(max(0, offset), document.characterCount)
        if pane == .primary {
            readingOffset = clamped
        } else {
            comparisonReadingOffset = clamped
        }
        progressByPath[document.id] = ReadingProgress(characterOffset: clamped, updatedAt: Date())
        scheduleProgressSave()
    }

    func jump(to chapter: Chapter) {
        jump(to: chapter, in: activeReaderPane)
    }

    func jump(to chapter: Chapter, in pane: ReaderPane) {
        if pane == .primary {
            requestLocation(chapter.offset)
        } else {
            requestComparisonLocation(chapter.offset)
        }
        updateReadingOffset(chapter.offset, in: pane)
    }

    func jumpToBeginning(in pane: ReaderPane) {
        guard document(in: pane) != nil else { return }
        if pane == .primary {
            requestLocation(0)
        } else {
            requestComparisonLocation(0)
        }
        updateReadingOffset(0, in: pane)
    }

    func moveChapter(by delta: Int) {
        let pane = activeReaderPane
        guard let chapters = document(in: pane)?.chapters, !chapters.isEmpty else { return }
        let offset = readingOffset(in: pane)
        let currentIndex = chapters.lastIndex { $0.offset <= offset } ?? 0
        let target = min(max(0, currentIndex + delta), chapters.count - 1)
        jump(to: chapters[target], in: pane)
    }

    func presentFindBar(showsReplace: Bool = false) {
        guard document(in: activeReaderPane) != nil || document(in: findPane) != nil else { return }
        findPane = document(in: activeReaderPane) != nil ? activeReaderPane : findPane
        findBarPresented = true
        findShowsReplace = showsReplace
        findFocusToken = UUID()
        if !findQuery.isEmpty {
            scheduleFindSearch(immediate: true)
        } else {
            publishFindHighlight()
        }
    }

    func dismissFindBar() {
        findBarPresented = false
        findShowsReplace = false
        findHits = []
        findIndex = 0
        findSearchTask?.cancel()
        findHighlight = .none
    }

    func setFindMatchCase(_ matchCase: Bool) {
        findMatchCase = matchCase
        scheduleFindSearch(immediate: true)
    }

    func scheduleFindSearch(immediate: Bool = false) {
        findSearchTask?.cancel()
        guard findBarPresented else { return }
        if immediate || findQuery.isEmpty {
            recomputeFindHits()
            return
        }
        findSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled, let self else { return }
            self.recomputeFindHits()
        }
    }

    func advanceFind(by delta: Int) {
        if !findBarPresented {
            presentFindBar()
            return
        }
        guard !findHits.isEmpty else { return }
        let count = findHits.count
        findIndex = (findIndex + delta % count + count) % count
        revealCurrentFindHit()
    }

    func jumpToFindHit(at index: Int) {
        guard findHits.indices.contains(index) else { return }
        findIndex = index
        revealCurrentFindHit()
    }

    func replaceCurrentFind() {
        guard !findQuery.isEmpty, findHits.indices.contains(findIndex) else { return }
        let range = findHits[findIndex]
        if canReplaceInFileDirectly {
            Task { await replaceInFile(range: range, replacingAll: false) }
            return
        }
        ensureEditingForReplace()
        guard findHits.indices.contains(findIndex) else { return }
        applyReplaceInDraft(range: findHits[findIndex])
    }

    func replaceAllFind() {
        guard !findQuery.isEmpty else { return }
        if canReplaceInFileDirectly {
            Task { await replaceInFile(range: nil, replacingAll: true) }
            return
        }
        ensureEditingForReplace()
        let result = TextSearch.replacing(
            in: draftText,
            query: findQuery,
            replacement: findReplacement,
            matchCase: findMatchCase
        )
        guard result.count > 0 else { return }
        draftText = result.text
        isDraftDirty = true
        draftEpoch += 1
        scheduleDraftSave()
        noticeMessage = "已替换 \(result.count) 处。"
        exportedWordURL = nil
        recomputeFindHits(preferLocation: 0)
    }

    private var canReplaceInFileDirectly: Bool {
        guard let document = document(in: findPane) else { return false }
        if isEditingContent && editingPane == findPane { return false }
        return document.format == .text || document.sourceText == document.displayText
    }

    private func ensureEditingForReplace() {
        if !(isEditingContent && editingPane == findPane) {
            beginEditing(findPane)
            recomputeFindHits(preferLocation: readingOffset(in: findPane))
        }
    }

    private func applyReplaceInDraft(range: NSRange) {
        let ns = draftText as NSString
        guard NSMaxRange(range) <= ns.length else {
            recomputeFindHits()
            return
        }
        let nextLocation = range.location + (findReplacement as NSString).length
        draftText = ns.replacingCharacters(in: range, with: findReplacement)
        isDraftDirty = true
        draftEpoch += 1
        scheduleDraftSave()
        recomputeFindHits(preferLocation: nextLocation)
    }

    private func replaceInFile(range: NSRange?, replacingAll: Bool) async {
        guard let document = document(in: findPane) else { return }
        let source = document.sourceText
        let updated: String
        let count: Int
        if replacingAll {
            let result = TextSearch.replacing(
                in: source,
                query: findQuery,
                replacement: findReplacement,
                matchCase: findMatchCase
            )
            updated = result.text
            count = result.count
        } else if let range, NSMaxRange(range) <= (source as NSString).length {
            updated = (source as NSString).replacingCharacters(in: range, with: findReplacement)
            count = 1
        } else {
            return
        }
        guard count > 0, updated != source else { return }
        do {
            try validateManagedURL(document.url)
            try await Task.detached {
                try Data(updated.utf8).write(to: document.url, options: .atomic)
            }.value
            applyDocumentSource(updated, in: findPane)
            if replacingAll {
                noticeMessage = "已替换 \(count) 处。"
                exportedWordURL = nil
                recomputeFindHits(preferLocation: 0)
            } else if let range {
                recomputeFindHits(preferLocation: range.location + (findReplacement as NSString).length)
            }
        } catch {
            errorMessage = ReaderError.fileOperationFailed(error.localizedDescription).localizedDescription
        }
    }

    private func restyleEditingDocument() {
        guard isEditingContent, let document = document(in: editingPane) else { return }
        applyDocumentSource(draftText, in: editingPane, existing: document)
    }

    private func applyDocumentSource(_ source: String, in pane: ReaderPane, existing: ReaderDocument? = nil) {
        guard let document = existing ?? document(in: pane) else { return }
        let updated = documentLoader.restyle(document, source: source, preferences: preferences, palette: palette)
        if pane == .primary {
            currentDocument = updated
        } else {
            comparisonDocument = updated
        }
    }

    private func findHaystack() -> String? {
        if isEditingContent, editingPane == findPane {
            return draftText
        }
        return document(in: findPane)?.displayText
    }

    private func recomputeFindHits(preferLocation: Int? = nil) {
        let query = findQuery
        let hits: [NSRange]
        if query.isEmpty {
            hits = []
        } else if let text = findHaystack() {
            hits = TextSearch.matches(in: text, query: query, matchCase: findMatchCase)
        } else {
            hits = []
        }
        findHits = hits
        if hits.isEmpty {
            findIndex = 0
            publishFindHighlight()
            return
        }
        let target = preferLocation ?? readingOffset(in: findPane)
        findIndex = preferLocation == nil
            ? TextSearch.index(nearestTo: target, in: hits)
            : TextSearch.index(atOrAfter: target, in: hits)
        revealCurrentFindHit()
    }

    private func revealCurrentFindHit() {
        publishFindHighlight()
        guard findHits.indices.contains(findIndex) else { return }
        let offset = findHits[findIndex].location
        if findPane == .primary {
            requestLocation(offset)
        } else {
            requestComparisonLocation(offset)
        }
        updateReadingOffset(offset, in: findPane)
        focusPane(findPane)
    }

    private func publishFindHighlight() {
        guard findBarPresented, findHits.indices.contains(findIndex) else {
            findHighlight = .none
            return
        }
        let current = findHits[findIndex]
        let start = max(0, findIndex - 40)
        let end = min(findHits.count, findIndex + 41)
        let neighbors = Array(findHits[start..<end].filter { $0 != current })
        findHighlight = SearchHighlightRequest(current: current, neighbors: neighbors)
    }

    private func refreshFindHitsIfNeeded() {
        guard findBarPresented else { return }
        if document(in: findPane) == nil {
            dismissFindBar()
            return
        }
        scheduleFindSearch(immediate: true)
    }

    @discardableResult
    func moveDocument(by delta: Int, in pane: ReaderPane? = nil) -> Bool {
        let pane = pane ?? activeReaderPane
        guard delta != 0, let currentDocument = document(in: pane) else { return false }
        let documents = flattenedDocuments(in: nodes(for: pane))
        guard let currentIndex = documents.firstIndex(where: { $0.id == currentDocument.id }) else {
            return false
        }
        let targetIndex = currentIndex + delta
        guard documents.indices.contains(targetIndex) else { return false }
        if pane == .primary {
            openDocument(documents[targetIndex])
        } else {
            openComparisonDocument(documents[targetIndex])
        }
        return true
    }

    func document(in pane: ReaderPane) -> ReaderDocument? {
        pane == .primary ? currentDocument : comparisonDocument
    }

    private func isEditingThis(_ document: ReaderDocument) -> Bool {
        isEditingContent && self.document(in: editingPane)?.id == document.id
    }

    func readingOffset(in pane: ReaderPane) -> Int {
        pane == .primary ? readingOffset : comparisonReadingOffset
    }

    func readingPercentage(in pane: ReaderPane) -> Int {
        guard let document = document(in: pane), document.characterCount > 0 else { return 0 }
        return Int((Double(readingOffset(in: pane)) / Double(document.characterCount) * 100).rounded())
    }

    func chapter(in pane: ReaderPane) -> Chapter? {
        let offset = readingOffset(in: pane)
        return document(in: pane)?.chapters.last { $0.offset <= offset }
    }

    func locationRequest(in pane: ReaderPane) -> ReadingLocationRequest {
        pane == .primary ? locationRequest : comparisonLocationRequest
    }

    private func restoreLibraries() async {
        let urls = bookmarkStore.restoreAll()
        libraries = urls.map(Self.librarySource)
        guard !libraries.isEmpty else { return }

        migrateLegacyLastDocumentIfNeeded()
        let savedID = UserDefaults.standard.string(forKey: Keys.activeLibraryID)
        let library = libraries.first(where: { $0.id == savedID }) ?? libraries[0]
        await activateLibrary(library)
    }

    private func openExternalFile(_ url: URL) async {
        let fileURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard fileURL.isFileURL else { return }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        if accessed {
            bookmarkStore.access(fileURL)
        }

        guard Self.isSupportedDocument(fileURL) else {
            errorMessage = "竹点阅读只打开 TXT 与 Markdown 文件。"
            return
        }

        let folder = fileURL.deletingLastPathComponent()
        if let libraryID = owningLibraryID(for: fileURL),
           let library = libraries.first(where: { $0.id == libraryID }) {
            await presentLibrary(library, opening: fileURL)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        do {
            let accessibleFolder = try bookmarkStore.rememberAndAccess(folder)
            let source = Self.librarySource(accessibleFolder)
            if !libraries.contains(where: { $0.id == source.id }) {
                libraries.append(source)
            }
            await presentLibrary(source, opening: fileURL)
        } catch {
            await presentStandaloneFile(fileURL, folder: folder)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentLibrary(_ library: LibrarySource, opening fileURL: URL) async {
        await finishEditing()
        bookmarkStore.access(library.url)
        bookmarkStore.access(fileURL)
        if comparisonDocument != nil || isPickingComparison {
            tearDownComparison()
        }
        activeLibraryID = library.id
        primaryLibraryID = library.id
        UserDefaults.standard.set(library.id, forKey: Keys.activeLibraryID)
        renamingNodeID = nil
        if libraryNodeCache[library.id] == nil {
            await scanLibrary(library, restoreDocument: nil, shouldOpen: false)
        }
        if (libraryNodeCache[library.id] ?? []).isEmpty {
            let node = LibraryNode(
                id: fileURL.path,
                name: fileURL.deletingPathExtension().lastPathComponent,
                url: fileURL,
                kind: .document,
                children: []
            )
            publishSidebarNodes([node], for: library.id)
        } else {
            publishSidebarNodes(libraryNodeCache[library.id] ?? [], for: library.id)
        }
        await loadDocument(at: fileURL, libraryID: library.id)
        expandAncestors(of: fileURL)
    }

    private func presentStandaloneFile(_ fileURL: URL, folder: URL) async {
        await finishEditing()
        if comparisonDocument != nil || isPickingComparison {
            tearDownComparison()
        }
        let source = Self.librarySource(folder)
        if !libraries.contains(where: { $0.id == source.id }) {
            libraries.append(source)
        }
        let node = LibraryNode(
            id: fileURL.path,
            name: fileURL.deletingPathExtension().lastPathComponent,
            url: fileURL,
            kind: .document,
            children: []
        )
        publishSidebarNodes([node], for: source.id)
        activeLibraryID = source.id
        primaryLibraryID = source.id
        renamingNodeID = nil
        await loadDocument(at: fileURL, libraryID: source.id)
    }

    private func installLibrary(_ url: URL) async {
        do {
            let accessibleURL = try bookmarkStore.rememberAndAccess(url)
            let source = Self.librarySource(accessibleURL)
            if !libraries.contains(where: { $0.id == source.id }) {
                libraries.append(source)
            }
            if showsComparisonLayout {
                await activateComparisonLibrary(source)
            } else {
                await activateLibrary(source)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func activateLibrary(_ library: LibrarySource) async {
        await finishEditing()
        bookmarkStore.access(library.url)
        activeLibraryID = library.id
        primaryLibraryID = library.id
        UserDefaults.standard.set(library.id, forKey: Keys.activeLibraryID)
        comparisonDocument = nil
        comparisonLibraryID = nil
        comparisonSidebarNodes = []
        isPickingComparison = false
        isLoadingComparison = false
        activeReaderPane = .primary
        renamingNodeID = nil
        if let cached = libraryNodeCache[library.id] {
            publishSidebarNodes(cached, for: library.id)
            await openPreferredDocument(
                in: cached,
                library: library,
                path: lastDocumentByLibrary[library.id]
            )
            return
        }
        await scanLibrary(library, restoreDocument: lastDocumentByLibrary[library.id], shouldOpen: true)
    }

    private func activateComparisonLibrary(_ library: LibrarySource) async {
        guard currentDocument != nil else {
            await activateLibrary(library)
            return
        }
        if comparisonDocument == nil {
            isPickingComparison = true
        }
        comparisonLibraryID = library.id
        if let cached = libraryNodeCache[library.id] {
            publishSidebarNodes(cached, for: library.id)
        }
        focusPane(.comparison)
        await ensureLibraryCached(library)
    }

    private func ensureLibraryCached(_ library: LibrarySource) async {
        bookmarkStore.access(library.url)
        guard libraryNodeCache[library.id] == nil else { return }
        await scanLibrary(library, restoreDocument: nil, shouldOpen: false)
    }

    private func scanLibrary(
        _ library: LibrarySource,
        restoreDocument path: String?,
        shouldOpen: Bool
    ) async {
        let quiet = libraryNodeCache[library.id] != nil
        if !quiet {
            isLoading = true
        }
        errorMessage = nil
        do {
            let nodes = try await scanner.scan(library.url)
            publishSidebarNodes(nodes, for: library.id)
            isLoading = false
            guard shouldOpen, primaryLibraryID == library.id else { return }
            await openPreferredDocument(in: nodes, library: library, path: path)
        } catch {
            isLoading = false
            if primaryLibraryID == library.id {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadDocument(at url: URL, libraryID: String? = nil) async {
        let targetLibraryID = libraryID ?? owningLibraryID(for: url) ?? activeLibraryID
        guard let targetLibraryID, libraries.contains(where: { $0.id == targetLibraryID }) else { return }
        let requestID = UUID()
        primaryDocumentRequestID = requestID
        await finishEditing()
        errorMessage = nil
        do {
            if let library = libraries.first(where: { $0.id == targetLibraryID }) {
                bookmarkStore.access(library.url)
            }
            let document = try await preparedDocument(at: url)
            guard primaryDocumentRequestID == requestID,
                  libraries.contains(where: { $0.id == targetLibraryID }) else { return }
            currentDocument = document
            primaryLibraryID = targetLibraryID
            selectedDocumentID = document.id
            expandAncestors(of: document.url)
            lastDocumentByLibrary[targetLibraryID] = document.id
            persistLastDocuments()
            let offset = min(progressByPath[document.id]?.characterOffset ?? 0, document.characterCount)
            readingOffset = offset
            requestLocation(offset)
            if findPane == .primary {
                refreshFindHitsIfNeeded()
            }
        } catch {
            if primaryDocumentRequestID == requestID {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadComparisonDocument(at url: URL, libraryID: String? = nil) async {
        let targetLibraryID = libraryID ?? owningLibraryID(for: url) ?? activeLibraryID
        guard let targetLibraryID, libraries.contains(where: { $0.id == targetLibraryID }) else { return }
        let requestID = UUID()
        comparisonDocumentRequestID = requestID
        if isEditingContent, editingPane == .comparison {
            await finishEditing()
        }
        isLoadingComparison = true
        errorMessage = nil
        do {
            if let library = libraries.first(where: { $0.id == targetLibraryID }) {
                bookmarkStore.access(library.url)
            }
            let document = try await preparedDocument(at: url)
            guard comparisonDocumentRequestID == requestID,
                  libraries.contains(where: { $0.id == targetLibraryID }) else { return }
            comparisonDocument = document
            comparisonLibraryID = targetLibraryID
            isPickingComparison = false
            isLoadingComparison = false
            comparisonReadingOffset = min(
                progressByPath[document.id]?.characterOffset ?? 0,
                document.characterCount
            )
            requestComparisonLocation(comparisonReadingOffset)
            lastDocumentByLibrary[targetLibraryID] = document.id
            persistLastDocuments()
            focusPane(.comparison)
            if findPane == .comparison {
                refreshFindHitsIfNeeded()
            }
        } catch {
            guard comparisonDocumentRequestID == requestID else { return }
            isLoadingComparison = false
            if comparisonDocument == nil {
                isPickingComparison = true
            }
            errorMessage = error.localizedDescription
        }
    }

    private func openPreferredDocument(
        in nodes: [LibraryNode],
        library: LibrarySource,
        path: String?
    ) async {
        guard primaryLibraryID == library.id else { return }
        if let path, let node = findDocument(path: path, in: nodes) {
            await loadDocument(at: node.url, libraryID: library.id)
        } else if let first = firstDocument(in: nodes) {
            await loadDocument(at: first.url, libraryID: library.id)
        } else {
            currentDocument = nil
            selectedDocumentID = nil
            readingOffset = 0
        }
    }

    private func preparedDocument(at url: URL) async throws -> ReaderDocument {
        if let cached = cachedDocument(at: url) {
            return cached
        }

        let loadingPreferences = preferences
        let loadingPalette = palette
        let document = try await Task.detached(priority: .userInitiated) { [documentLoader] in
            try documentLoader.load(
                url: url,
                preferences: loadingPreferences,
                palette: loadingPalette
            )
        }.value

        if loadingPreferences == preferences {
            cacheDocument(document, preferences: loadingPreferences)
            return document
        }

        let currentPreferences = preferences
        let currentPalette = palette
        let restyled = await Task.detached(priority: .userInitiated) { [documentLoader] in
            documentLoader.restyle(
                document,
                preferences: currentPreferences,
                palette: currentPalette
            )
        }.value
        cacheDocument(restyled, preferences: currentPreferences)
        return restyled
    }

    private func scheduleDocumentRestyle() {
        restyleTask?.cancel()
        guard currentDocument != nil || comparisonDocument != nil else { return }

        let targetPreferences = preferences
        let targetPalette = palette
        let primarySnapshot = currentDocument
        let comparisonSnapshot = comparisonDocument
        let primarySource = primarySnapshot.map {
            isEditingContent && editingPane == .primary ? draftText : $0.sourceText
        }
        let comparisonSource = comparisonSnapshot.map {
            isEditingContent && editingPane == .comparison ? draftText : $0.sourceText
        }

        restyleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }

            let results = await Task.detached(priority: .userInitiated) { [documentLoader] in
                let primary = primarySnapshot.map {
                    documentLoader.restyle(
                        $0,
                        source: primarySource,
                        preferences: targetPreferences,
                        palette: targetPalette
                    )
                }
                let comparison = comparisonSnapshot.map {
                    documentLoader.restyle(
                        $0,
                        source: comparisonSource,
                        preferences: targetPreferences,
                        palette: targetPalette
                    )
                }
                return (primary, comparison)
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.preferences == targetPreferences else { return }

            if let original = primarySnapshot,
               let restyled = results.0,
               self.currentDocument?.id == original.id {
                self.currentDocument = restyled
                self.cacheDocument(restyled, preferences: targetPreferences)
                self.requestLocation(self.readingOffset)
            }
            if let original = comparisonSnapshot,
               let restyled = results.1,
               self.comparisonDocument?.id == original.id {
                self.comparisonDocument = restyled
                self.cacheDocument(restyled, preferences: targetPreferences)
                self.requestComparisonLocation(self.comparisonReadingOffset)
            }
        }
    }

    private func cachedDocument(at url: URL) -> ReaderDocument? {
        let path = url.standardizedFileURL.path
        guard let stamp = documentFileStamp(for: url),
              let entry = documentCache[path],
              entry.fileStamp == stamp,
              entry.preferences == preferences else {
            documentCache.removeValue(forKey: path)
            documentCacheOrder.removeAll { $0 == path }
            return nil
        }
        touchCachedDocument(path)
        return entry.document
    }

    private func cacheDocument(_ document: ReaderDocument, preferences: ReaderPreferences) {
        guard let stamp = documentFileStamp(for: document.url) else { return }
        documentCache[document.id] = DocumentCacheEntry(
            document: document,
            fileStamp: stamp,
            preferences: preferences
        )
        touchCachedDocument(document.id)

        while cachedDocumentCharacterCount > Self.documentCacheCharacterLimit,
              documentCacheOrder.count > 1 {
            let removedPath = documentCacheOrder.removeFirst()
            documentCache.removeValue(forKey: removedPath)
        }
    }

    private func touchCachedDocument(_ path: String) {
        documentCacheOrder.removeAll { $0 == path }
        documentCacheOrder.append(path)
    }

    private var cachedDocumentCharacterCount: Int {
        documentCache.values.reduce(0) { $0 + $1.document.characterCount }
    }

    private func documentFileStamp(for url: URL) -> DocumentFileStamp? {
        guard let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ]) else { return nil }
        return DocumentFileStamp(
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize
        )
    }

    private func requestLocation(_ offset: Int) {
        locationRequest = ReadingLocationRequest(offset: offset)
    }

    private func requestComparisonLocation(_ offset: Int) {
        comparisonLocationRequest = ReadingLocationRequest(offset: offset)
    }

    private func scheduleProgressSave() {
        progressSaveTask?.cancel()
        progressSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.persistProgress()
        }
    }

    private func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Keys.preferences)
    }

    private func validatedName(_ proposedName: String, for node: LibraryNode) throws -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains(":") else {
            throw ReaderError.invalidFileName
        }
        guard node.kind == .document else { return trimmed }
        let fileExtension = node.url.pathExtension
        if trimmed.lowercased().hasSuffix(".\(fileExtension.lowercased())") {
            return trimmed
        }
        return "\(trimmed).\(fileExtension)"
    }

    private func moveItem(_ node: LibraryNode, to destinationURL: URL) throws {
        let source = node.url.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        try validateManagedURL(source)
        try validateManagedURL(destination.deletingLastPathComponent())

        guard source.path != destination.path else { return }
        if node.kind == .folder,
           destination.path.hasPrefix(source.path + "/") {
            throw ReaderError.invalidMove("不能把文件夹移动到它自身里面。")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ReaderError.itemAlreadyExists(destination.lastPathComponent)
        }

        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw ReaderError.fileOperationFailed(error.localizedDescription)
        }

        let preferredComparisonPath = comparisonDocument.map {
            remapPath($0.id, from: source.path, to: destination.path)
        }
        let preferredPath = remapState(from: source.path, to: destination.path)
        Task {
            await reloadAfterFileOperation(
                preferredDocumentPath: preferredPath,
                preferredComparisonPath: preferredComparisonPath
            )
        }
    }

    private func validateManagedURL(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let isManaged = libraries.contains { library in
            let rootPath = library.url.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        guard isManaged else {
            throw ReaderError.invalidMove("文件操作不能超出已打开的书库。")
        }
    }

    private func remapState(from oldPrefix: String, to newPrefix: String) -> String? {
        let progressMatches = progressByPath.filter { path, _ in
            path == oldPrefix || path.hasPrefix(oldPrefix + "/")
        }
        for (path, progress) in progressMatches {
            progressByPath.removeValue(forKey: path)
            progressByPath[remapPath(path, from: oldPrefix, to: newPrefix)] = progress
        }
        persistProgress()

        expandedFolderIDs = Set(expandedFolderIDs.map { path in
            path == oldPrefix || path.hasPrefix(oldPrefix + "/")
                ? remapPath(path, from: oldPrefix, to: newPrefix)
                : path
        })

        var preferredPath = currentDocument?.id
        if let currentPath = preferredPath,
           currentPath == oldPrefix || currentPath.hasPrefix(oldPrefix + "/") {
            preferredPath = remapPath(currentPath, from: oldPrefix, to: newPrefix)
        }
        if let activeLibraryID,
           let lastPath = lastDocumentByLibrary[activeLibraryID],
           lastPath == oldPrefix || lastPath.hasPrefix(oldPrefix + "/") {
            lastDocumentByLibrary[activeLibraryID] = remapPath(lastPath, from: oldPrefix, to: newPrefix)
            persistLastDocuments()
        }
        return preferredPath
    }

    private func removeState(forPathPrefix prefix: String) {
        for path in Array(progressByPath.keys) where path == prefix || path.hasPrefix(prefix + "/") {
            progressByPath.removeValue(forKey: path)
        }
        persistProgress()
        expandedFolderIDs = expandedFolderIDs.filter { path in
            path != prefix && !path.hasPrefix(prefix + "/")
        }
        if let activeLibraryID,
           let lastPath = lastDocumentByLibrary[activeLibraryID],
           lastPath == prefix || lastPath.hasPrefix(prefix + "/") {
            lastDocumentByLibrary.removeValue(forKey: activeLibraryID)
            persistLastDocuments()
        }
        if let selectedDocumentID,
           selectedDocumentID == prefix || selectedDocumentID.hasPrefix(prefix + "/") {
            currentDocument = nil
            self.selectedDocumentID = nil
            readingOffset = 0
            if isEditingContent, editingPane == .primary {
                isEditingContent = false
                draftText = ""
                isDraftDirty = false
            }
        }
        if let comparisonDocument,
           comparisonDocument.id == prefix || comparisonDocument.id.hasPrefix(prefix + "/") {
            if isEditingContent, editingPane == .comparison {
                isEditingContent = false
                draftText = ""
                isDraftDirty = false
            }
            tearDownComparison()
        }
    }

    private func reloadAfterFileOperation(
        preferredDocumentPath: String?,
        preferredComparisonPath: String?
    ) async {
        guard let activeLibrary else { return }
        do {
            let nodes = try await scanner.scan(activeLibrary.url)
            publishSidebarNodes(nodes, for: activeLibrary.id)

            if let path = preferredDocumentPath, let node = findDocument(path: path, in: nodes) {
                if currentDocument?.id == path {
                    selectedDocumentID = path
                    expandAncestors(of: node.url)
                } else {
                    await loadDocument(at: node.url, libraryID: activeLibrary.id)
                }
            } else if let currentDocument,
                      owningLibraryID(for: currentDocument.url) == activeLibrary.id,
                      findDocument(path: currentDocument.id, in: nodes) == nil {
                isEditingContent = false
                draftText = ""
                isDraftDirty = false
                if let first = firstDocument(in: nodes) {
                    await loadDocument(at: first.url, libraryID: activeLibrary.id)
                } else {
                    self.currentDocument = nil
                    selectedDocumentID = nil
                    readingOffset = 0
                }
            }

            if let path = preferredComparisonPath,
               let node = findDocument(path: path, in: nodes) {
                if comparisonDocument?.id != path {
                    await loadComparisonDocument(at: node.url, libraryID: activeLibrary.id)
                } else {
                    expandAncestors(of: node.url)
                }
            } else if let comparisonDocument,
                      owningLibraryID(for: comparisonDocument.url) == activeLibrary.id {
                closeComparison()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remapPath(_ path: String, from oldPrefix: String, to newPrefix: String) -> String {
        guard path == oldPrefix || path.hasPrefix(oldPrefix + "/") else { return path }
        return path == oldPrefix ? newPrefix : newPrefix + path.dropFirst(oldPrefix.count)
    }

    private func persistProgress() {
        guard let data = try? JSONEncoder().encode(progressByPath) else { return }
        UserDefaults.standard.set(data, forKey: Keys.progress)
    }

    private func persistLastDocuments() {
        guard let data = try? JSONEncoder().encode(lastDocumentByLibrary) else { return }
        UserDefaults.standard.set(data, forKey: Keys.lastDocumentsByLibrary)
    }

    private static func loadPreferences() -> ReaderPreferences {
        guard let data = UserDefaults.standard.data(forKey: Keys.preferences),
              let preferences = try? JSONDecoder().decode(ReaderPreferences.self, from: data) else {
            return ReaderPreferences()
        }
        return preferences
    }

    private static func loadProgress() -> [String: ReadingProgress] {
        guard let data = UserDefaults.standard.data(forKey: Keys.progress),
              let progress = try? JSONDecoder().decode([String: ReadingProgress].self, from: data) else {
            return [:]
        }
        return progress
    }

    private static func loadLastDocuments() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: Keys.lastDocumentsByLibrary),
              let documents = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return documents
    }

    private static func librarySource(_ url: URL) -> LibrarySource {
        let standardizedURL = url.standardizedFileURL
        return LibrarySource(
            id: standardizedURL.path,
            name: standardizedURL.lastPathComponent,
            url: standardizedURL
        )
    }

    private static let supportedDocumentExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "mdwn"
    ]

    private static var supportedDocumentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        for ext in ["md", "markdown", "mdown", "txt"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    private static func isSupportedDocument(_ url: URL) -> Bool {
        supportedDocumentExtensions.contains(url.pathExtension.lowercased())
    }

    private func migrateLegacyLastDocumentIfNeeded() {
        guard lastDocumentByLibrary.isEmpty,
              let path = UserDefaults.standard.string(forKey: Keys.lastDocumentPath),
              let library = libraries.first(where: { path.hasPrefix($0.id + "/") }) else { return }
        lastDocumentByLibrary[library.id] = path
        persistLastDocuments()
        UserDefaults.standard.removeObject(forKey: Keys.lastDocumentPath)
    }

    private func findDocument(path: String, in nodes: [LibraryNode]) -> LibraryNode? {
        for node in nodes {
            if node.kind == .document, node.id == path { return node }
            if let match = findDocument(path: path, in: node.children) { return match }
        }
        return nil
    }

    private func findNode(path: String, in nodes: [LibraryNode]) -> LibraryNode? {
        for node in nodes {
            if node.id == path { return node }
            if let match = findNode(path: path, in: node.children) { return match }
        }
        return nil
    }

    private func firstDocument(in nodes: [LibraryNode]) -> LibraryNode? {
        for node in nodes {
            if node.kind == .document { return node }
            if let document = firstDocument(in: node.children) { return document }
        }
        return nil
    }

    private func flattenedDocuments(in nodes: [LibraryNode]) -> [LibraryNode] {
        nodes.flatMap { node in
            node.kind == .document ? [node] : flattenedDocuments(in: node.children)
        }
    }

    private func replacementDocumentPath(
        for currentPath: String?,
        removing node: LibraryNode,
        in nodes: [LibraryNode]
    ) -> String? {
        guard let currentPath else { return nil }
        let removesCurrent = currentPath == node.id || currentPath.hasPrefix(node.id + "/")
        guard removesCurrent else { return currentPath }

        let documents = flattenedDocuments(in: nodes)
        let removedIndexes = documents.indices.filter { index in
            let path = documents[index].id
            return path == node.id || path.hasPrefix(node.id + "/")
        }
        guard let firstRemoved = removedIndexes.first,
              let lastRemoved = removedIndexes.last else { return nil }

        let nextIndex = lastRemoved + 1
        if documents.indices.contains(nextIndex) {
            return documents[nextIndex].id
        }

        let previousIndex = firstRemoved - 1
        return documents.indices.contains(previousIndex) ? documents[previousIndex].id : nil
    }

    private func finishEditing() async {
        guard isEditingContent else { return }
        await saveDraftIfNeeded()
        let source = draftText
        let pane = editingPane
        isEditingContent = false
        isDraftDirty = false
        if pane == .comparison, let comparisonDocument {
            self.comparisonDocument = documentLoader.restyle(
                comparisonDocument,
                source: source,
                preferences: preferences,
                palette: palette
            )
            requestComparisonLocation(comparisonReadingOffset)
        } else if let currentDocument {
            self.currentDocument = documentLoader.restyle(
                currentDocument,
                source: source,
                preferences: preferences,
                palette: palette
            )
            requestLocation(readingOffset)
        }
        editingPane = .primary
    }

    private func saveDraftIfNeeded() async {
        guard isDraftDirty, let url = document(in: editingPane)?.url else { return }
        let text = draftText
        do {
            try validateManagedURL(url)
            try await Task.detached {
                try Data(text.utf8).write(to: url, options: .atomic)
            }.value
            isDraftDirty = false
        } catch {
            errorMessage = ReaderError.fileOperationFailed(error.localizedDescription).localizedDescription
        }
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            await self.saveDraftIfNeeded()
        }
    }

    private func insertionDirectory(relativeTo node: LibraryNode?) throws -> URL {
        if let node {
            let directory = node.kind == .folder ? node.url : node.url.deletingLastPathComponent()
            try validateManagedURL(directory)
            return directory.standardizedFileURL
        }
        if let currentDocument {
            let directory = currentDocument.url.deletingLastPathComponent()
            try validateManagedURL(directory)
            return directory.standardizedFileURL
        }
        guard let root = libraryRootURL else {
            throw ReaderError.invalidMove("请先选择书库。")
        }
        return root.standardizedFileURL
    }

    private func uniqueItemName(in directory: URL, base: String, ext: String?) -> String {
        func candidate(_ index: Int) -> String {
            let stem = index == 1 ? base : "\(base) \(index)"
            return ext.map { "\(stem).\($0)" } ?? stem
        }
        var index = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate(index)).path) {
            index += 1
        }
        return candidate(index)
    }

    private func owningLibraryID(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return libraries.first { path == $0.id || path.hasPrefix($0.id + "/") }?.id
    }

    private func nodes(for pane: ReaderPane) -> [LibraryNode] {
        nodes(forLibraryID: pane == .primary ? primaryLibraryID : comparisonLibraryID)
    }

    private func nodes(forLibraryID libraryID: String?) -> [LibraryNode] {
        guard let libraryID else { return libraryNodes }
        if libraryID == comparisonLibraryID, comparisonLibraryID != primaryLibraryID {
            return comparisonSidebarNodes.isEmpty ? (libraryNodeCache[libraryID] ?? []) : comparisonSidebarNodes
        }
        if libraryID == primaryLibraryID, !libraryNodes.isEmpty {
            return libraryNodes
        }
        return libraryNodeCache[libraryID] ?? libraryNodes
    }

    private func publishSidebarNodes(_ nodes: [LibraryNode], for libraryID: String) {
        libraryNodeCache[libraryID] = nodes
        if libraryID == primaryLibraryID {
            libraryNodes = nodes
        }
        if libraryID == comparisonLibraryID {
            comparisonSidebarNodes = nodes
        }
    }

    private func expandAncestors(of documentURL: URL) {
        guard let rootPath = owningLibraryID(for: documentURL) else { return }
        var folder = documentURL.deletingLastPathComponent().standardizedFileURL
        while folder.path != rootPath, folder.path.hasPrefix(rootPath + "/") {
            expandedFolderIDs.insert(folder.path)
            folder.deleteLastPathComponent()
        }
    }
}

struct ReadingLocationRequest: Equatable {
    let id = UUID()
    let offset: Int
}

struct SearchHighlightRequest: Equatable {
    let id: UUID
    var current: NSRange?
    var neighbors: [NSRange]

    static let none = SearchHighlightRequest(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        current: nil,
        neighbors: []
    )

    init(current: NSRange? = nil, neighbors: [NSRange] = []) {
        self.id = UUID()
        self.current = current
        self.neighbors = neighbors
    }

    private init(id: UUID, current: NSRange?, neighbors: [NSRange]) {
        self.id = id
        self.current = current
        self.neighbors = neighbors
    }
}

struct FindJumpItem: Equatable {
    let index: Int
    let snippet: String
}
