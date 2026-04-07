import Foundation

// MARK: - Data Model

struct SavedEditorState: Codable {
    struct FoldInfo: Codable {
        /// Character offset (UTF-16) in the **true content** where the fold starts.
        /// This equals the position of the "\n" that precedes the folded children.
        let trueOffset: Int
        /// Length (UTF-16) of the folded text in the true content: "\n" + all children.
        let originalLength: Int
    }
    /// Top-level folds only, sorted ascending by trueOffset.
    let folds: [FoldInfo]
    /// Cursor position in true-content coordinates (UTF-16).
    let cursorOffset: Int
}

// MARK: - Store

final class EditorStateStore {
    static let shared = EditorStateStore()

    private var cache: [String: SavedEditorState] = [:]
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClaudeNotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("editor_state.json")
        load()
    }

    func save(_ state: SavedEditorState, for noteID: UUID) {
        cache[noteID.uuidString] = state
        persist()
    }

    func state(for noteID: UUID) -> SavedEditorState? {
        cache[noteID.uuidString]
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SavedEditorState].self, from: data) else { return }
        cache = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
