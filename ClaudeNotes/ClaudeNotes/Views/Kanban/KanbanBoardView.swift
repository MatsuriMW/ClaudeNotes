import SwiftUI
import SwiftData

// MARK: - Board

struct KanbanBoardView: View {
    @Query(sort: \Note.modifiedAt, order: .reverse) private var allNotes: [Note]
    @Environment(\.dismiss) private var dismiss

    // Custom task items (for container view) - made binding for mutability
    @Binding var customTaskItems: [TaskItem]?
    var onSelectNote: ((Note) -> Void)?

    private let settings = TaskSettings.shared
    @State private var showSettings = false
    @State private var library = LibraryManager.shared
    @State private var isRefreshing = false

    // Side panel state
    @State private var editingTask: TaskItem? = nil
    @State private var highlightTaskID: String? = nil  // 用于黄色高亮标记
    @State private var isMultiSelectMode = false  // Command key pressed
    @State private var selectedTaskIDs: Set<String> = []  // 多选的任务 ID
    @State private var lastSelectedTaskID: String? = nil  // 最后点击的任务（用于 Shift 范围选择）

    private var tasks: [TaskItem] {
        if let custom = customTaskItems {
            return custom.sorted { compareTasks($0, $1) }
        }
        return extractTasksFromNotes().sorted { compareTasks($0, $1) }
    }

    /// Sort tasks: pinned first, then by display order, then by original position
    private func compareTasks(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        if a.displayOrder != b.displayOrder { return a.displayOrder < b.displayOrder }
        if a.status != b.status { return a.status < b.status }
        return a.id < b.id
    }

    private var hasNotes: Bool {
        customTaskItems != nil || !allNotes.isEmpty || !library.libraries.isEmpty
    }

