import SwiftUI
import SwiftData

@main
struct ClaudeNotesApp: App {
    @StateObject private var recentFiles = RecentFilesStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Note.self, NoteFolder.self, AIAnalysis.self, NoteVersion.self])
        .commands {
            FileCommands(recentFiles: recentFiles)
            EditFormatCommands()
            ViewCommands()
            HelpCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Recent Files Store (ObservableObject for use in Commands)

final class RecentFilesStore: ObservableObject {
    static let shared = RecentFilesStore()

    @Published private(set) var urls: [URL] = []

    private init() { load() }

    func add(_ url: URL) {
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        if urls.count > 10 { urls = Array(urls.prefix(10)) }
        save()
    }

    func clear() { urls = []; save() }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: "recentFileURLs")
    }

    private func load() {
        urls = (UserDefaults.standard.stringArray(forKey: "recentFileURLs") ?? [])
            .compactMap { path -> URL? in
                let url = URL(fileURLWithPath: path)
                return FileManager.default.fileExists(atPath: path) ? url : nil
            }
    }
}

// MARK: - File Menu Commands

struct FileCommands: Commands {
    @ObservedObject var recentFiles: RecentFilesStore

    var body: some Commands {
        // Replace the default "New" group with our iA Writer-style items
        CommandGroup(replacing: .newItem) {
            Button("在 Library 中新建") {
                post(.menuNewInLibrary)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("新建笔记") {
                post(.menuNewNote)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("新建文件...") {
                post(.menuNewFile)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("新建笔记文件夹...") {
                post(.menuNewNoteFolder)
            }

            Divider()

            Button("打开...") {
                post(.menuOpenFile)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("添加 Library 文件夹...") {
                post(.menuAddLibrary)
            }

            Menu("最近打开") {
                if recentFiles.urls.isEmpty {
                    Text("暂无最近文件")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentFiles.urls, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            NotificationCenter.default.post(
                                name: .menuOpenRecentFile, object: url)
                        }
                    }
                    Divider()
                    Button("清除最近记录") { recentFiles.clear() }
                }
            }

            Divider()

            Button("在访达中显示") {
                post(.menuRevealInFinder)
            }

            Divider()

            Button("全部关闭") {
                post(.menuCloseAll)
            }
            .keyboardShortcut("w", modifiers: [.command, .option])

            Divider()

            // AI 功能菜单
            Menu("AI 功能") {
                // 个人画像
                Button("生成个人画像") {
                    post(.menuGeneratePersona)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("更新个人画像") {
                    post(.menuUpdatePersona)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Divider()

                // 每日简报
                Button("订阅设置") {
                    post(.menuInboxTopics)
                }

                Button("生成简报") {
                    post(.menuGenerateInbox)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        // Save commands
        CommandGroup(replacing: .saveItem) {
            Button("保存到文件") {
                post(.menuSaveFile)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("另存为...") {
                post(.menuSaveFileAs)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

// MARK: - Help Menu Commands

struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()

            Button("快捷键参考") {
                NotificationCenter.default.post(name: .menuShowShortcutsHelp, object: nil)
            }
            .keyboardShortcut("?", modifiers: [.command, .option])
        }
    }
}

// MARK: - Edit Menu Format Commands

struct EditFormatCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Menu("标题") {
                Button("H1 标题") { postFormat(.heading1) }
                Button("H2 标题") { postFormat(.heading2) }
                Button("H3 标题") { postFormat(.heading3) }
                Button("H4 标题") { postFormat(.heading4) }
                Button("H5 标题") { postFormat(.heading5) }
                Button("H6 标题") { postFormat(.heading6) }
            }

            Divider()

            Button("加粗")       { postFormat(.bold) }
            Button("斜体")       { postFormat(.italic) }
            Button("删除线")     { postFormat(.strikethrough) }
            Button("行内代码")   { postFormat(.inlineCode) }
            Button("代码块")     { postFormat(.codeBlock) }

            Divider()

            Button("链接")       { postFormat(.link) }
            Button("图片")       { postFormat(.image) }

            Divider()

            Button("无序列表")   { postFormat(.unorderedList) }
            Button("有序列表")   { postFormat(.orderedList) }
            Button("任务列表")   { postFormat(.taskList) }
            Button("引用")       { postFormat(.blockquote) }
            Button("分割线")     { postFormat(.horizontalRule) }

            Divider()

            Button("缩进")       { postFormat(.indent) }
            Button("取消缩进")   { postFormat(.outdent) }

            Divider()

            Button("盘古之白")   { postFormat(.panguSpacing) }
        }
    }

    private func postFormat(_ action: ShortcutAction) {
        NotificationCenter.default.post(name: .menuFormatAction, object: action.rawValue)
    }
}

// MARK: - View Menu Commands

struct ViewCommands: Commands {
    /// Mirrors the UserDefaults keys written by EditorSettings so @AppStorage reacts to
    /// changes made via EditorSettings.shared and vice-versa.
    @AppStorage("typewriterFocusMode")    var focusModeRaw:      String = "off"
    @AppStorage("typewriterScrollPosition") var scrollPositionRaw: String = "middle"

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            // ── Standalone 突出显示 (works independently of typewriter mode) ──
            Menu("突出显示") {
                ForEach(EditorSettings.TypewriterFocusMode.allCases, id: \.self) { mode in
                    Toggle(mode.displayName, isOn: Binding(
                        get: { focusModeRaw == mode.rawValue },
                        set: { if $0 { EditorSettings.shared.typewriterFocusMode = mode } }
                    ))
                }
            }

            // ── 打字机模式 ──
            Menu("打字机模式") {
                Button("停用") {
                    EditorSettings.shared.isTypewriterMode = false
                }
                .keyboardShortcut("t", modifiers: [.option, .command])

                Divider()

                Menu("固定滚动") {
                    ForEach(EditorSettings.TypewriterScrollPosition.allCases, id: \.self) { pos in
                        Toggle(pos.displayName, isOn: Binding(
                            get: { scrollPositionRaw == pos.rawValue },
                            set: { if $0 {
                                EditorSettings.shared.typewriterScrollPosition = pos
                                if pos != .off { EditorSettings.shared.isTypewriterMode = true }
                            }}
                        ))
                    }
                }

                Button("标记当前行") {
                    EditorSettings.shared.typewriterMarkLine.toggle()
                    EditorSettings.shared.isTypewriterMode = true
                }
            }
        }
    }
}

// MARK: - Menu Notification Names

extension Notification.Name {
    static let menuNewInLibrary   = Notification.Name("menuNewInLibrary")
    static let menuNewNote        = Notification.Name("menuNewNote")
    static let menuNewFile        = Notification.Name("menuNewFile")
    static let menuNewNoteFolder  = Notification.Name("menuNewNoteFolder")
    static let menuOpenFile       = Notification.Name("menuOpenFile")
    static let menuAddLibrary     = Notification.Name("menuAddLibrary")
    static let menuOpenRecentFile = Notification.Name("menuOpenRecentFile")
    static let menuCloseAll       = Notification.Name("menuCloseAll")
    static let menuSaveFile       = Notification.Name("menuSaveFile")
    static let menuSaveFileAs     = Notification.Name("menuSaveFileAs")
    static let menuFormatAction   = Notification.Name("menuFormatAction")
    static let menuRevealInFinder = Notification.Name("menuRevealInFinder")
    static let menuGeneratePersona = Notification.Name("menuGeneratePersona")
    static let menuUpdatePersona     = Notification.Name("menuUpdatePersona")
    static let menuInboxTopics       = Notification.Name("menuInboxTopics")
    static let menuGenerateInbox     = Notification.Name("menuGenerateInbox")
    static let menuShowShortcutsHelp = Notification.Name("menuShowShortcutsHelp")
}
