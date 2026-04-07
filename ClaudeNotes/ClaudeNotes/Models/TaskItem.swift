import Foundation
import SwiftUI

// MARK: - TaskItem

struct TaskItem: Identifiable, Equatable {
    /// Stable ID: note UUID + line index within the note
    var id: String { "\(note.id.uuidString)|\(originalLineIndex)" }

    let note: Note
    var status: String          // column keyword (lowercase)
    var text: String            // task description
    let originalLine: String    // original markdown line (for rebuilding)
    let originalLineIndex: Int  // line number in note.content (for sync-back)
    let matchedKeyword: String  // exact keyword that triggered the match (for sync-back)
    let keywordLeadsContent: Bool // keyword is at the start of content (after any list prefix)

    // UI-only properties (not persisted to files)
    var displayOrder: Int = 0      // for manual ordering within columns
    var isPinned: Bool = false     // pinned tasks always appear first
    var isSelected: Bool = false   // for multi-selection
    var priority: TaskPriority = .none  // priority level

    // For external files, store the file URL separately
    var fileURL: URL? = nil

    // True when this task was extracted from a non-list paragraph via an inline #tag.
    // Controls sync-back behaviour: inline tags are preserved and checkbox is appended.
    var isInlineTag: Bool = false

    var noteTitle: String { note.title.isEmpty ? "无标题" : note.title }

    static func == (lhs: TaskItem, rhs: TaskItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.status == rhs.status &&
        lhs.text == rhs.text &&
        lhs.displayOrder == rhs.displayOrder &&
        lhs.isPinned == rhs.isPinned &&
        lhs.isSelected == rhs.isSelected &&
        lhs.priority == rhs.priority
    }
}

// MARK: - Task Priority

enum TaskPriority: String, CaseIterable, Codable {
    case none = "none"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case urgent = "urgent"

    var displayName: String {
        switch self {
        case .none: return "无"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .urgent: return "紧急"
        }
    }

    var colorHex: String {
        switch self {
        case .none: return "#6B7280"      // gray
        case .low: return "#10B981"       // green
        case .medium: return "#F59E0B"    // orange
        case .high: return "#F97316"      // dark orange
        case .urgent: return "#EF4444"    // red
        }
    }

    var backgroundColor: Color {
        let hex = colorHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = int >> 16
        let g = (int >> 8) & 0xFF
        let b = int & 0xFF
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255).opacity(0.2)
    }
}

// Helper to create Color from hex string
func colorFromHex(_ hex: String) -> Color {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let r = int >> 16
    let g = (int >> 8) & 0xFF
    let b = int & 0xFF
    return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
}

// MARK: - TaskSettings

@Observable
final class TaskSettings {
    static let shared = TaskSettings()

    var columns: [TaskColumn]

    // MARK: - Kanban Data Source Settings

    struct KanbanDataSource: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var folderPath: String = ""           // Path to the folder
        var filePattern: String = "*.md"      // Glob pattern for file filtering
        var maxFiles: Int = 0                 // 0 = unlimited
        var sortOrder: SortOrder = .byName
        var dateRange: DateRange = .all
        var daysAround: Int = 7               // For dateRange == .aroundToday, days before/after

        enum SortOrder: String, Codable, CaseIterable {
            case byName = "name"
            case byDateModified = "dateModified"
            case byDateCreated = "dateCreated"

            var displayName: String {
                switch self {
                case .byName: return "按名称"
                case .byDateModified: return "按修改日期"
                case .byDateCreated: return "按创建日期"
                }
            }
        }

        enum DateRange: String, Codable, CaseIterable {
            case all = "all"
            case today = "today"
            case thisWeek = "thisWeek"
            case thisMonth = "thisMonth"
            case aroundToday = "aroundToday"

            var displayName: String {
                switch self {
                case .all: return "全部"
                case .today: return "今天"
                case .thisWeek: return "本周"
                case .thisMonth: return "本月"
                case .aroundToday: return "今天前后"
                }
            }
        }