    /// Sort columns: non-empty columns first, then empty columns
    private var sortedColumns: [TaskSettings.TaskColumn] {
        let nonEmpty = settings.columns.filter { column in
            tasks.contains { $0.status == column.keyword }
        }
        let empty = settings.columns.filter { column in
            !tasks.contains { $0.status == column.keyword }
        }
        return nonEmpty + empty
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main board
            VStack(spacing: 0) {
                boardToolbar
                Divider()
                if tasks.isEmpty && hasNotes {
                    emptyHint
                } else if tasks.isEmpty {
                    noNotesHint
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 12) {
                            // Sort columns: non-empty first, then empty columns
                            ForEach(sortedColumns, id: \.self) { column in
                                KanbanColumnView(
                                    column: column,
                                    columnTasks: tasks.filter { $0.status == column.keyword },
                                    allTasks: tasks,
                                    allColumns: settings.columns,
                                    editingTask: editingTask,
                                    onMove: { task, status in moveTask(task, to: status) },
                                    onDelete: { task in deleteTask(task) },
                                    onOpenEditor: { task in
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            editingTask = task
                                            highlightTaskID = task.id
                                        }
                                    },
                                    onCloseEditor: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            editingTask = nil
                                            highlightTaskID = nil
                                        }
                                    },
                                    onMoveUp: { task in moveTaskUp(task) },
                                    onMoveDown: { task in moveTaskDown(task) },
                                    onTogglePin: { task in togglePin(task) },
                                    onToggleSelection: { task in toggleSelection(task) },
                                    onSetPriority: { priority in setPriority(priority) },
                                    onToggleCheckbox: { task in toggleCheckbox(task) }
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: editingTask == nil ? .infinity : nil)

            // Side panel for editing
            if let task = editingTask {
                Divider()
                kanbanEditorPanel(for: task)
                    .frame(width: 450)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .animation(.spring(response: 0.35, dampingFraction: 0.85, blendDuration: 0), value: editingTask != nil)
        .sheet(isPresented: $showSettings) {
            KanbanSettingsView(settings: settings, noteCount: allNotes.count)
        }
        .onAppear {
            // Listen for keyboard events
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // ESC key - close editor
                if event.keyCode == 53 {
                    if editingTask != nil {
                        DispatchQueue.main.async {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                editingTask = nil
                                highlightTaskID = nil
                            }
                        }
                        return nil
                    }
                }
                // Command key - multi-select mode
                if event.keyCode == 55 || event.keyCode == 54 { // Left or Right Command
                    isMultiSelectMode = true
                    return event
                }
                return event
            }

            NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                if event.keyCode == 55 || event.keyCode == 54 {
                    isMultiSelectMode = false
                }
                return event
            }
        }
    }

    @ViewBuilder
    private func kanbanEditorPanel(for task: TaskItem) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "rectangle.righthalf.inset.filled")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(task.noteTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    editingTask = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Editor content
            if let fileURL = task.fileURL {
                let mod = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                FileNoteEditorView(
                    fileNote: FileNote(url: fileURL, modifiedAt: mod),
                    highlightQuery: .constant(nil),
                    jumpToLine: task.originalLineIndex,
                    highlightTaskText: highlightTaskID == task.id ? task.text : nil,
                    onRename: nil
                )
                .id(task.id)
                .onAppear {
                    // 延迟清除高亮标记，确保高亮能显示
                    if highlightTaskID == task.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            highlightTaskID = nil
                        }
                    }
                }
            } else {
                NoteEditorView(note: task.note)
                    .id(task.id)
            }
        }
    }

    private var boardToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(.secondary)
            Text("任务看板")
                .font(.headline)
            Spacer()
            if !tasks.isEmpty {
                Text("\(tasks.count) 个任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                refreshTasks()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新任务列表")
            .disabled(isRefreshing)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("自定义状态列")
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("还没有任务条目")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("在笔记任意位置写下关键词即可自动提取\n例如：`- todo 买牛奶`  `#toread 这篇文章值得一读`  `doing: 写周报`")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noNotesHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("暂无笔记")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("创建笔记或添加外部文件夹来开始管理任务")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func moveTask(_ task: TaskItem, to status: String) {
        if task.fileURL != nil {
            _ = TaskExtractionService.updateStatusInFile(task, newStatus: status)
        } else {
            TaskExtractionService.updateStatus(of: task, to: status, in: task.note, settings: settings)
        }
        // Refresh tasks to update the UI
        refreshTasks()
    }

    private func editText(_ task: TaskItem, newText: String) {
        if task.fileURL != nil {
            _ = TaskExtractionService.updateTextInFile(task, newText: newText)
        } else {
            TaskExtractionService.updateText(of: task, to: newText, in: task.note)
        }
    }

    private func deleteTask(_ task: TaskItem) {
        if task.fileURL != nil {
            _ = TaskExtractionService.deleteFromFile(task)
        } else {
            TaskExtractionService.delete(task, from: task.note)
        }
    }

    /// Move task up within its column
    private func moveTaskUp(_ task: TaskItem) {
        guard var items = customTaskItems else { return }
        guard items.firstIndex(where: { $0.id == task.id }) != nil else { return }

        // Find the previous task in the same column (excluding pinned tasks)
        let sameColumnTasks = items.filter { $0.status == task.status && !$0.isPinned }
        guard let taskIndex = sameColumnTasks.firstIndex(where: { $0.id == task.id }),
              taskIndex > 0 else { return }

        let prevTask = sameColumnTasks[taskIndex - 1]

        // Swap display orders
        if let itemIndex = items.firstIndex(where: { $0.id == task.id }),
           let prevIndex = items.firstIndex(where: { $0.id == prevTask.id }) {
            let tempOrder = items[itemIndex].displayOrder
            items[itemIndex].displayOrder = items[prevIndex].displayOrder
            items[prevIndex].displayOrder = tempOrder
            customTaskItems = items
        }
    }

    /// Move task down within its column
    private func moveTaskDown(_ task: TaskItem) {
        guard var items = customTaskItems else { return }
        guard items.firstIndex(where: { $0.id == task.id }) != nil else { return }

        // Find the next task in the same column (excluding pinned tasks)
        let sameColumnTasks = items.filter { $0.status == task.status && !$0.isPinned }
        guard let taskIndex = sameColumnTasks.firstIndex(where: { $0.id == task.id }),
              taskIndex < sameColumnTasks.count - 1 else { return }

        let nextTask = sameColumnTasks[taskIndex + 1]

        // Swap display orders
        if let itemIndex = items.firstIndex(where: { $0.id == task.id }),
           let nextIndex = items.firstIndex(where: { $0.id == nextTask.id }) {
            let tempOrder = items[itemIndex].displayOrder
            items[itemIndex].displayOrder = items[nextIndex].displayOrder
            items[nextIndex].displayOrder = tempOrder
            customTaskItems = items
        }
    }

    /// Toggle pin status for a task
    private func togglePin(_ task: TaskItem) {
        guard var items = customTaskItems else { return }
        guard let index = items.firstIndex(where: { $0.id == task.id }) else { return }

        items[index].isPinned.toggle()

        // When pinning, set display order to be first among pinned
        if items[index].isPinned {
            let pinnedCount = items.filter { $0.isPinned && $0.status == task.status }.count
            items[index].displayOrder = -pinnedCount
        } else {
            items[index].displayOrder = items.filter { $0.status == task.status }.count
        }

        customTaskItems = items
    }

    /// Toggle task selection
    private func toggleSelection(_ task: TaskItem) {
        guard var items = customTaskItems else { return }

        // Check if Shift key is pressed for range selection
        let isShiftPressed = NSEvent.modifierFlags.contains(.shift)

        if isShiftPressed, let lastID = lastSelectedTaskID, let lastIndex = items.firstIndex(where: { $0.id == lastID }), let currentIndex = items.firstIndex(where: { $0.id == task.id }) {
            // Range selection: select all tasks between last and current
            let start = min(lastIndex, currentIndex)
            let end = max(lastIndex, currentIndex)

            // Clear existing selection
            for i in items.indices {
                items[i].isSelected = false
            }
            selectedTaskIDs.removeAll()

            // Select range
            for i in start...end {
                items[i].isSelected = true
                selectedTaskIDs.insert(items[i].id)
            }

            customTaskItems = items
            return
        }

        // Normal toggle selection
        guard let index = items.firstIndex(where: { $0.id == task.id }) else { return }

        items[index].isSelected.toggle()

        if items[index].isSelected {
            selectedTaskIDs.insert(task.id)
            lastSelectedTaskID = task.id  // Update last selected
        } else {
            selectedTaskIDs.remove(task.id)
            if lastSelectedTaskID == task.id {
                lastSelectedTaskID = nil
            }
        }

        customTaskItems = items
    }

    /// Set priority for selected tasks
    private func setPriority(_ priority: TaskPriority) {
        guard var items = customTaskItems else { return }

        for taskID in selectedTaskIDs {
            if let index = items.firstIndex(where: { $0.id == taskID }) {
                items[index].priority = priority
            }
        }

        customTaskItems = items
        selectedTaskIDs.removeAll()
    }

    /// Select all tasks in current column
    private func selectAllInColumn(_ columnKeyword: String) {
        guard var items = customTaskItems else { return }

        for index in items.indices {
            if items[index].status == columnKeyword {
                items[index].isSelected = true
                selectedTaskIDs.insert(items[index].id)
            }
        }

        customTaskItems = items
    }

    /// Deselect all tasks
    private func deselectAll() {
        guard var items = customTaskItems else { return }

        for index in items.indices {
            items[index].isSelected = false
        }

        selectedTaskIDs.removeAll()
        customTaskItems = items
    }

    /// Toggle checkbox status for markdown-style tasks
    private func toggleCheckbox(_ task: TaskItem) {
        // Only allow toggle for checkbox-style tasks
        guard task.matchedKeyword == "[ ]" || task.matchedKeyword == "[x]" else { return }

        // Determine new status
        let newStatus: String
        if task.matchedKeyword == "[ ]" {
            newStatus = "done"  // [ ] -> [x]
        } else {
            newStatus = "todo"  // [x] -> [ ]
        }

        // Update in the data store
        if task.fileURL != nil {
            // External file
            _ = TaskExtractionService.updateStatusInFile(task, newStatus: newStatus)
        } else {
            // Database note
            TaskExtractionService.updateStatus(of: task, to: newStatus, in: task.note, settings: settings)
        }

        // Refresh tasks
        refreshTasks()
    }

    // MARK: - Task Extraction (including library files)

    /// Extract tasks from both notes and library files
    private func extractTasksFromNotes() -> [TaskItem] {
        var allTasks: [TaskItem] = []

        // Extract from database notes
        let noteTasks = TaskExtractionService.extract(from: Array(allNotes), settings: settings)
        allTasks.append(contentsOf: noteTasks)

        // Extract from library files (all files, no date filter)
        for lib in library.libraries {
            for file in lib.files {
                if let content = try? String(contentsOf: file.url, encoding: .utf8) {
                    let fileTasks = extractTasksFromFile(file: file, content: content)
                    allTasks.append(contentsOf: fileTasks)
                }
            }
        }

        return allTasks
    }

    /// Extract tasks from a single file content
    private func extractTasksFromFile(file: FileNote, content: String) -> [TaskItem] {
        var tasks: [TaskItem] = []
        let lines = content.components(separatedBy: "\n")

        // Build keyword map
        var keywordMap: [String: String] = [:]
        for col in settings.columns {
            for kw in col.allKeywords {
                keywordMap[kw.lowercased()] = col.keyword
            }
        }
        let sortedKeywords = keywordMap.keys.sorted { $0.count > $1.count }

        var inCodeBlock = false

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Track fenced code blocks
            if trimmed.hasPrefix("```") { inCodeBlock.toggle(); continue }
            if inCodeBlock || trimmed.isEmpty { continue }

            // MUST start with unordered list marker (-, *, +)
            guard let (_, content) = TaskExtractionService.listItemParts(of: line) else { continue }

            // Find the first matching keyword at the start of content
            var matched: (status: String, keyword: String)?
            for kw in sortedKeywords {
                // Keyword must be at the start of content (after list marker)
                if content.lowercased().hasPrefix(kw.lowercased()) {
                    // Verify it's a whole word match
                    let nextIdx = content.index(content.startIndex, offsetBy: kw.count)
                    if nextIdx == content.endIndex ||
                       !content[nextIdx].isLetter && !content[nextIdx].isNumber {
                        matched = (keywordMap[kw]!, kw)
                        break
                    }
                }
            }
            guard let (status, matchedKw) = matched else { continue }

            let (text, _) = displayTextAndPosition(trimmed: trimmed, keyword: matchedKw)

            // Create a placeholder note for file tasks
            let placeholderNote = Note(title: file.displayTitle, content: content)
            placeholderNote.modifiedAt = file.modifiedAt

            var task = TaskItem(
                note: placeholderNote,
                status: status,
                text: text,
                originalLine: line,
                originalLineIndex: index,
                matchedKeyword: matchedKw,
                keywordLeadsContent: true
            )
            task.fileURL = file.url
            tasks.append(task)
        }

        return tasks
    }

    /// Refresh tasks from all sources
    private func refreshTasks() {
        isRefreshing = true
        // Force refresh all libraries
        library.refreshAllLibraries()

        // Small delay to let files load
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRefreshing = false
        }
    }

    /// Check if word appears as whole word in text
    private func containsWholeWord(_ word: String, in text: String) -> Bool {
        guard !word.isEmpty else { return false }
        var pos = text.startIndex
        while pos < text.endIndex {
            guard let range = text.range(of: word, options: .caseInsensitive, range: pos..<text.endIndex) else { break }
            let beforeOK = range.lowerBound == text.startIndex ||
                           !text[text.index(before: range.lowerBound)].isLetter &&
                           !text[text.index(before: range.lowerBound)].isNumber
            let afterOK = range.upperBound == text.endIndex ||
                          !text[range.upperBound].isLetter &&
                          !text[range.upperBound].isNumber
            if beforeOK && afterOK { return true }
            pos = text.index(after: range.lowerBound)
        }
        return false
    }

    /// Returns display text and whether keyword leads content
    private func displayTextAndPosition(trimmed: String, keyword: String) -> (text: String, leads: Bool) {
        let content: String
        if let (_, c) = TaskExtractionService.listItemParts(of: trimmed) { content = c } else { content = trimmed }

        let kwLen = keyword.count
        guard content.count >= kwLen else { return (content, false) }

        let prefix = content.prefix(kwLen)
        guard prefix.lowercased() == keyword.lowercased() else { return (content, false) }

        let afterIdx = content.index(content.startIndex, offsetBy: kwLen)
        if afterIdx < content.endIndex, content[afterIdx].isLetter || content[afterIdx].isNumber {
            return (content, false)
        }

        var rest = String(afterIdx < content.endIndex ? content[afterIdx...] : "")
        if rest.hasPrefix(":") { rest = String(rest.dropFirst()) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? content : rest, true)
    }
}

