import Foundation

@MainActor
final class SecurityScopedBookmarkStore {
    private enum Keys {
        static let libraryBookmark = "zhudot.reader.libraryBookmark"
        static let libraryBookmarks = "zhudot.reader.libraryBookmarks"
    }

    private var accessedURLs: [String: URL] = [:]

    deinit {
        for url in accessedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func rememberAndAccess(_ url: URL) throws -> URL {
        let standardizedURL = url.standardizedFileURL
        let data = try standardizedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = storedBookmarks()
        let existingPaths = resolve(bookmarks).map(\.url.standardizedFileURL.path)
        if !existingPaths.contains(standardizedURL.path) {
            bookmarks.append(data)
            save(bookmarks)
        }
        access(standardizedURL)
        return standardizedURL
    }

    func restoreAll() -> [URL] {
        var bookmarks = storedBookmarks()
        if bookmarks.isEmpty,
           let legacy = UserDefaults.standard.data(forKey: Keys.libraryBookmark) {
            bookmarks = [legacy]
            save(bookmarks)
            UserDefaults.standard.removeObject(forKey: Keys.libraryBookmark)
        }

        let resolved = resolve(bookmarks)
        if resolved.count != bookmarks.count || resolved.contains(where: \.isStale) {
            let refreshed = resolved.compactMap { item in
                try? item.url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
            save(refreshed)
        }
        let urls = resolved.map(\.url)
        accessAll(urls)
        return urls
    }

    func access(_ url: URL) {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard accessedURLs[path] == nil else { return }
        if standardized.startAccessingSecurityScopedResource() {
            accessedURLs[path] = standardized
        }
    }

    func accessAll(_ urls: [URL]) {
        urls.forEach(access)
    }

    func remove(_ url: URL) {
        let targetPath = url.standardizedFileURL.path
        let remaining = storedBookmarks().filter { data in
            resolvedBookmark(data)?.url.standardizedFileURL.path != targetPath
        }
        save(remaining)
        stopAccessing(url)
    }

    func clearAll() {
        for url in accessedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
        UserDefaults.standard.removeObject(forKey: Keys.libraryBookmark)
        UserDefaults.standard.removeObject(forKey: Keys.libraryBookmarks)
    }

    private func stopAccessing(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let accessed = accessedURLs.removeValue(forKey: path) {
            accessed.stopAccessingSecurityScopedResource()
        }
    }

    private func storedBookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: Keys.libraryBookmarks) as? [Data] ?? []
    }

    private func save(_ bookmarks: [Data]) {
        UserDefaults.standard.set(bookmarks, forKey: Keys.libraryBookmarks)
    }

    private func resolve(_ bookmarks: [Data]) -> [(url: URL, isStale: Bool)] {
        var paths = Set<String>()
        return bookmarks.compactMap { data in
            guard let item = resolvedBookmark(data), paths.insert(item.url.path).inserted else {
                return nil
            }
            return item
        }
    }

    private func resolvedBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL else {
            return nil
        }
        return (url, isStale)
    }
}
