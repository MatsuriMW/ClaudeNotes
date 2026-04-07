import Foundation
import AppKit

// MARK: - File Note

struct FileNote: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var modifiedAt: Date

    var displayTitle: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// A stable, deterministic UUID derived from the file path (for EditorStateStore keying)
    var stableID: UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let pathBytes = Array(url.path.utf8)
        for (i, b) in pathBytes.prefix(16).enumerated() { bytes[i] = b }
        for (i, b) in pathBytes.dropFirst(16).enumerated() { bytes[i % 16] ^= b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Library Folder

struct LibraryFolder: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var files: [FileNote] = []

    var displayName: String { url.lastPathComponent }
}

// MARK: - Sort Mode

enum LibrarySortMode: String, CaseIterable {
    case recentlyUsed = "recentlyUsed"
    case name = "name"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .recentlyUsed: return "最近使用"
        case .name:         return "名字"
        case .custom:       return "自定义"
        }
    }
}

// MARK: - Library Manager

@Observable
final class LibraryManager {
    static let shared = LibraryManager()

    private(set) var libraries: [LibraryFolder] = []
    var openedFiles: [FileNote] = []

    // Global filter settings
    var maxFilesFilter: Int = 0
    var filenameFilter: String = ""
    var sortMode: LibrarySortMode = .name
    var sortAscending: Bool = true

    /// last-opened timestamps keyed by file path
    private var lastAccessDates: [String: Date] = [:]
    /// custom order per library folder: folder-path → [file-path in order]
    private var customOrders: [String: [String]] = [:]

    // MARK: - File system watchers (folder path → DispatchSource)
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var watcherFDs: [String: Int32] = [:]
    /// Debounce work items so rapid FS events don't cause many redundant refreshes
    private var refreshWorkItems: [String: DispatchWorkItem] = [:]

    private init() {
        loadState()
        for lib in libraries { startWatching(lib) }
    }

    // MARK: - Libraries

    func addLibrary(_ url: URL) {
        guard !libraries.contains(where: { $0.url == url }) else { return }
        var lib = LibraryFolder(id: stableID(for: url), url: url)
        lib.files = loadFiles(from: url)
        libraries.append(lib)
        saveFolders()
        startWatching(lib)
    }

    func removeLibrary(id: UUID) {
        if let lib = libraries.first(where: { $0.id == id }) {
            stopWatching(lib.url.path)
        }
        libraries.removeAll { $0.id == id }
        saveFolders()
    }

    // MARK: - File operations

    /// Move a file to the Trash. The directory watcher handles the refresh automatically.
    func trashFile(url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        // Remove from openedFiles if present
        openedFiles.removeAll { $0.url == url }
    }

