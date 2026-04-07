import SwiftUI
import SwiftData

enum SidebarItem: Hashable {
    case allNotes
    case folder(NoteFolder)
    case persona
    case inbox
    case kanban
}

struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NoteFolder.createdAt) private var folders: [NoteFolder]
    @Binding var selectedItem: SidebarItem?
    @Binding var selectedFolder: NoteFolder?
    var onOpenFile: (URL, String) -> Void = { _, _ in }

    @State private var library = LibraryManager.shared
    @State private var inboxStore = InboxStore.shared
    @State private var personaStore = PersonaStore.shared
    @State private var showLibraryFilter = false
    // Inline new-file creation: tracks which library's "+" was tapped
    @State private var newFileLibraryID: UUID? = nil
    @State private var newFileName = ""
    /// Tracks which file URL is currently showing the accent flash
    @State private var tappedFileURL: URL? = nil
    /// Tracks the currently hovered/selected file for keyboard shortcuts
    @State private var currentFile: FileNote? = nil
    @FocusState private var isFocused: Bool
    private let shortcutSettings = ShortcutSettings.shared

    var body: some View {
        List(selection: $selectedItem) {
            // ── AI 工具 ──────────────────────────────────────────
            Section {
                HStack(spacing: 4) {
                    Label("个人画像", systemImage: "person.crop.circle")
                    Spacer()
                    if personaStore.isAnalyzing {
                        HStack(spacing: 3) {
                            ProgressView().controlSize(.mini)
                            Text("分析中")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if personaStore.analysisCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if personaStore.persona?.isStale == true {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .help("画像已过时，建议重新分析")
                    }
                }
                .tag(SidebarItem.persona)

                HStack(spacing: 4) {
                    Label("每日简报", systemImage: "newspaper")
                    Spacer()
                    if inboxStore.isGenerating {
                        HStack(spacing: 3) {
                            ProgressView().controlSize(.mini)
                            Text("生成中")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else if inboxStore.generationCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                .tag(SidebarItem.inbox)

                HStack(spacing: 4) {
                    Label("任务看板", systemImage: "rectangle.3.group")
                }
                .tag(SidebarItem.kanban)
            }

            // ── 笔记与文件（自然分节间距形成视觉分隔）───────────────
            Section {
                Label("所有笔记", systemImage: "tray.full")
                    .tag(SidebarItem.allNotes)
            }

            Section("文件夹") {
                ForEach(folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .tag(SidebarItem.folder(folder))
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                deleteFolder(folder)
                            }
                        }
                }
            }

            // Single files opened via panel
            if !library.openedFiles.isEmpty {
                Section("已打开文件") {
                    ForEach(library.openedFiles) { file in
                        Label(file.displayTitle, systemImage: "doc.text")
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(tappedFileURL == file.url ? 0.18 : 0))
                            )
                            .onTapGesture { flashAndOpen(file) }
                            .contextMenu {
                                Button("打开") { flashAndOpen(file) }
                                Divider()
                                Button("关闭文件", role: .destructive) {
                                    library.closeFile(file.url)
                                }
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                }
                            }
                    }
                }
            }

            // Multiple library folders
            ForEach(library.libraries) { lib in
                Section {
                    ForEach(lib.files) { file in
                        Label(file.displayTitle, systemImage: "doc.text")
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(tappedFileURL == file.url ? 0.18 : 0))
                            )
                            .onTapGesture {
                                currentFile = file
                                flashAndOpen(file)
                            }
                            .contextMenu {
                                Button("打开") { flashAndOpen(file) }
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                }
                                Divider()
                                Button("移到最前") {
                                    library.moveToFirst(in: lib.id, file: file)
                                    currentFile = file
                                }
                                Button("移到最后") {
                                    library.moveToLast(in: lib.id, file: file)
                                    currentFile = file
                                }
                                Divider()
                                Button("上移") {
                                    library.moveFileUp(in: lib.id, file: file)
                                    currentFile = file
                                }
                                .keyboardShortcut(shortcutSettings.binding(for: .moveLibraryFileUp).swiftUIKey, modifiers: shortcutSettings.binding(for: .moveLibraryFileUp).swiftUIModifiers)
                                Button("下移") {
                                    library.moveFileDown(in: lib.id, file: file)
                                    currentFile = file
                                }
                                .keyboardShortcut(shortcutSettings.binding(for: .moveLibraryFileDown).swiftUIKey, modifiers: shortcutSettings.binding(for: .moveLibraryFileDown).swiftUIModifiers)
                                Divider()
                                Button("重命名…") { renameFile(file) }
                                Button("移到废纸篓", role: .destructive) {
                                    library.trashFile(url: file.url)
                                }
                            }
                    }
                    .onMove { from, to in
                        library.moveFilesAndSwitchToCustom(in: lib.id, from: from, to: to)
                    }
                    // Inline new-file input row
                    if newFileLibraryID == lib.id {
                        HStack {
                            TextField("文件名", text: $newFileName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { createFile(in: lib) }
                            Button("添加") { createFile(in: lib) }
                                .disabled(newFileName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button {
                                newFileLibraryID = nil
                                newFileName = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(lib.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        // New file in this library
                        Button {
                            newFileLibraryID = lib.id
                            newFileName = ""
                        } label: {
                            Image(systemName: "doc.badge.plus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("在此文件夹中新建文件")
                        // Filter
                        Button { showLibraryFilter = true } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showLibraryFilter) {
                            LibraryFilterView(library: library)
                        }
                        // Refresh
                        Button { library.refreshLibrary(id: lib.id) } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("刷新文件列表")
                        // Remove library
                        Button { library.removeLibrary(id: lib.id) } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("移除文件库")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        .onAppear {
            // Track the currently selected file when list appears
            if let firstLib = library.libraries.first, !firstLib.files.isEmpty {
                currentFile = firstLib.files.first
            }
        }
        // Global keyboard shortcuts for file navigation
        .background {
            Button("") {
                handleFileMoveUp()
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .hidden()

            Button("") {
                handleFileMoveDown()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .hidden()
        }
    }

    // MARK: - Keyboard shortcut handlers

    private func handleFileMoveUp() {
        guard let file = currentFile,
              let lib = library.libraries.first(where: { lib in
                  lib.files.contains(where: { $0.url == file.url })
              }) else { return }
        library.moveFileUp(in: lib.id, file: file)
    }

    private func handleFileMoveDown() {
        guard let file = currentFile,
              let lib = library.libraries.first(where: { lib in
                  lib.files.contains(where: { $0.url == file.url })
              }) else { return }
        library.moveFileDown(in: lib.id, file: file)
    }

    // MARK: - Actions

    private func flashAndOpen(_ file: FileNote) {
        // When opening a file, automatically switch to "all notes" so users can browse other notes
        selectedItem = .allNotes
        onOpenFile(file.url, file.displayTitle)
        withAnimation(.easeOut(duration: 0.12)) { tappedFileURL = file.url }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.3)) { tappedFileURL = nil }
        }
    }

    private func deleteFolder(_ folder: NoteFolder) {
        if selectedFolder?.id == folder.id {
            selectedFolder = nil
            selectedItem = .allNotes
        }
        modelContext.delete(folder)
    }

    private func openLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加为 Library"
        if panel.runModal() == .OK, let url = panel.url {
            library.addLibrary(url)
        }
    }

    private func openSingleFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.prompt = "打开文件"
        if panel.runModal() == .OK, let url = panel.url {
            library.openSingleFile(url)
            onOpenFile(url, url.deletingPathExtension().lastPathComponent)
        }
    }

    private func createFile(in lib: LibraryFolder) {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = library.createFile(in: lib.id, name: name.isEmpty ? "无标题" : name) {
            onOpenFile(url, url.deletingPathExtension().lastPathComponent)
        }
        newFileLibraryID = nil
        newFileName = ""
    }

    private func renameFile(_ file: FileNote) {
        let alert = NSAlert()
        alert.messageText = "重命名文件"
        alert.informativeText = "请输入「\(file.displayTitle)」的新名称："
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = file.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        library.renameFile(url: file.url, newName: newName)
    }
}

// MARK: - Library Filter View

private struct LibraryFilterView: View {
    @Bindable var library: LibraryManager
    @State private var customFileCount: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("文件库筛选")
                .font(.headline)
                .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最多显示文件数")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        // 自定义输入框
                        TextField("输入数量", text: $customFileCount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .onChange(of: customFileCount) { _, newValue in
                                // 处理用户输入
                                if newValue.isEmpty {
                                    library.maxFilesFilter = 0
                                } else if let count = Int(newValue), count >= 0 {
                                    library.maxFilesFilter = count
                                }
                            }
                            .onAppear {
                                if library.maxFilesFilter == 0 {
                                    customFileCount = ""
                                } else {
                                    customFileCount = "\(library.maxFilesFilter)"
                                }
                            }

                        // 或者使用 Stepper
                        HStack(spacing: 8) {
                            Stepper("", value: $library.maxFilesFilter, in: 0...99999, step: 10)
                                .labelsHidden()
                                .onChange(of: library.maxFilesFilter) { _, newValue in
                                    customFileCount = newValue == 0 ? "" : "\(newValue)"
                                }
                        }

                        Spacer()

                        // 显示当前值
                        Text(library.maxFilesFilter == 0 ? "不限" : "\(library.maxFilesFilter) 个")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("文件名筛选")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("文件名包含…", text: $library.filenameFilter)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: library.filenameFilter) { _, _ in library.refreshAllLibraries() }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("排序方式")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $library.sortMode) {
                        ForEach(LibrarySortMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: library.sortMode) { _, _ in library.refreshAllLibraries() }
                    if library.sortMode == .custom {
                        Text("在侧边栏拖拽文件可调整顺序")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }

                if library.sortMode != .custom {
                    Toggle("升序排列", isOn: $library.sortAscending)
                        .onChange(of: library.sortAscending) { _, _ in library.refreshAllLibraries() }
                }
            }

            Divider()
                .padding(.vertical, 16)

            Button("刷新所有文件库") { library.refreshAllLibraries() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 320)
    }
}
