import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Tab Group

struct TabGroup: Identifiable {
    let id: UUID
    var name: String
    var color: Color

    static let presetColors: [Color] = [.blue, .green, .orange, .red, .purple, .yellow]
}

// MARK: - Open Tab Model

struct OpenTab: Identifiable {
    let id: UUID
    var isPinned: Bool = false
    var groupID: UUID? = nil
    enum Content {
        case note(Note)
        case file(URL, displayTitle: String)
    }
    var content: Content

    var title: String {
        switch content {
        case .note(let n): return n.title.isEmpty ? "无标题" : n.title
        case .file(_, let t): return t
        }
    }

    var icon: String {
        switch content {
        case .note: return "doc.text"
        case .file: return "doc.plaintext"
        }
    }

    func matchesNote(_ note: Note) -> Bool {
        if case .note(let n) = content { return n.id == note.id }
        return false
    }

    func matchesURL(_ url: URL) -> Bool {
        if case .file(let u, _) = content { return u == url }
        return false
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var sidebarSelection: SidebarItem? = .allNotes
    @State private var selectedFolder: NoteFolder? = nil
    @State private var openTabs: [OpenTab] = []
    @State private var activeTabID: UUID? = nil
    @State private var secondaryTabID: UUID? = nil
    @State private var tabGroups: [TabGroup] = []
    @State private var showAIPanel = false
    @State private var showVaultSearch = false
    @State private var showShortcutsHelp = false
    @State private var showTabManager = false
    @State private var kanbanTaskItems: [TaskItem]? = nil
    /// Set by search to jump the active editor to the matched keyword on open.
    @State private var searchJumpQuery: String? = nil
    /// Set by kanban board to jump to specific line in secondary editor
    @State private var fileJumpToLine: (tabID: UUID, line: Int)? = nil
    private let shortcutSettings = ShortcutSettings.shared

    private var activeNote: Note? {
        guard let id = activeTabID,
              let tab = openTabs.first(where: { $0.id == id }),
              case .note(let note) = tab.content else { return nil }
        return note
    }

    var body: some View {
        navView
            .onReceive(NotificationCenter.default.publisher(for: .menuGenerateInbox)) { _ in sidebarSelection = .inbox }
            .onReceive(NotificationCenter.default.publisher(for: .menuInboxTopics)) { _ in sidebarSelection = .inbox }
            .toolbar { toolbarContent }
            .background { tabKeyboardShortcuts }
            .onAppear {
                NotificationService.shared.requestAuthorization()
                InboxStore.shared.startAutoGenerateIfNeeded()
            }
            .sheet(isPresented: $showShortcutsHelp) { ShortcutsHelpView(settings: shortcutSettings) }
            .sheet(isPresented: $showVaultSearch) { vaultSearchSheet }
            .frame(minWidth: 800, minHeight: 500)
    }

    private var navView: some View {
        NavigationSplitView {
            SidebarView(
                selectedItem: $sidebarSelection,
                selectedFolder: $selectedFolder,
                onOpenFile: { url, title in openFileTab(url: url, title: title) }
            )
        } detail: {
            detailContent
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { createNewNote() } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("新建笔记")
            Button { showVaultSearch = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .keyboardShortcut(searchBinding.swiftUIKey, modifiers: searchBinding.swiftUIModifiers)
            .help("搜索所有笔记")
            Button { withAnimation { showAIPanel.toggle() } } label: {
                Image(systemName: showAIPanel ? "terminal.fill" : "terminal")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help("Claude Code 终端")
            tabManagerMenu
        }
    }

    private var tabManagerMenu: some View {
        Menu {
            ForEach(openTabs) { tab in
                Button {
                    activeTabID = tab.id
                } label: {
                    HStack {
                        Image(systemName: tab.icon)
                        Text(tab.title)
                        Spacer()
                        if tab.id == activeTabID { Image(systemName: "checkmark") }
                    }
                }
            }
            if !openTabs.isEmpty {
                Divider()
                Button(role: .destructive) {
                    openTabs = []; activeTabID = nil; secondaryTabID = nil
                } label: { Label("关闭所有标签", systemImage: "xmark.circle") }
            }
        } label: {
            Image(systemName: "rectangle.stack")
        }
        .help("管理标签页")
    }

    private var vaultSearchSheet: some View {
        VaultSearchView(
            onSelectNote: { note, query in
                openNoteTab(note)
                searchJumpQuery = query
            },
            onSelectFile: { url, title, query in
                openFileTab(url: url, title: title)
                searchJumpQuery = query
            }
        )
    }

    private var searchBinding: ShortcutBinding {
        shortcutSettings.binding(for: .searchAllNotes)
    }

    // MARK: - Keyboard shortcuts (hidden buttons)

    @ViewBuilder
    private var tabKeyboardShortcuts: some View {
        Group {
            // Cmd+1…8 — jump to tab by position; Cmd+9 — jump to last tab
            Button("") { switchToTab(at: 0) }.keyboardShortcut("1", modifiers: .command)
            Button("") { switchToTab(at: 1) }.keyboardShortcut("2", modifiers: .command)
            Button("") { switchToTab(at: 2) }.keyboardShortcut("3", modifiers: .command)
            Button("") { switchToTab(at: 3) }.keyboardShortcut("4", modifiers: .command)
            Button("") { switchToTab(at: 4) }.keyboardShortcut("5", modifiers: .command)
            Button("") { switchToTab(at: 5) }.keyboardShortcut("6", modifiers: .command)
            Button("") { switchToTab(at: 6) }.keyboardShortcut("7", modifiers: .command)
            Button("") { switchToTab(at: 7) }.keyboardShortcut("8", modifiers: .command)
            Button("") { switchToTab(at: 0, last: true) }.keyboardShortcut("9", modifiers: .command)

            // Use customizable shortcuts for previous/next tab
            let prevBinding = shortcutSettings.binding(for: .selectPreviousTab)
            let nextBinding = shortcutSettings.binding(for: .selectNextTab)

            Button("") { selectPreviousTab() }
                .keyboardShortcut(prevBinding.swiftUIKey, modifiers: prevBinding.swiftUIModifiers)
            Button("") { selectNextTab() }
                .keyboardShortcut(nextBinding.swiftUIKey, modifiers: nextBinding.swiftUIModifiers)

            // Cmd+W — close active tab
            Button("") { closeActiveTab() }.keyboardShortcut("w", modifiers: .command)

            // Inbox / daily brief shortcuts
            let inboxBinding = shortcutSettings.binding(for: .generateInbox)
            Button("") {
                NotificationCenter.default.post(name: .menuGenerateInbox, object: nil)
            }
            .keyboardShortcut(inboxBinding.swiftUIKey, modifiers: inboxBinding.swiftUIModifiers)

            let topicsBinding = shortcutSettings.binding(for: .inboxTopics)
            Button("") {
                NotificationCenter.default.post(name: .menuInboxTopics, object: nil)
            }
            .keyboardShortcut(topicsBinding.swiftUIKey, modifiers: topicsBinding.swiftUIModifiers)
        }
        .hidden()
    }

    // MARK: - Detail content

    @ViewBuilder
    private var detailContent: some View {
        if showAIPanel {
            HSplitView {
                mainDetailContent
                    .frame(minWidth: 380)
                ClaudeTerminalView(
                    note: activeNote,
                    initialContext: terminalContext,
                    sessionID: terminalSessionID
                )
                .frame(minWidth: 300, idealWidth: 420, maxWidth: 600)
            }
        } else {
            mainDetailContent
        }
    }

    @ViewBuilder
    private var mainDetailContent: some View {
        switch sidebarSelection {
        case .persona:
            PersonaView()
        case .inbox:
            InboxView()
        case .kanban:
            KanbanBoardView(customTaskItems: $kanbanTaskItems) { note in
                dismissKanbanAndOpenNote(note)
            }
        default:
            notesWorkspace
        }
    }

    private var terminalContext: String? {
        if case .persona = sidebarSelection {
            return PersonaStore.shared.systemPromptContext
        }
        return nil
    }

    private var terminalSessionID: UUID {
        if let note = activeNote { return note.id }
        switch sidebarSelection {
        case .persona: return UUID(uuidString: "AA000000-0000-0000-0000-000000000001")!
        case .inbox:   return UUID(uuidString: "AA000000-0000-0000-0000-000000000002")!
        default:       return UUID(uuidString: "AA000000-0000-0000-0000-000000000000")!
        }
    }

    // MARK: - Notes workspace (tab bar + editor)

    private var notesWorkspace: some View {
        VStack(spacing: 0) {
            if !openTabs.isEmpty {
                TabBarView(
                    tabs: $openTabs,
                    activeTabID: $activeTabID,
                    secondaryTabID: $secondaryTabID,
                    tabGroups: $tabGroups,
                    onClose: { closeTab($0) },
                    onTogglePin: { togglePin($0) },
                    onAddGroup: { addGroup(containing: $0) },
                    onRemoveFromGroup: { removeFromGroup($0) },
                    onMoveToGroup: { tab, gid in moveTab(tab, toGroup: gid) },
                    onCreateTabAfter: { createNoteAfterTab($0) }
                )
                Divider()
            }
            tabEditorArea
        }
    }

    // MARK: - Editor area (primary + optional secondary)

    @ViewBuilder
    private var tabEditorArea: some View {
        let rewriteActive = RewriteSession.shared.isActive
        let hasSecondary = secondaryTabID != nil
            && secondaryTabID != activeTabID
            && openTabs.first(where: { $0.id == secondaryTabID }) != nil

        if rewriteActive || hasSecondary {
            HSplitView {
                primaryEditorContent
                    .frame(minWidth: 300)
                if rewriteActive {
                    RewriteResultPanel()
                        .frame(minWidth: 280)
                } else if let secondaryID = secondaryTabID,
                          let secondaryTab = openTabs.first(where: { $0.id == secondaryID }) {
                    secondaryEditorPanel(for: secondaryTab)
                        .frame(minWidth: 280)
                }
            }
        } else {
            primaryEditorContent
        }
    }

    @ViewBuilder
    private var primaryEditorContent: some View {
        if let note = activeNote {
            NoteEditorView(note: note, highlightQuery: $searchJumpQuery) { _, _ in
                withAnimation { showAIPanel = true }
            }
        } else if let id = activeTabID,
                  let tab = openTabs.first(where: { $0.id == id }),
                  case .file(let url, _) = tab.content {
            fileEditorView(url: url, tabID: id)
        } else {
            emptyState
        }
    }

    /// Second editor pane shown alongside the primary editor.
    @ViewBuilder
    private func secondaryEditorPanel(for tab: OpenTab) -> some View {
        VStack(spacing: 0) {
            // Mini header identifies this as the second editor
            HStack(spacing: 6) {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(tab.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    secondaryTabID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("关闭第二编辑器")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)

            Divider()

            switch tab.content {
            case .note(let note):
                NoteEditorView(note: note)
            case .file(let url, _):
                fileEditorView(url: url, tabID: tab.id)
            }
        }
    }

    @ViewBuilder
    private func fileEditorView(url: URL, tabID: UUID) -> some View {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? Date()
        let jumpToLine = fileJumpToLine?.tabID == tabID ? fileJumpToLine?.line : nil

        FileNoteEditorView(
            fileNote: FileNote(url: url, modifiedAt: mod),
            highlightQuery: $searchJumpQuery,
            jumpToLine: jumpToLine,
            onRename: { newURL in renameFileTab(oldURL: url, newURL: newURL) }
        )
        .id(url)
        .onAppear {
            // Clear the jump after it's been used
            if fileJumpToLine?.tabID == tabID {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    fileJumpToLine = nil
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("选择或创建一个笔记")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("使用 / 唤起 Claude Code 终端")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab management

    private func dismissKanbanAndOpenNote(_ note: Note) {
        sidebarSelection = .allNotes
        openNoteTab(note)
    }

    private func openNoteTab(_ note: Note) {
        // When opening a note, automatically switch to "all notes" so users can browse other notes
        sidebarSelection = .allNotes

        if let existing = openTabs.first(where: { $0.matchesNote(note) }) {
            activeTabID = existing.id
        } else {
            let tab = OpenTab(id: UUID(), content: .note(note))
            openTabs.append(tab)
            activeTabID = tab.id
        }
    }

    private func openFileTab(url: URL, title: String) {
        // When opening a file, automatically switch to "all notes" so users can browse other notes
        sidebarSelection = .allNotes

        RecentFilesStore.shared.add(url)
        LibraryManager.shared.recordAccess(url: url)
        if let existing = openTabs.first(where: { $0.matchesURL(url) }) {
            activeTabID = existing.id
        } else {
            let tab = OpenTab(id: UUID(), content: .file(url, displayTitle: title))
            openTabs.append(tab)
            activeTabID = tab.id
        }
    }

    private func openFileTab(url: URL, jumpToLine: Int) {
        // Open file in secondary editor
        let title = url.deletingPathExtension().lastPathComponent

        RecentFilesStore.shared.add(url)
        LibraryManager.shared.recordAccess(url: url)

        // Check if file is already open
        if let existing = openTabs.first(where: { $0.matchesURL(url) }) {
            // If it's the active tab, open in secondary
            if activeTabID == existing.id {
                secondaryTabID = existing.id
                fileJumpToLine = (existing.id, jumpToLine)
            } else {
                // Otherwise activate it
                activeTabID = existing.id
                fileJumpToLine = (existing.id, jumpToLine)
            }
        } else {
            // Create new tab
            let tab = OpenTab(id: UUID(), content: .file(url, displayTitle: title))
            openTabs.append(tab)
            secondaryTabID = tab.id
            fileJumpToLine = (tab.id, jumpToLine)
        }
    }

    private func closeTab(_ tab: OpenTab) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        openTabs.remove(at: idx)
        if secondaryTabID == tab.id { secondaryTabID = nil }
        if activeTabID == tab.id {
            activeTabID = openTabs.isEmpty ? nil : openTabs[min(idx, openTabs.count - 1)].id
        }
        // Clean up groups that become empty
        pruneEmptyGroups()
    }

    private func closeActiveTab() {
        guard let id = activeTabID,
              let tab = openTabs.first(where: { $0.id == id }) else { return }
        closeTab(tab)
    }

    private func switchToTab(at index: Int, last: Bool = false) {
        guard !openTabs.isEmpty else { return }
        activeTabID = last ? openTabs.last?.id : (index < openTabs.count ? openTabs[index].id : nil)
    }

    private func selectPreviousTab() {
        guard !openTabs.isEmpty,
              let current = activeTabID,
              let idx = openTabs.firstIndex(where: { $0.id == current }) else { return }
        activeTabID = openTabs[(idx - 1 + openTabs.count) % openTabs.count].id
    }

    private func selectNextTab() {
        guard !openTabs.isEmpty,
              let current = activeTabID,
              let idx = openTabs.firstIndex(where: { $0.id == current }) else { return }
        activeTabID = openTabs[(idx + 1) % openTabs.count].id
    }

    private func togglePin(_ tab: OpenTab) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        openTabs[idx].isPinned.toggle()
    }

    private func createNewNote() {
        let note = Note(title: "", content: "")
        note.folder = selectedFolder
        modelContext.insert(note)
        openNoteTab(note)
    }

    /// Creates a new note and inserts its tab immediately after the given tab.
    private func createNoteAfterTab(_ tab: OpenTab) {
        let note = Note(title: "", content: "")
        note.folder = selectedFolder
        modelContext.insert(note)
        let newTab = OpenTab(id: UUID(), content: .note(note))
        if let idx = openTabs.firstIndex(where: { $0.id == tab.id }) {
            openTabs.insert(newTab, at: idx + 1)
        } else {
            openTabs.append(newTab)
        }
        activeTabID = newTab.id
    }

    // MARK: - Tab group management

    private func addGroup(containing tab: OpenTab) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let color = TabGroup.presetColors[tabGroups.count % TabGroup.presetColors.count]
        let group = TabGroup(id: UUID(), name: "群组 \(tabGroups.count + 1)", color: color)
        tabGroups.append(group)
        openTabs[idx].groupID = group.id
    }

    private func removeFromGroup(_ tab: OpenTab) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        openTabs[idx].groupID = nil
        pruneEmptyGroups()
    }

    private func moveTab(_ tab: OpenTab, toGroup groupID: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        openTabs[idx].groupID = groupID
        pruneEmptyGroups()
    }

    private func pruneEmptyGroups() {
        tabGroups.removeAll { group in !openTabs.contains(where: { $0.groupID == group.id }) }
    }

    private func renameFileTab(oldURL: URL, newURL: URL) {
        guard let idx = openTabs.firstIndex(where: { $0.matchesURL(oldURL) }) else { return }
        openTabs[idx].content = .file(newURL, displayTitle: newURL.deletingPathExtension().lastPathComponent)
    }

    // MARK: - File management

    private func createNewFileInLibrary() {
        let library = LibraryManager.shared
        guard let lib = library.libraries.first else { createNewNote(); return }
        if let url = library.createFile(in: lib.id, name: "无标题") {
            openFileTab(url: url, title: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func createNewStandaloneFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "无标题.md"
        panel.prompt = "新建"
        if panel.runModal() == .OK, let url = panel.url {
            try? "".write(to: url, atomically: true, encoding: .utf8)
            openFileTab(url: url, title: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func createNoteFolderViaDialog() {
        let alert = NSAlert()
        alert.messageText = "新建笔记文件夹"
        alert.addButton(withTitle: "新建")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "文件夹名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        modelContext.insert(NoteFolder(name: name))
    }

    private func addLibraryViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "添加为 Library"
        if panel.runModal() == .OK, let url = panel.url {
            LibraryManager.shared.addLibrary(url)
        }
    }

    private func openFileViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.prompt = "打开"
        if panel.runModal() == .OK, let url = panel.url {
            LibraryManager.shared.openSingleFile(url)
            openFileTab(url: url, title: url.deletingPathExtension().lastPathComponent)
        }
    }

    private func revealActiveTabInFinder() {
        guard let id = activeTabID,
              let tab = openTabs.first(where: { $0.id == id }) else { return }

        switch tab.content {
        case .file(let url, _):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .note:
            // Notes don't have file paths, so ignore
            break
        }
    }
}

// MARK: - Tab Bar

struct TabBarView: View {
    @Binding var tabs: [OpenTab]
    @Binding var activeTabID: UUID?
    @Binding var secondaryTabID: UUID?
    @Binding var tabGroups: [TabGroup]
    let onClose: (OpenTab) -> Void
    let onTogglePin: (OpenTab) -> Void
    let onAddGroup: (OpenTab) -> Void
    let onRemoveFromGroup: (OpenTab) -> Void
    let onMoveToGroup: (OpenTab, UUID) -> Void
    let onCreateTabAfter: (OpenTab) -> Void

    /// ID of the tab currently being dragged (gesture-based, horizontal-only).
    @State private var draggingID: UUID? = nil
    /// Visual X offset of the dragged tab (only updated in X, Y is fixed).
    @State private var dragOffsetX: CGFloat = 0
    /// Cumulative offset adjustment from swaps, so total-translation stays meaningful.
    @State private var dragBaseX: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let tabID = tab.id
                    let isDragging = draggingID == tabID
                    let group = tab.groupID.flatMap { gid in tabGroups.first { $0.id == gid } }
                    let otherGroups = tabGroups.filter { $0.id != tab.groupID }
                    TabItemView(
                        tab: tab,
                        isActive: tabID == activeTabID,
                        isSecondary: tabID == secondaryTabID,
                        group: group,
                        otherGroups: otherGroups,
                        isDragging: isDragging,
                        onTap: { activeTabID = tabID },
                        onClose: { onClose(tab) },
                        onTogglePin: { onTogglePin(tab) },
                        onOpenAsSecondary: {
                            secondaryTabID = secondaryTabID == tabID ? nil : tabID
                        },
                        onAddGroup: { onAddGroup(tab) },
                        onRemoveFromGroup: { onRemoveFromGroup(tab) },
                        onMoveToGroup: { gid in onMoveToGroup(tab, gid) },
                        onCreateAfter: { onCreateTabAfter(tab) }
                    )
                    // Horizontal-only drag: apply X offset, keep Y fixed.
                    .offset(x: isDragging ? dragOffsetX : 0, y: 0)
                    .zIndex(isDragging ? 1 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                if draggingID == nil {
                                    draggingID = tabID
                                    dragBaseX  = 0
                                }
                                guard draggingID == tabID else { return }

                                // Effective offset relative to drag origin after swaps
                                let effective = value.translation.width + dragBaseX
                                dragOffsetX = effective

                                // Swap with neighbour when dragged past ≈ one tab width
                                // Increased threshold to reduce sensitivity and make dragging smoother
                                let threshold: CGFloat = 120
                                guard let fromIdx = tabs.firstIndex(where: { $0.id == tabID })
                                else { return }

                                if effective > threshold, fromIdx < tabs.count - 1 {
                                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                                        tabs.swapAt(fromIdx, fromIdx + 1)
                                    }
                                    dragBaseX  -= threshold
                                    dragOffsetX = effective - threshold
                                } else if effective < -threshold, fromIdx > 0 {
                                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                                        tabs.swapAt(fromIdx, fromIdx - 1)
                                    }
                                    dragBaseX  += threshold
                                    dragOffsetX = effective + threshold
                                }
                            }
                            .onEnded { _ in
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                    draggingID  = nil
                                    dragOffsetX = 0
                                    dragBaseX   = 0
                                }
                            }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .frame(height: 38)
        .background(.bar)
    }
}

// MARK: - Tab Item View

private struct TabItemView: View {
    let tab: OpenTab
    let isActive: Bool
    let isSecondary: Bool
    let group: TabGroup?
    let otherGroups: [TabGroup]   // groups this tab is NOT in (for "move to group" submenu)
    let isDragging: Bool
    let onTap: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void
    let onOpenAsSecondary: () -> Void
    let onAddGroup: () -> Void
    let onRemoveFromGroup: () -> Void
    let onMoveToGroup: (UUID) -> Void
    let onCreateAfter: () -> Void

    var body: some View {
        Group {
            if tab.isPinned {
                pinnedTabBody
            } else {
                normalTabBody
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .opacity(isDragging ? 0.45 : 1.0)
        .contextMenu { contextMenuContent }
    }

    // MARK: Pinned tab (icon only)

    private var pinnedTabBody: some View {
        ZStack(alignment: .bottom) {
            Image(systemName: tab.icon)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 32, height: 28)
                .background(tabBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(tabBorder)
                .overlay(alignment: .topTrailing) { secondaryBadge }

            groupBar
        }
        .frame(width: 32)
        .help(tab.title)
    }

    // MARK: Normal tab (icon + title + close)

    private var normalTabBody: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 5) {
                // Group color dot
                if let group = group {
                    Circle()
                        .fill(group.color)
                        .frame(width: 7, height: 7)
                }

                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? .primary : .secondary)

                Text(tab.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .leading)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(tabBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(tabBorder)
            .overlay(alignment: .topTrailing) { secondaryBadge }

            groupBar
        }
    }

    // MARK: Shared decorations

    /// Small accent dot in top-right corner indicating this tab is the second editor.
    @ViewBuilder
    private var secondaryBadge: some View {
        if isSecondary {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .offset(x: 2, y: -2)
        }
    }

    /// Colored 2 px bar along the bottom edge for group membership.
    @ViewBuilder
    private var groupBar: some View {
        if let group = group {
            Rectangle()
                .fill(group.color)
                .frame(height: 2)
        }
    }

    private var tabBackground: some View {
        isActive
            ? Color(nsColor: .controlBackgroundColor)
            : Color(nsColor: .controlBackgroundColor).opacity(0.4)
    }

    private var tabBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
                isActive ? Color(nsColor: .separatorColor) : .clear,
                lineWidth: 0.5
            )
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenuContent: some View {
        // ── 创建 ─────────────────────────────────────────────────
        Button("在右侧新增标签页") { onCreateAfter() }

        Divider()

        // ── 第二编辑器 ────────────────────────────────────────────
        Button(isSecondary ? "关闭第二编辑器" : "作为第二编辑器打开") {
            onOpenAsSecondary()
        }

        Divider()

        // ── 群组管理 ──────────────────────────────────────────────
        if let group = group {
            Text("群组：\(group.name)")
                .foregroundStyle(.secondary)
            Button("移出群组") { onRemoveFromGroup() }
            if !otherGroups.isEmpty {
                Menu("移至其他群组") {
                    ForEach(otherGroups) { g in
                        Button { onMoveToGroup(g.id) } label: {
                            Label(g.name, systemImage: "circle.fill")
                        }
                    }
                }
            }
            Divider()
        }

        Button("向新群组中添加标签页") { onAddGroup() }

        if !otherGroups.isEmpty && group == nil {
            Menu("添加到已有群组") {
                ForEach(otherGroups) { g in
                    Button { onMoveToGroup(g.id) } label: {
                        Label(g.name, systemImage: "circle.fill")
                    }
                }
            }
        }

        Divider()

        // ── 固定 / 关闭 ───────────────────────────────────────────
        Button(tab.isPinned ? "取消固定标签页" : "固定标签页") { onTogglePin() }
        Button("关闭标签页", role: .destructive) { onClose() }
    }
}