    /// Rename a file. Preserves the original extension if the new name omits it.
    /// Returns the new URL, or nil on failure.
    @discardableResult
    func renameFile(url: URL, newName: String) -> URL? {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let ext = url.pathExtension
        if !ext.isEmpty && !name.lowercased().hasSuffix(".\(ext.lowercased())") {
            name += ".\(ext)"
        }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            // Update openedFiles entry if this was an open single file
            if let i = openedFiles.firstIndex(where: { $0.url == url }) {
                openedFiles[i] = makeFileNote(newURL)
                saveOpenedFiles()
            }
            return newURL
        } catch {
            return nil
        }
    }

    func refreshLibrary(id: UUID) {
        guard let idx = libraries.firstIndex(where: { $0.id == id }) else { return }
        libraries[idx].files = loadFiles(from: libraries[idx].url)
    }

    func refreshAllLibraries() {
        for i in libraries.indices {
            libraries[i].files = loadFiles(from: libraries[i].url)
        }
        saveFilterState()
    }

    // Legacy alias used by LibraryFilterView
    func refreshLibrary() { refreshAllLibraries() }

    // MARK: - Directory watching (DispatchSource / kqueue EVFILT_VNODE)

    private func startWatching(_ lib: LibraryFolder) {
        let path = lib.url.path
        guard watchers[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: .main
        )
        let libID = lib.id
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Debounce: rapid events (e.g. atomic save) coalesce into one refresh
            self.refreshWorkItems[path]?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.refreshLibrary(id: libID)
                self?.refreshWorkItems.removeValue(forKey: path)
            }
            self.refreshWorkItems[path] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers[path] = source
    }

    private func stopWatching(_ path: String) {
        refreshWorkItems[path]?.cancel()
        refreshWorkItems.removeValue(forKey: path)
        watchers[path]?.cancel()
        watchers.removeValue(forKey: path)
    }

    /// Creates a new .md file in the given library and returns its URL.
    @discardableResult
    func createFile(in libraryID: UUID, name: String) -> URL? {
        guard let lib = libraries.first(where: { $0.id == libraryID }) else { return nil }
        var fileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty { fileName = "无标题" }
        if !fileName.lowercased().hasSuffix(".md") { fileName += ".md" }
        var candidate = lib.url.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = fileName.replacingOccurrences(of: ".md", with: "")
            candidate = lib.url.appendingPathComponent("\(base) \(counter).md")
            counter += 1
        }
        guard (try? "".write(to: candidate, atomically: true, encoding: .utf8)) != nil else { return nil }
        refreshLibrary(id: libraryID)
        return candidate
    }

    // MARK: - Single Files

    func openSingleFile(_ url: URL) {
        guard !openedFiles.contains(where: { $0.url == url }) else { return }
        openedFiles.insert(makeFileNote(url), at: 0)
        saveOpenedFiles()
    }

    func closeFile(_ url: URL) {
        openedFiles.removeAll { $0.url == url }
        saveOpenedFiles()
    }

    // MARK: - Access tracking

    /// Call this whenever a file is opened in the editor.
    func recordAccess(url: URL) {
        lastAccessDates[url.path] = Date()
        saveAccessDates()
        if sortMode == .recentlyUsed { refreshAllLibraries() }
    }

    // MARK: - Custom ordering

    /// Move files within a library and switch to custom sort mode.
    /// Dragging any file automatically activates custom mode.
    func moveFilesAndSwitchToCustom(in libraryID: UUID, from indices: IndexSet, to newOffset: Int) {
        guard let idx = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        var files = libraries[idx].files
        files.move(fromOffsets: indices, toOffset: newOffset)
        libraries[idx].files = files
        customOrders[libraries[idx].url.path] = files.map(\.url.path)
        if sortMode != .custom { sortMode = .custom }
        saveCustomOrders()
        saveFilterState()
    }

    /// Move a file to the first position in the list.
    func moveToFirst(in libraryID: UUID, file: FileNote) {
        guard let idx = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        var files = libraries[idx].files

        // Remove file from its current position
        files.removeAll { $0.url == file.url }

        // Insert at the beginning
        files.insert(file, at: 0)

        libraries[idx].files = files
        customOrders[libraries[idx].url.path] = files.map(\.url.path)
        if sortMode != .custom { sortMode = .custom }
        saveCustomOrders()
        saveFilterState()
    }

    /// Move a file to the last position in the list.
    func moveToLast(in libraryID: UUID, file: FileNote) {
        guard let idx = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        var files = libraries[idx].files

        // Remove file from its current position
        files.removeAll { $0.url == file.url }

        // Append at the end
        files.append(file)

        libraries[idx].files = files
        customOrders[libraries[idx].url.path] = files.map(\.url.path)
        if sortMode != .custom { sortMode = .custom }
        saveCustomOrders()
        saveFilterState()
    }

    /// Move a file up by one position.
    func moveFileUp(in libraryID: UUID, file: FileNote) {
        guard let idx = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        var files = libraries[idx].files

        guard let currentIndex = files.firstIndex(where: { $0.url == file.url }),
              currentIndex > 0 else { return }

        // Swap with previous file
        files.swapAt(currentIndex, currentIndex - 1)

        libraries[idx].files = files
        customOrders[libraries[idx].url.path] = files.map(\.url.path)
        if sortMode != .custom { sortMode = .custom }
        saveCustomOrders()
        saveFilterState()
    }

    /// Move a file down by one position.
    func moveFileDown(in libraryID: UUID, file: FileNote) {
        guard let idx = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
        var files = libraries[idx].files

        guard let currentIndex = files.firstIndex(where: { $0.url == file.url }),
              currentIndex < files.count - 1 else { return }

        // Swap with next file
        files.swapAt(currentIndex, currentIndex + 1)

        libraries[idx].files = files
        customOrders[libraries[idx].url.path] = files.map(\.url.path)
        if sortMode != .custom { sortMode = .custom }
        saveCustomOrders()
        saveFilterState()
    }

    // MARK: - File loading

    private func loadFiles(from folder: URL) -> [FileNote] {
        let fm = FileManager.default
        let extensions = Set(["md", "markdown", "txt"])
        var urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { extensions.contains($0.pathExtension.lowercased()) } ?? []

        if !filenameFilter.isEmpty {
            urls = urls.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(filenameFilter) }
        }

        switch sortMode {
        case .recentlyUsed:
            urls.sort { a, b in
                let aDate = lastAccessDates[a.path]
                    ?? (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let bDate = lastAccessDates[b.path]
                    ?? (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return sortAscending ? aDate < bDate : aDate > bDate
            }
        case .name:
            urls.sort { a, b in
                let r = a.lastPathComponent.localizedCompare(b.lastPathComponent)
                return sortAscending ? r == .orderedAscending : r == .orderedDescending
            }
        case .custom:
            let order = customOrders[folder.path] ?? []
            let orderMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            urls.sort { a, b in
                let ai = orderMap[a.path] ?? Int.max
                let bi = orderMap[b.path] ?? Int.max
                if ai == Int.max && bi == Int.max {
                    return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
                }
                return ai < bi
            }
        }

        if maxFilesFilter > 0 { urls = Array(urls.prefix(maxFilesFilter)) }
        return urls.map { makeFileNote($0) }
    }

    private func makeFileNote(_ url: URL) -> FileNote {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return FileNote(url: url, modifiedAt: mod)
    }

    private func stableID(for url: URL) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let pathBytes = Array(url.path.utf8)
        for (i, b) in pathBytes.prefix(16).enumerated() { bytes[i] = b }
        for (i, b) in pathBytes.dropFirst(16).enumerated() { bytes[i % 16] ^= b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Persistence

    private func loadState() {
        let d = UserDefaults.standard

        if let paths = d.stringArray(forKey: "libraryFolderPaths") {
            libraries = paths.compactMap { path -> LibraryFolder? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path)
                return LibraryFolder(id: stableID(for: url), url: url)
            }
            for i in libraries.indices {
                libraries[i].files = loadFiles(from: libraries[i].url)
            }
        } else if let path = d.string(forKey: "libraryFolderPath") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                var lib = LibraryFolder(id: stableID(for: url), url: url)
                lib.files = loadFiles(from: url)
                libraries = [lib]
            }
            d.removeObject(forKey: "libraryFolderPath")
            saveFolders()
        }

        if let paths = d.stringArray(forKey: "openedFilePaths") {
            openedFiles = paths.compactMap { path -> FileNote? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return makeFileNote(URL(fileURLWithPath: path))
            }
        }

        maxFilesFilter = d.integer(forKey: "libMaxFiles")
        filenameFilter = d.string(forKey: "libFilenameFilter") ?? ""
        sortAscending  = d.object(forKey: "libSortAscending") as? Bool ?? false

        // Migrate old bool sort setting
        if let rawMode = d.string(forKey: "libSortMode"),
           let mode = LibrarySortMode(rawValue: rawMode) {
            sortMode = mode
        } else if let oldBool = d.object(forKey: "libSortByDate") as? Bool {
            sortMode = oldBool ? .recentlyUsed : .name
            d.removeObject(forKey: "libSortByDate")
        }

        // Load access dates
        if let dict = d.dictionary(forKey: "libAccessDates") as? [String: Double] {
            lastAccessDates = dict.mapValues { Date(timeIntervalSince1970: $0) }
        }

        // Load custom orders
        if let dict = d.dictionary(forKey: "libCustomOrders") as? [String: [String]] {
            customOrders = dict
        }
    }

    private func saveFolders() {
        UserDefaults.standard.set(libraries.map(\.url.path), forKey: "libraryFolderPaths")
    }

    private func saveOpenedFiles() {
        UserDefaults.standard.set(openedFiles.map(\.url.path), forKey: "openedFilePaths")
    }

    private func saveFilterState() {
        let d = UserDefaults.standard
        d.set(maxFilesFilter,      forKey: "libMaxFiles")
        d.set(filenameFilter,      forKey: "libFilenameFilter")
        d.set(sortMode.rawValue,   forKey: "libSortMode")
        d.set(sortAscending,       forKey: "libSortAscending")
    }

    private func saveAccessDates() {
        let dict = lastAccessDates.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(dict, forKey: "libAccessDates")
    }

    private func saveCustomOrders() {
        UserDefaults.standard.set(customOrders, forKey: "libCustomOrders")
    }
}