// MARK: - Column

private struct KanbanColumnView: View {
    let column: TaskSettings.TaskColumn
    let columnTasks: [TaskItem]
    let allTasks: [TaskItem]
    let allColumns: [TaskSettings.TaskColumn]
    let editingTask: TaskItem?
    let onMove: (TaskItem, String) -> Void
    let onDelete: (TaskItem) -> Void
    let onOpenEditor: (TaskItem) -> Void
    let onCloseEditor: () -> Void
    let onMoveUp: (TaskItem) -> Void
    let onMoveDown: (TaskItem) -> Void
    let onTogglePin: (TaskItem) -> Void
    let onToggleSelection: (TaskItem) -> Void
    let onSetPriority: (TaskPriority) -> Void
    let onToggleCheckbox: (TaskItem) -> Void

    @State private var isTargeted = false

    private var color: Color { hexColor(column.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(Array(columnTasks.enumerated()), id: \.element.id) { index, task in
                        KanbanCardView(
                            task: task,
                            allColumns: allColumns,
                            onMove: { onMove(task, $0) },
                            onDelete: { onDelete(task) },
                            onOpenEditor: { onOpenEditor(task) },
                            onCloseEditor: onCloseEditor,
                            onMoveUp: { onMoveUp(task) },
                            onMoveDown: { onMoveDown(task) },
                            onTogglePin: { onTogglePin(task) },
                            onToggleSelection: { onToggleSelection(task) },
                            onSetPriority: { onSetPriority($0) },
                            onToggleCheckbox: { onToggleCheckbox(task) },
                            canMoveUp: index > 0,
                            canMoveDown: index < columnTasks.count - 1,
                            isCurrentlyEditing: editingTask?.id == task.id
                        )
                        .draggable(task.id)
                    }
                    // Empty drop zone so columns without cards are still droppable
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: columnTasks.isEmpty ? 80 : 8)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first,
                                  let draggedTask = allTasks.first(where: { $0.id == id }),
                                  draggedTask.status != column.keyword else { return false }
                            onMove(draggedTask, column.keyword)
                            return true
                        }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 240)
        .frame(minHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? color.opacity(0.07) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isTargeted ? color.opacity(0.5) : Color.primary.opacity(0.10),
                    lineWidth: isTargeted ? 2 : 1
                )
        )
    }

    private var columnHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(column.displayName)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(columnTasks.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Card

private struct KanbanCardView: View {
    let task: TaskItem
    let allColumns: [TaskSettings.TaskColumn]
    let onMove: (String) -> Void
    let onDelete: () -> Void
    let onOpenEditor: () -> Void
    let onCloseEditor: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onTogglePin: () -> Void
    let onToggleSelection: () -> Void
    let onSetPriority: (TaskPriority) -> Void
    let onToggleCheckbox: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let isCurrentlyEditing: Bool

    private var isCheckboxTask: Bool {
        // Show checkbox for todo/done columns OR if it's a markdown checkbox task
        task.status == "todo" || task.status == "done" || task.matchedKeyword == "[ ]" || task.matchedKeyword == "[x]"
    }

    private var isCheckboxChecked: Bool {
        // Check if task is in done column or has [x] keyword
        task.status == "done" || task.matchedKeyword == "[x]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 4) {
                // Checkbox for markdown-style tasks
                if isCheckboxTask {
                    Button(action: onToggleCheckbox) {
                        Image(systemName: isCheckboxChecked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(isCheckboxChecked ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isCheckboxChecked ? "标记为未完成" : "标记为已完成")
                }

                // Priority indicator
                if task.priority != .none {
                    Circle()
                        .fill(colorFromHex(task.priority.colorHex))
                        .frame(width: 6, height: 6)
                        .help(task.priority.displayName)
                }

                if task.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }

                Text(task.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(isCheckboxTask && isCheckboxChecked, color: .secondary)
                    .onTapGesture(count: 2) {
                        if isCurrentlyEditing {
                            onCloseEditor()
                        } else {
                            onOpenEditor()
                        }
                    }

                Spacer()
            }

            Button(action: onOpenEditor) {
                HStack(spacing: 3) {
                    Image(systemName: "note.text")
                        .font(.system(size: 9))
                    Text(task.noteTitle)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(task.priority.backgroundColor)
                RoundedRectangle(cornerRadius: 6)
                    .fill(task.isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(task.isSelected ? Color.accentColor : (isCurrentlyEditing ? Color.accentColor.opacity(0.5) : Color.clear), lineWidth: task.isSelected ? 2 : (isCurrentlyEditing ? 2 : 1))
        )
        .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
        .contextMenu {
            Menu("移动到") {
                ForEach(allColumns.filter { $0.keyword != task.status }) { col in
                    Button {
                        onMove(col.keyword)
                    } label: {
                        Text(col.displayName)
                    }
                }
            }
            Divider()
            Button(task.isPinned ? "取消置顶" : "置顶") {
                onTogglePin()
            }
            Button("上移") {
                onMoveUp()
            }
            .disabled(!canMoveUp && !task.isPinned)
            Button("下移") {
                onMoveDown()
            }
            .disabled(!canMoveDown)
            Divider()
            Menu("设置优先级") {
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    Button {
                        onSetPriority(priority)
                    } label: {
                        HStack {
                            Circle()
                                .fill(colorFromHex(priority.colorHex))
                                .frame(width: 8, height: 8)
                            Text(priority.displayName)
                            if task.priority == priority {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
            Button(isCurrentlyEditing ? "关闭编辑器" : "在编辑器中打开") {
                if isCurrentlyEditing {
                    onCloseEditor()
                } else {
                    onOpenEditor()
                }
            }
            Divider()
            Button("删除任务", role: .destructive, action: onDelete)
        }
        .onTapGesture(count: 1) {
            // Single tap to toggle selection when Command is held
            if NSEvent.modifierFlags.contains(.command) {
                onToggleSelection()
            }
        }
    }
}

// MARK: - Settings

struct KanbanSettingsView: View {
    @Bindable var settings: TaskSettings
    @Environment(\.dismiss) private var dismiss
    var noteCount: Int = 0  // Number of database notes

    @State private var showAdd = false
    @State private var newKeyword = ""
    @State private var newDisplayName = ""
    @State private var newColorHex = "#3B82F6"
    @State private var editingAliasesFor: String? = nil  // column keyword

    private let palette = ["#6B7280","#3B82F6","#F59E0B","#10B981",
                            "#EF4444","#9CA3AF","#8B5CF6","#EC4899","#F97316","#06B6D4"]

    // Suggested quick-add keywords with display names
    private let suggestions: [(kw: String, name: String, color: String)] = [
        ("toread",   "待读",  "#8B5CF6"),
        ("towatch",  "待看",  "#EC4899"),
        ("tolisten", "待听",  "#06B6D4"),
        ("togo",     "待去",  "#F97316"),
        ("tobuy",    "待买",  "#10B981"),
        ("tolearn",  "待学",  "#3B82F6"),
        ("someday",  "将来",  "#9CA3AF"),
        ("idea",     "想法",  "#F59E0B"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("自定义状态列")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // ── Current columns ──────────────────────────────────
                    sectionHeader("当前状态列", note: "拖动排序，左滑删除")

                    List {
                        ForEach($settings.columns) { $col in
                            columnRow(col: $col)
                        }
                        .onDelete { settings.removeColumn(at: $0) }
                        .onMove   { settings.moveColumn(from: $0, to: $1) }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: CGFloat(settings.columns.count) * 58 + 8)

                    Divider().padding(.vertical, 4)

                    // ── Quick add suggestions ─────────────────────────────
                    sectionHeader("快速添加关键词",
                                  note: "点击一键添加，笔记中包含该词的行会自动归入此列")

                    let available = suggestions.filter { s in
                        !settings.columns.contains(where: {
                            $0.keyword == s.kw || $0.aliases.contains(s.kw)
                        })
                    }
                    if available.isEmpty {
                        Text("所有建议关键词已添加")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(available, id: \.kw) { s in
                                    Button {
                                        settings.addColumn(.init(
                                            keyword: s.kw,
                                            displayName: s.name,
                                            colorHex: s.color,
                                            aliases: []))
                                    } label: {
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(hexColor(s.color))
                                                .frame(width: 7, height: 7)
                                            Text(s.name)
                                                .font(.system(size: 12, weight: .medium))
                                            Text(s.kw)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(.quaternary.opacity(0.6),
                                                    in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 10)
                        }
                    }

                    Divider().padding(.vertical, 4)

                    // ── Custom add ────────────────────────────────────────
                    sectionHeader("自定义关键词", note: "在笔记任何位置写下关键词即可识别")
                    if showAdd {
                        addRow.padding(.horizontal, 16).padding(.bottom, 12)
                    } else {
                        Button { showAdd = true } label: {
                            Label("新建状态列…", systemImage: "plus.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }

                    Divider().padding(.vertical, 4)

                    // ── Kanban Data Sources ────────────────────────────────
                    sectionHeader("数据源", note: "配置看板读取哪些笔记文件")

                    VStack(alignment: .leading, spacing: 8) {
                        // Database notes option
                        Toggle("读取数据库笔记", isOn: Binding(
                            get: { settings.kanbanDataSources.isEmpty },
                            set: { if $0 { settings.kanbanDataSources = []; settings.save() } }
                        ))
                        .font(.system(size: 12))

                        Text("当前会读取 \(noteCount) 篇数据库笔记")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)

                        Divider().padding(.vertical, 4)

                        // Library folders section
                        HStack {
                            Text("文件库文件夹")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button {
                                addDataSource()
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                        }

                        if settings.kanbanDataSources.isEmpty {
                            Text("未添加任何文件库文件夹")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach($settings.kanbanDataSources) { $source in
                                DataSourceRow(source: $source, onDelete: {
                                    if let idx = settings.kanbanDataSources.firstIndex(where: { $0.id == source.id }) {
                                        settings.kanbanDataSources.remove(at: idx)
                                        settings.save()
                                    }
                                })
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    // ── Usage hint ────────────────────────────────────────
                    usageHint
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .frame(width: 500, height: 560)
    }

    // MARK: - Sub-views

    private func sectionHeader(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func columnRow(col: Binding<TaskSettings.TaskColumn>) -> some View {
        let c = col.wrappedValue
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Color dot + picker
                Menu {
                    ForEach(palette, id: \.self) { hex in
                        Button {
                            col.wrappedValue.colorHex = hex
                            settings.save()
                        } label: {
                            Label(hex, systemImage: c.colorHex == hex ? "checkmark" : "circle.fill")
                        }
                    }
                } label: {
                    Circle()
                        .fill(hexColor(c.colorHex))
                        .frame(width: 12, height: 12)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16)

                // Display name
                TextField("显示名称", text: col.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .onChange(of: c.displayName) { _, _ in settings.save() }

                Spacer()

                // Keyword badge
                Text(c.keyword)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }

            // Aliases row
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if c.aliases.isEmpty {
                    Text("无别名（点击添加）")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(c.aliases, id: \.self) { alias in
                        Text(alias)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.7),
                                        in: RoundedRectangle(cornerRadius: 3))
                        // Remove alias
                            .onTapGesture {
                                col.wrappedValue.aliases.removeAll { $0 == alias }
                                settings.save()
                            }
                    }
                }
            }
            .onTapGesture { editingAliasesFor = c.keyword }
            .sheet(isPresented: Binding(
                get: { editingAliasesFor == c.keyword },
                set: { if !$0 { editingAliasesFor = nil } }
            )) {
                AliasEditorView(column: col, settings: settings)
            }
        }
        .padding(.vertical, 4)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(palette, id: \.self) { hex in
                    Circle()
                        .fill(hexColor(hex))
                        .frame(width: 18, height: 18)
                        .overlay(Circle()
                            .stroke(Color.primary.opacity(newColorHex == hex ? 0.8 : 0), lineWidth: 2))
                        .onTapGesture { newColorHex = hex }
                }
            }
            HStack(spacing: 8) {
                TextField("关键词（英文）", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                TextField("显示名称", text: $newDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button("添加") {
                    let kw = newKeyword.lowercased().trimmingCharacters(in: .whitespaces)
                    let name = newDisplayName.trimmingCharacters(in: .whitespaces)
                    guard !kw.isEmpty, !name.isEmpty,
                          !settings.columns.contains(where: { $0.keyword == kw }) else { return }
                    settings.addColumn(.init(keyword: kw, displayName: name,
                                             colorHex: newColorHex, aliases: []))
                    newKeyword = ""; newDisplayName = ""; showAdd = false
                }
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty ||
                          newDisplayName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消") { newKeyword = ""; newDisplayName = ""; showAdd = false }
            }
        }
    }

    private var usageHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("使用方法")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("""
                在笔记的任意位置（包括列表、标题、正文）写下关键词，\
                该行内容会自动出现在对应看板列中。大小写不敏感。

                示例：
                · - todo 买牛奶
                · doing: 写周报
                · [toread] 深度工作
                · 记得 TODO 这件事
                """)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineSpacing(2)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func addDataSource() {
        settings.addKanbanDataSource(TaskSettings.KanbanDataSource())
    }
}

// MARK: - Data Source Row

private struct DataSourceRow: View {
    @Binding var source: TaskSettings.KanbanDataSource
    let onDelete: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Main row
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if source.folderPath.isEmpty {
                    Text("未选择文件夹")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(source.folderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                }

                Spacer()

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }

            // Expanded options
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Folder path
                    HStack(spacing: 6) {
                        Text("文件夹:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button("选择文件夹...") {
                            selectFolder()
                        }
                        .font(.system(size: 10))
                    }

                    // File pattern
                    HStack(spacing: 6) {
                        Text("文件匹配:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("*.md", text: $source.filePattern)
                            .font(.system(size: 10, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    // Max files
                    HStack(spacing: 6) {
                        Text("最多文件:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Stepper(value: $source.maxFiles, in: 0...1000, step: 10) {
                            Text(source.maxFiles == 0 ? "无限制" : "\(source.maxFiles)")
                                .font(.system(size: 10))
                        }
                    }

                    // Sort order
                    HStack(spacing: 6) {
                        Text("排序:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $source.sortOrder) {
                            ForEach(TaskSettings.KanbanDataSource.SortOrder.allCases, id: \.self) { order in
                                Text(order.displayName).tag(order)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }

                    // Date range
                    HStack(spacing: 6) {
                        Text("日期范围:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $source.dateRange) {
                            ForEach(TaskSettings.KanbanDataSource.DateRange.allCases, id: \.self) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }

                    // Days around (if selected)
                    if source.dateRange == .aroundToday {
                        HStack(spacing: 6) {
                            Text("前后天数:")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Stepper(value: $source.daysAround, in: 1...30) {
                                Text("\(source.daysAround) 天")
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }
                .padding(.leading, 24)
                .onChange(of: source.folderPath) { _, _ in
                    TaskSettings.shared.save()
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择包含 Markdown 文件的文件夹"

        if panel.runModal() == .OK, let url = panel.url {
            source.folderPath = url.path
            TaskSettings.shared.save()
        }
    }
}

// MARK: - Alias editor sheet

private struct AliasEditorView: View {
    @Binding var column: TaskSettings.TaskColumn
    let settings: TaskSettings
    @Environment(\.dismiss) private var dismiss

    @State private var newAlias = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("「\(column.displayName)」的别名关键词")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Text("多个关键词映射到同一个列。例如 todo 列可添加 task、fixme 等别名。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            List {
                // Primary keyword (non-removable)
                HStack {
                    Image(systemName: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(column.keyword)
                        .font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Text("主关键词")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(column.aliases, id: \.self) { alias in
                    HStack {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(alias)
                            .font(.system(size: 13, design: .monospaced))
                        Spacer()
                    }
                }
                .onDelete { offsets in
                    column.aliases.remove(atOffsets: offsets)
                    settings.save()
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180)

            Divider()

            HStack(spacing: 8) {
                TextField("新别名（英文）", text: $newAlias)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addAlias() }
                Button("添加", action: addAlias)
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 340, height: 360)
    }

    private func addAlias() {
        let a = newAlias.lowercased().trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty,
              a != column.keyword,
              !column.aliases.contains(a) else { return }
        column.aliases.append(a)
        settings.save()
        newAlias = ""
    }
}

// MARK: - Hex color helper

private func hexColor(_ hex: String) -> Color {
    let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: h).scanHexInt64(&int)
    return Color(
        red:   Double((int >> 16) & 0xFF) / 255,
        green: Double((int >> 8)  & 0xFF) / 255,
        blue:  Double(int         & 0xFF) / 255
    )
}
