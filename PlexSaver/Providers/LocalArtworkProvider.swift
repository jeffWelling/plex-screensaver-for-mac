import AppKit
import CryptoKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

/// Folder access comes only from the user's folder picker. Read-only scoped
/// bookmarks are retained instead of a path-based permission workaround.
enum LocalArtworkFolder {
    static func bookmark(for url: URL) throws -> Data {
        guard url.isFileURL else { throw LocalArtworkError.invalidFolder }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try validate(url)
        return try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(bookmarkData: Data) throws -> URL {
        guard !bookmarkData.isEmpty else { throw LocalArtworkError.chooseFolderAgain }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw LocalArtworkError.chooseFolderAgain }
        guard !stale, url.isFileURL else { throw LocalArtworkError.chooseFolderAgain }
        return url
    }

    static func identity(for url: URL) -> String {
        hash(url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    static func displayName(bookmarkData: Data) -> String? {
        (try? resolve(bookmarkData: bookmarkData))?.lastPathComponent
    }

    fileprivate static func validate(_ url: URL) throws {
        guard url.isFileURL else { throw LocalArtworkError.invalidFolder }
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey]) }
        catch { throw LocalArtworkError.chooseFolderAgain }
        guard values.isDirectory == true else { throw LocalArtworkError.invalidFolder }
        guard values.isReadable != false else { throw LocalArtworkError.chooseFolderAgain }
    }

    fileprivate static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum LocalArtworkError: Error, LocalizedError, Equatable {
    case invalidFolder, chooseFolderAgain, missingArtwork, tooManyFiles
    var errorDescription: String? {
        switch self {
        case .invalidFolder: return "Choose a folder containing artwork."
        case .chooseFolderAgain: return "The artwork folder is unavailable. Choose it again in Options."
        case .missingArtwork: return "This artwork is no longer available in the selected folder."
        case .tooManyFiles: return "This folder contains too many files. Choose a smaller artwork folder."
        }
    }
}

/// One account-free local library. File names are used only for captions; IDs
/// and artwork keys are opaque hashes. Hidden files, packages and symlinks are
/// skipped. The selected folder's descriptor anchors every subsequent read.
actor LocalArtworkProvider: MediaProvider {
    nonisolated let serverName: String
    nonisolated let filterCapabilities = MediaFilterCapabilities()
    private let scopedURL: URL
    private let rootURL: URL
    private let scopeAccessing: Bool
    private let rootDescriptor: Int32
    private var artworkFiles: [String: String] = [:]
    static let libraryID = "local-artwork"
    static let maximumFiles = 50_000

    init(bookmarkData: Data) throws {
        let url = try LocalArtworkFolder.resolve(bookmarkData: bookmarkData)
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            try LocalArtworkFolder.validate(url)
            let root = url.standardizedFileURL.resolvingSymlinksInPath()
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw LocalArtworkError.chooseFolderAgain }
            scopedURL = url
            rootURL = root
            scopeAccessing = accessing
            rootDescriptor = descriptor
            serverName = url.lastPathComponent
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit {
        close(rootDescriptor)
        if scopeAccessing { scopedURL.stopAccessingSecurityScopedResource() }
    }

    func fetchLibraries() async throws -> [MediaLibrary] {
        try Task.checkCancellation()
        return [MediaLibrary(id: Self.libraryID, name: serverName, type: "photos")]
    }

    func fetchItems(libraryId: String) async throws -> [MediaItem] {
        guard libraryId == Self.libraryID else { return [] }
        return try scan()
    }

    func fetchImage(path: String, width: Int, height: Int) async throws -> NSImage {
        try Task.checkCancellation()
        // Cached catalogue metadata can be used before the first server refresh.
        if artworkFiles[path] == nil { _ = try scan() }
        guard let relative = artworkFiles[path] else { throw LocalArtworkError.missingArtwork }
        let descriptor = try openArtwork(relativePath: relative)
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try file.read(upToCount: URLSessionTransport.maximumImageBytes + 1) ?? Data()
        try Task.checkCancellation()
        guard data.count <= URLSessionTransport.maximumImageBytes else { throw MediaNetworkError.oversizedPayload }
        return try ArtworkDecoder.decode(data, width: width, height: height)
    }

    private func scan() throws -> [MediaItem] {
        try Task.checkCancellation()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
                                      .fileSizeKey, .contentModificationDateKey, .contentTypeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw LocalArtworkError.chooseFolderAgain }
        let supported = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        var result: [MediaItem] = []
        var files: [String: String] = [:]
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            guard visited <= Self.maximumFiles else { throw LocalArtworkError.tooManyFiles }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true,
                  let size = values.fileSize, size > 0, size <= URLSessionTransport.maximumImageBytes,
                  let type = values.contentType,
                  type.conforms(to: .image), supported.contains(type.identifier) else { continue }
            let relative = String(url.path.dropFirst(rootURL.path.count + 1))
            guard !relative.isEmpty, url.path.hasPrefix(rootURL.path + "/") else { continue }
            let identity = LocalArtworkFolder.hash(relative)
            let revision = LocalArtworkFolder.hash("\(relative)|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            files[revision] = relative
            result.append(MediaItem(id: identity, title: url.deletingPathExtension().lastPathComponent,
                year: nil, artPaths: [.fanart: revision, .posters: revision],
                libraryId: Self.libraryID, mediaType: "photo"))
        }
        if enumerationError != nil { throw LocalArtworkError.chooseFolderAgain }
        try Task.checkCancellation()
        artworkFiles = files
        return result.sorted { $0.id < $1.id }
    }

    /// openat + O_NOFOLLOW denies traversal and symlink replacement between
    /// catalogue discovery and reading, including symlinked parent directories.
    private func openArtwork(relativePath: String) throws -> Int32 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalArtworkError.missingArtwork
        }
        var parent = dup(rootDescriptor)
        guard parent >= 0 else { throw LocalArtworkError.chooseFolderAgain }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(parent)
            guard next >= 0 else { throw LocalArtworkError.missingArtwork }
            parent = next
        }
        let descriptor = openat(parent, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        close(parent)
        guard descriptor >= 0 else { throw LocalArtworkError.missingArtwork }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= URLSessionTransport.maximumImageBytes else {
            close(descriptor)
            throw LocalArtworkError.missingArtwork
        }
        return descriptor
    }
}