        /// Check if the file matches this data source's criteria
        func matchesFile(url: URL, date: Date) -> Bool {
            // Check glob pattern
            let filename = url.lastPathComponent
            let pattern = filePattern.isEmpty ? "*.md" : filePattern
            if !matchesGlob(filename: filename, pattern: pattern) {
                return false
            }

            // Check date range
            let calendar = Calendar.current
            let now = Date()

            switch dateRange {
            case .all:
                return true
            case .today:
                return calendar.isDateInToday(date)
            case .thisWeek:
                return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .thisMonth:
                return calendar.isDate(date, equalTo: now, toGranularity: .month)
            case .aroundToday:
                let startDate = calendar.date(byAdding: .day, value: -daysAround, to: calendar.startOfDay(for: now))!
                let endDate = calendar.date(byAdding: .day, value: daysAround, to: calendar.startOfDay(for: now))!
                return date >= startDate && date <= endDate
            }
        }

        /// Simple glob pattern matching
        private func matchesGlob(filename: String, pattern: String) -> Bool {
            if pattern == "*" || pattern == "*.*" { return true }
            if pattern.hasSuffix("*") {
                let prefix = String(pattern.dropLast())
                return filename.hasPrefix(prefix)
            }
            return filename == pattern
        }
    }

    var kanbanDataSources: [KanbanDataSource] = []

    struct TaskColumn: Identifiable, Codable, Equatable, Hashable {
        var id: String { keyword }
        var keyword: String      // primary keyword (lowercase)
        var displayName: String
        var colorHex: String
        var aliases: [String]    // additional keywords that map to this column

        var allKeywords: [String] {
            ([keyword] + aliases).map { $0.lowercased() }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyword)
            hasher.combine(displayName)
            hasher.combine(colorHex)
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "taskColumns"),
           let cols = try? JSONDecoder().decode([TaskColumn].self, from: data) {
            columns = cols
        } else {
            columns = Self.defaults
        }

        // Load kanban data sources
        if let data = UserDefaults.standard.data(forKey: "kanbanDataSources"),
           let sources = try? JSONDecoder().decode([KanbanDataSource].self, from: data) {
            kanbanDataSources = sources
        } else {
            // Default: use all database notes
            kanbanDataSources = []
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(columns) else { return }
        UserDefaults.standard.set(data, forKey: "taskColumns")

        // Save kanban data sources
        if let sourcesData = try? JSONEncoder().encode(kanbanDataSources) {
            UserDefaults.standard.set(sourcesData, forKey: "kanbanDataSources")
        }
    }

    func addColumn(_ col: TaskColumn) {
        columns.append(col)
        save()
    }

    func removeColumn(at offsets: IndexSet) {
        columns.remove(atOffsets: offsets)
        save()
    }

    func moveColumn(from source: IndexSet, to destination: Int) {
        columns.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Kanban Data Source Management

    func addKanbanDataSource(_ source: KanbanDataSource) {
        kanbanDataSources.append(source)
        save()
    }

    func removeKanbanDataSource(at offsets: IndexSet) {
        kanbanDataSources.remove(atOffsets: offsets)
        save()
    }

    func moveKanbanDataSource(from source: IndexSet, to destination: Int) {
        kanbanDataSources.move(fromOffsets: source, toOffset: destination)
        save()
    }

    static let defaults: [TaskColumn] = [
        .init(keyword: "todo",      displayName: "待办",   colorHex: "#6B7280", aliases: ["task"]),
        .init(keyword: "doing",     displayName: "进行中", colorHex: "#3B82F6", aliases: ["wip"]),
        .init(keyword: "waiting",   displayName: "等待中", colorHex: "#F59E0B", aliases: ["blocked"]),
        .init(keyword: "toread",    displayName: "待读",   colorHex: "#8B5CF6", aliases: ["2read", "to-read", "reading"]),
        .init(keyword: "done",      displayName: "已完成", colorHex: "#10B981", aliases: ["completed"]),
        .init(keyword: "cancelled", displayName: "已取消", colorHex: "#9CA3AF", aliases: ["canceled"]),
        .init(keyword: "failed",    displayName: "失败",   colorHex: "#EF4444", aliases: []),
    ]
}
