import SwiftUI
import SwiftData
import Combine
import AppKit

@Observable
final class NoteEditorViewModel {
    var title: String = ""
    var content: String = ""
    var isPreviewMode: Bool = false
    var filePath: String? = nil
    var hasUnsavedChanges = false
    var lastSavedContent: String = ""

    private var note: Note?
    private var saveTask: Task<Void, Never>?

    var fileName: String? {
        guard let path = filePath else { return nil }
        return (path as NSString).lastPathComponent
    }

    func load(note: Note) {
        self.note = note
        self.title = note.title
        self.content = note.content
        self.filePath = note.filePath
        self.lastSavedContent = note.content
        self.hasUnsavedChanges = false
    }

    func onTitleChanged() {
        hasUnsavedChanges = true
        scheduleSave()
    }

    func onContentChanged() {
        hasUnsavedChanges = (content != lastSavedContent)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    @MainActor
    func save() {
        guard let note else { return }
        if note.title != title {
            note.title = title
        }
        if note.content != content {
            note.content = content
        }
        note.filePath = filePath
        note.modifiedAt = .now
    }

    @MainActor
    func saveImmediately() {
        saveTask?.cancel()
        save()
    }

    // MARK: - File I/O

    @MainActor
    func openFile() {
        let panel = NSOpenPanel()
        panel.title = "打开 Markdown 文件"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Allow common markdown extensions
        panel.allowedContentTypes = [
            .init(filenameExtension: "md")!,
            .init(filenameExtension: "markdown")!,
            .plainText
        ]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let fileContent = try String(contentsOf: url, encoding: .utf8)
            content = fileContent
            title = url.deletingPathExtension().lastPathComponent
            filePath = url.path
            lastSavedContent = fileContent
            hasUnsavedChanges = false
            save()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法打开文件"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @MainActor
    func saveToFile(saveAs: Bool = false) {
        let contentToSave = content

        if let path = filePath, !saveAs {
            // Save to existing file
            do {
                try contentToSave.write(toFile: path, atomically: true, encoding: .utf8)
                lastSavedContent = contentToSave
                hasUnsavedChanges = false
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        } else {
            // Save As dialog
            let panel = NSSavePanel()
            panel.title = "保存 Markdown 文件"
            panel.allowedContentTypes = [.init(filenameExtension: "md")!]
            panel.nameFieldStringValue = (title.isEmpty ? "Untitled" : title) + ".md"
            panel.canCreateDirectories = true
            // Default to the parent directory of the existing file (save-as), or the
            // first configured library folder, so the user doesn't have to navigate there.
            if let existingPath = filePath {
                panel.directoryURL = URL(fileURLWithPath: existingPath).deletingLastPathComponent()
            } else if let libraryURL = LibraryManager.shared.libraries.first?.url {
                panel.directoryURL = libraryURL
            }

            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                try contentToSave.write(to: url, atomically: true, encoding: .utf8)
                filePath = url.path
                title = url.deletingPathExtension().lastPathComponent
                lastSavedContent = contentToSave
                hasUnsavedChanges = false
                save()
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
