import Foundation

actor LibraryScanner {
    private let supportedExtensions: Set<String> = ["txt", "md"]
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .nameKey
    ]

    func scan(_ root: URL) throws -> [LibraryNode] {
        try scanDirectory(root)
    }

    private func scanDirectory(_ directory: URL) throws -> [LibraryNode] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var nodes: [LibraryNode] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: resourceKeys)
            if values.isHidden == true || values.isSymbolicLink == true {
                continue
            }

            if values.isDirectory == true {
                let children = try scanDirectory(url)
                nodes.append(
                    LibraryNode(
                        id: url.standardizedFileURL.path,
                        name: values.name ?? url.lastPathComponent,
                        url: url,
                        kind: .folder,
                        children: children
                    )
                )
            } else if values.isRegularFile == true,
                      supportedExtensions.contains(url.pathExtension.lowercased()) {
                nodes.append(
                    LibraryNode(
                        id: url.standardizedFileURL.path,
                        name: url.deletingPathExtension().lastPathComponent,
                        url: url,
                        kind: .document,
                        children: []
                    )
                )
            }
        }

        return nodes.sorted {
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
