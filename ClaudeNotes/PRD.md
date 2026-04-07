# ClaudeNotes PRD — 产品需求文档

> **文档状态：** 初稿 v0.1
> **编写日期：** 2026-04-03
> **最后更新：** —
> **维护者：** ClaudeNotes Team
> **目标读者：** 产品经理、设计/研发团队

---

## 1. 产品概述

### 1.1 产品名称与类型

**ClaudeNotes** 是一款 macOS 平台原生笔记应用，基于 **SwiftUI + SwiftData** 构建，深度集成 AI 辅助能力。

### 1.2 一句话定位

> 一款面向知识工作者和创作者的双链笔记工具，提供 Markdown 编辑、AI 驱动的个人画像分析和智能简报生成能力。

### 1.3 核心价值主张

| 维度 | 描述 |
|------|------|
| **编辑体验** | 类 iA Writer 的沉浸式 Markdown 写作，支持代码折叠、打字机模式 |
| **AI 集成** | 本地 Claude CLI 或多模型 API（Claude / ChatGPT / Gemini / ）深度集成 |
| **个人画像** | 基于笔记库分析用户 MBTI、性格特质、兴趣领域和写作风格 |
| **每日简报** | AI 从笔记中自动提炼今日待办、灵感与摘要 |
| **外部库** | 支持 Library 文件夹管理本地 Markdown 文件，双编辑器对比 |

---

## 2. 技术架构

### 2.1 技术栈

| 层次 | 技术选型 |
|------|---------|
| UI 框架 | SwiftUI + AppKit（NSTextView 文本编辑层） |
| 数据持久化 | SwiftData |
| AI 服务 | `AIService` actor，支持 Claude CLI（本地）、Claude API、OpenAI API、Gemini API、|
| 密钥管理 | KeychainService |
| 平台最低版本 | macOS 14.0+ |

### 2.2 项目结构

```
ClaudeNotes/
├── App/
│   └── ClaudeNotesApp.swift          # @main 入口，WindowGroup 配置，菜单命令
├── Models/
│   ├── Note.swift                    # SwiftData @Model，笔记主体
│   ├── NoteFolder.swift              # 笔记文件夹
│   ├── NoteVersion.swift             # 版本历史
│   ├── AIAnalysis.swift              # AI 分析结果
│   ├── UserPersona.swift             # 个人画像（MBTI、性格、兴趣）
│   ├── TaskItem.swift                # 看板任务
│   ├── InboxModels.swift             # 每日简报数据模型
│   ├── LLMProvider.swift             # AI Provider 配置
│   ├── AIProviderSettings.swift      # Provider 设置
│   ├── EditorSettings.swift          # 编辑器偏好设置
│   ├── ShortcutSettings.swift        # 快捷键自定义
│   ├── PlatformRewrite.swift        # 平台风格重写
│   ├── ExternalSearch.swift          # 外部搜索
│   └── LibraryModels.swift           # Library 文件管理模型
├── ViewModels/
│   ├── NoteEditorViewModel.swift     # 笔记编辑 VM（@Observable）
│   └── AIInsightsViewModel.swift     # AI 洞察 VM
├── Views/
│   ├── ContentView.swift             # 主布局：侧边栏 + 标签页 + 编辑器
│   ├── Sidebar/
│   │   └── SidebarView.swift         # 侧边栏：AI 工具 / 笔记列表 / Library
│   ├── Editor/
│   │   ├── NoteEditorView.swift      # 笔记编辑器 SwiftUI 包装层
│   │   ├── MarkdownTextView.swift    # NSTextView 子类（NSViewRepresentable）
│   │   ├── MarkdownPreviewView.swift # Markdown 预览视图
│   │   ├── EditorToolbar.swift       # 编辑器工具栏
│   │   ├── OutlinePanelView.swift    # 大纲面板
│   │   ├── VersionHistoryView.swift  # 版本历史
│   │   ├── MetadataGeneratorView.swift # 元数据生成
│   │   └── RewriteResultPanel.swift  # AI 重写结果面板
│   ├── AI/
│   │   ├── AIInsightsPanel.swift     # AI 洞察面板
│   │   └── AILoadingView.swift       # AI 加载状态
│   ├── Chat/
│   │   ├── AIChatPanel.swift         # AI 对话面板
│   │   ├── LLMWebView.swift          # Web 模式 LLM（内嵌浏览器）
│   │   ├── ChatBrowserView.swift     # 聊天浏览器视图
│   │   ├── ChatProviderListView.swift # Provider 列表
│   │   ├── ClaudeTerminalView.swift  # Claude Code 终端
│   │   └── SlashCommandPopup.swift   # Slash 命令弹窗
│   ├── NoteList/
│   │   ├── NoteListView.swift        # 笔记列表视图
│   │   └── NoteRow.swift             # 笔记行组件
│   ├── Search/
│   │   └── VaultSearchView.swift     # 全局笔记搜索
│   ├── Settings/
│   │   ├── SettingsView.swift        # 设置总览
│   │   ├── EditorSettingsView.swift  # 编辑器设置
│   │   ├── PlatformRewriteSettingsView.swift # 平台重写设置
│   │   ├── ExternalSearchSettingsView.swift   # 外部搜索设置
│   │   └── ShortcutSettingsView.swift # 快捷键设置
│   ├── Kanban/
│   │   └── KanbanBoardView.swift     # 看板视图
│   ├── Inbox/
│   │   └── InboxView.swift           # 每日简报视图
│   ├── FileLibrary/
│   │   └── FileNoteEditorView.swift  # 外部文件编辑器
│   └── ShortcutsHelpView.swift       # 快捷键帮助视图
├── Services/
│   ├── AIService.swift               # AI 服务 actor（核心 AI 逻辑）
│   ├── AIPrompts.swift               # AI Prompt 模板
│   ├── KeychainService.swift         # 密钥链访问
│   ├── MarkdownFormatter.swift       # Markdown 格式化
│   ├── MarkdownRenderer.swift        # Markdown 渲染
│   ├── MetadataService.swift         # 元数据服务
│   ├── PanguSpacing.swift            # 盘古之白（中文 spacing）
│   ├── InboxService.swift            # 简报生成服务
│   ├── TaskExtractionService.swift   # 任务提取服务
│   ├── WebChatInjector.swift         # Web 聊天注入脚本
│   └── TerminalSession.swift         # 终端会话管理
└── Extensions/
    └── Date+Formatting.swift         # 日期格式化扩展
```

---

## 3. 功能规格

### 3.1 侧边栏导航

侧边栏分为三个区域：

#### 区域 A — AI 工具（固定）
| 项目 | 图标 | 说明 |
|------|------|------|
| 个人画像 | `person.crop.circle` | MBTI 分析、性格特质、兴趣领域 |
| 每日简报 | `newspaper` | 今日待办与灵感摘要 |
| 任务看板 | `rectangle.3.group` | 看板式任务管理 |

状态指示：
- 分析中：内联 `ProgressView`
- 已完成：绿色 `checkmark.circle.fill`
- 已过时（>7 天）：橙色圆点提示

#### 区域 B — 笔记列表
- 固定入口：`全部笔记`
- 动态列表：`NoteFolder` 笔记文件夹（支持创建）
- 支持拖拽排序

#### 区域 C — 文件库（Library）
- 支持添加多个本地文件夹作为 Library
- 支持文件过滤（文件名搜索、最大数量限制）
- 支持排序模式：最近使用 / 名字 / 自定义顺序
- 支持拖拽调整自定义顺序
- 实时监听文件系统变化（`DispatchSource` / kqueue）
- 最近打开文件列表

---

### 3.2 标签页系统（多文档）

**`OpenTab` 模型：**

```swift
struct OpenTab: Identifiable {
    let id: UUID
    var isPinned: Bool = false
    var groupID: UUID? = nil
    enum Content {
        case note(Note)
        case file(URL, displayTitle: String)
    }
    var content: Content
}
```

**功能列表：**

| 功能 | 描述 |
|------|------|
| 多标签 | 支持同时打开多个笔记和外部文件 |
| 固定标签 | 固定标签以图标形式显示（节省空间） |
| 标签拖拽排序 | 水平拖拽，支持与相邻标签交换位置 |
| 标签组 | 将标签分组，组内标签底部显示彩色条 |
| 第二编辑器 | 任意标签可作为右侧副编辑器（双屏对比） |
| 键盘快捷切换 | `Cmd+1`–`Cmd+8` 跳转指定位置，`Cmd+9` 最后标签 |
| 上下文菜单 | 右键菜单：关闭、固定、新建、标签组管理 |

---

### 3.3 Markdown 编辑器

#### 3.3.1 核心架构

- **编辑层**：`MarkdownEditorNSTextView`（`NSTextView` 子类）
- **SwiftUI 包装**：`MarkdownTextView`（`NSViewRepresentable`）
- **数据绑定**：`NoteEditorViewModel`（`@Observable`）
  - `content: String` — 始终为"真实内容"（折叠后展开状态）
  - `trueContent()` 方法：将折叠占位符还原为原始文本
  - 自动保存（500ms 防抖）

#### 3.3.2 编辑特性

| 特性 | 描述 |
|------|------|
| 实时字数统计 | `wordCount` 属性（按空白字符分割计数） |
| 内容预览 | 去除 Markdown 符号后的前 120 字符摘要 |
| Markdown 预览 | 切换到 `MarkdownPreviewView` 渲染视图 |
| 文件打开/保存 | `NSOpenPanel` / `NSSavePanel`，支持 `.md` / `.markdown` |
| 自动保存 | 内容变化 500ms 后自动持久化到 SwiftData |

#### 3.3.3 代码折叠（Fold）

- 折叠记录存储在 `foldRecords: [FoldRecord]`
- `FoldRecord` 包含 `placeholderRange` 和原始内容
- `trueContent()` 遍历所有折叠记录，还原真实文本
- 折叠状态不影响 `NoteEditorViewModel.content` 的准确性

#### 3.3.4 打字机模式

| 配置项 | 选项 |
|--------|------|
| 突出显示模式 | 关闭 / 聚焦行 / 聚焦段落 |
| 固定滚动位置 | 关闭 / 顶部 / 中间 / 底部 |
| 标记当前行 | 高亮背景色 |

#### 3.3.5 大纲模式

- `outlineMode: Bool` — 回车键始终生成列表项

#### 3.3.6 搜索跳转

- `jumpToFirstMatch(query:)` — 滚动到第一个匹配结果并高亮
- `scrollToLine(lineIndex:)` — 滚动到指定行

#### 3.3.7 格式化操作（快捷键）

支持通过菜单或快捷键触发的格式化操作：

| 操作 | 快捷键 | 对应 Markdown |
|------|--------|--------------|
| 标题 H1–H6 | — | `#` – `######` |
| 加粗 | `Cmd+B` | `**text**` |
| 斜体 | `Cmd+I` | `*text*` |
| 删除线 | — | `~~text~~` |
| 行内代码 | `Cmd+E` | `` `code` `` |
| 代码块 | — | ```` ``` ```` |
| 链接 | `Cmd+K` | `[text](url)` |
| 图片 | — | `![alt](url)` |
| 无序列表 | — | `- item` |
| 有序列表 | — | `1. item` |
| 任务列表 | — | `- [ ] task` |
| 引用 | — | `> quote` |
| 分割线 | — | `---` |
| 缩进 / 取消缩进 | `Tab` / `Shift+Tab` | 增加 / 减少列表缩进 |
| 盘古之白 | — | 中文标点与英文/数字间插入空格（PanguSpacing） |

---

### 3.4 AI 集成

#### 3.4.1 多模型支持

| Provider | API 支持 | Web 模式 |
|----------|----------|----------|
| Claude（本地 CLI） | ✅（本地 subprocess） | ✅ |
| Claude（API） | ✅ | ✅ |
| ChatGPT | ✅ | ✅ |
| Gemini | ✅ | ✅ |
| | ✅ | ❌ |

#### 3.4.2 AIService Actor

- 单例 `AIService.shared`，以 `actor` 保证线程安全
- **API 模式**：通过 HTTP 请求调用各 Provider API
- **CLI 模式**：调用本地 `claude` CLI subprocess
- **Prompt 注入**：从 `PersonaStore.shared.systemPromptContext` 注入用户画像上下文

#### 3.4.3 AI 功能矩阵

| 功能 | 触发方式 | Provider |
|------|----------|----------|
| 笔记分析（摘要/主题/洞察） | `AIInsightsPanel` | Claude CLI/API |
| 续写（ClaudeWrite） | 编辑器内触发 | Claude CLI/API |
| 智能重写（PlatformRewrite） | 选中文本重写 | Claude API |
| AI 对话面板 | `AIChatPanel` | 多 Provider |
| 外部搜索 | `ExternalSearch` | 多 Provider |
| 个人画像分析 | `PersonaStore` | Claude CLI/API |
| 每日简报 | `InboxStore` | Claude CLI/API |
| Slash 命令 | 编辑器内 `/` | Claude CLI |

#### 3.4.4 ClaudeTerminalView

- 集成 Claude Code 终端到编辑器侧边面板
- Session 按 NoteID / PersonaID / InboxID 隔离
- 支持发送笔记内容作为上下文

---

### 3.5 个人画像系统

#### 3.5.1 UserPersona 数据模型

```swift
struct UserPersona: Codable {
    struct MBTI: Codable {
        var type: String           // e.g. "INTP"
        var confidence: String      // 高 / 中 / 低
        var reasoning: String      // 推断理由
        var dimensions: MBTIDimensions  // iVsE, nVsS, tVsF, jVsP (0-100)
    }
    struct PersonalityTrait: Codable { name, description, evidence }
    struct InterestArea: Codable { name, intensity(1-5), summary }
    var writingStyle: String
    var recentFocus: String
    var summary: String            // 150-200 字整体画像
    var suggestions: [String]       // 3-5 条建议
    var generatedAt: Date
    var lastPatchedAt: Date?
    var noteCount: Int
    var totalWords: Int
    var providerID: String
    var analyzedNoteIDs: [UUID]     // 用于增量分析
}
```

#### 3.5.2 PersonaStore

- 持久化路径：`~/Library/Application Support/ClaudeNotes/user_persona.json`
- **全量分析**：一次性分析全部笔记
- **增量分析**（`patchPersona`）：仅分析新增/修改的笔记，保留稳定特质
- **过时判断**：超过 7 天 或 新增 ≥5 篇笔记 → 触发重新分析
- **背景运行**：分析在后台 `Task` 中执行，通过 `@Observable` 属性驱动 UI 进度

#### 3.5.3 分析算法

| 笔记数量 | 策略 |
|----------|------|
| ≤60 篇 | 单次全量分析 |
| >60 篇 | 分批（每批 60 篇）提取性格信号 → 综合生成画像 |

---

### 3.6 每日简报（Inbox）

#### 3.6.1 数据流

1. `InboxStore` 从今日修改的笔记中提取待办事项和灵感
2. `InboxService` 通过 AI 生成结构化简报
3. 支持按话题订阅（`InboxTopic`）
4. 自动生成开关（应用启动时检查是否需要）

#### 3.6.2 显示界面

- 独立 `InboxView` 展示今日摘要
- 支持手动重新生成（`Cmd+Shift+G`）

---

### 3.7 任务看板（Kanban）

- `KanbanBoardView`：看板视图
- `TaskItem`：看板任务模型
- 从笔记中提取任务（`TaskExtractionService`）
- 点击任务跳转到对应笔记行

---

### 3.8 版本历史

- `NoteVersion`：每次保存时记录快照
- `VersionHistoryView`：查看历史版本并还原

---

### 3.9 全局搜索（VaultSearch）

- `VaultSearchView`：搜索全部笔记和外部文件
- 支持跳转到匹配关键词并高亮

---

### 3.10 外部搜索

- `ExternalSearch`：AI 驱动的外部知识搜索
- 搜索结果可插入当前笔记

---

## 4. UI/UX 规格

### 4.1 整体布局

```
┌──────────────────────────────────────────────────────────────────────┐
│  Toolbar: [新建] [搜索] [AI面板] [标签管理菜单]                          │
├─────────────┬────────────────────────────────────────────────────────┤
│             │  TabBar: [笔记1] [笔记2] [笔记3] …                        │
│  Sidebar    ├────────────────────────────────────────────────────────┤
│             │                                                        │
│  ┌─ AI 工具 ─┐ │  MarkdownEditor / MarkdownPreview                    │
│  │个人画像   │ │                                                        │
│  │每日简报   │ │  ← 主编辑器 (Primary)     │ ← 副编辑器或重写结果 (Secondary) │
│  │任务看板   │ │                                                        │
│  └──────────┘ │                                                        │
│             │                                                        │
│  ┌─ 笔记 ────┐ │                                                        │
│  │全部笔记   │ │                                                        │
│  │文件夹    │ │                                                        │
│  └──────────┘ │                                                        │
│             │                                                        │
│  ┌─ 文件库 ──┐ │                                                        │
│  │Library1  │ │                                                        │
│  │Library2  │ │                                                        │
│  └──────────┘ │                                                        │
└─────────────┴────────────────────────────────────────────────────────┘
```

### 4.2 配色与主题

- 遵循 macOS 系统主题（亮/暗模式自适应）
- 优先使用 `Color(nsColor:)` 获取系统色
- AI 面板：`terminal` 图标切换状态（实心/空心）

### 4.3 窗口规格

```swift
.frame(minWidth: 800, minHeight: 500)
```

---

## 5. 数据模型关系图

```
┌──────────────────┐       ┌──────────────────┐
│    NoteFolder    │       │       Note       │
│──────────────────│  1:N  │──────────────────│
│ id: UUID         │←──────│ id: UUID         │
│ name: String     │       │ title: String    │
│ notes: [Note]    │       │ content: String  │
└──────────────────┘       │ folder: NoteFolder│
                          │ aiAnalysis: AIAnalysis│
                          │ isPinned: Bool   │
                          │ isDeleted: Bool  │
                          │ filePath: String?│
                          └──────────────────┘
                                  │ 1:1
                                  ▼
                          ┌──────────────────┐
                          │   AIAnalysis     │
                          │──────────────────│
                          │ summary: String? │
                          │ relatedTopics    │
                          │ insights: String?│
                          └──────────────────┘

┌──────────────────┐       ┌──────────────────┐
│  UserPersona     │       │   LLMProvider    │
│──────────────────│       │──────────────────│
│ mbti: MBTI       │       │ id: String       │
│ personalityTraits│       │ name: String     │
│ interests[]      │       │ supportsAPI: Bool│
│ writingStyle     │       │ apiBaseURL: URL? │
│ recentFocus      │       └──────────────────┘
│ suggestions[]    │
└──────────────────┘
```

---

## 6. 键盘快捷键汇总

### 6.1 全局快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+N` | 在 Library 中新建文件 |
| `Cmd+Shift+N` | 新建笔记 |
| `Cmd+Option+N` | 新建文件 |
| `Cmd+O` | 打开文件 |
| `Cmd+S` | 保存到文件 |
| `Cmd+Shift+S` | 另存为 |
| `Cmd+W` | 关闭当前标签 |
| `Cmd+Option+W` | 关闭所有标签 |
| `Cmd+Shift+G` | 生成每日简报 |
| `Cmd+Shift+P` | 生成个人画像 |
| `Cmd+Option+P` | 更新个人画像 |
| `Cmd+Shift+I` | 切换 AI 面板 |
| `Cmd+?` | 快捷键帮助 |
| `Cmd+1`–`Cmd+8` | 跳转标签 1–8 |
| `Cmd+9` | 跳转最后标签 |

### 6.2 编辑器快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+B` | 加粗 |
| `Cmd+I` | 斜体 |
| `Cmd+E` | 行内代码 |
| `Cmd+K` | 链接 |
| `Tab` | 缩进 |
| `Shift+Tab` | 取消缩进 |

---

## 7. 存储与持久化

### 7.1 SwiftData 模型

| 模型 | 存储位置 |
|------|----------|
| `Note` | SwiftData（`~/Library/Application Support/ClaudeNotes`） |
| `NoteFolder` | SwiftData |
| `AIAnalysis` | SwiftData（与 Note 一对一） |
| `NoteVersion` | SwiftData（与 Note 一对多） |

### 7.2 UserDefaults 存储

| Key | 类型 | 用途 |
|-----|------|------|
| `libraryFolderPaths` | `[String]` | Library 文件夹路径列表 |
| `openedFilePaths` | `[String]` | 最近打开的外部文件 |
| `libMaxFiles` | `Int` | Library 文件数量限制 |
| `libFilenameFilter` | `String` | Library 文件名过滤 |
| `libSortMode` | `String` | 排序模式 |
| `libSortAscending` | `Bool` | 升序/降序 |
| `libAccessDates` | `[String: Double]` | 文件访问时间戳 |
| `libCustomOrders` | `[String: [String]]` | 各 Library 的自定义顺序 |
| `typewriterFocusMode` | `String` | 突出显示模式 |
| `typewriterScrollPosition` | `String` | 打字机滚动位置 |

### 7.3 Keychain 存储

API 密钥按 Provider ID 存储于 macOS Keychain：

```
Service: "ClaudeNotes"
Account: <provider_id>  // e.g. "claude", "chatgpt", "gemini"
```

### 7.4 Persona 持久化

```
~/Library/Application Support/ClaudeNotes/user_persona.json
```

---

## 8. 待完成功能（Roadmap）

> 以下功能为当前代码中尚未完全实现或需要完善的模块：

| 功能 | 状态 | 说明 |
|------|------|------|
| 大纲面板（OutlinePanel） | 部分实现 | 从 Markdown 提取标题生成可导航大纲 |
| 智能重写（PlatformRewrite） | 需完善 | 选中文本按指定风格重写 |
| 外部搜索（ExternalSearch） | 需完善 | AI 驱动的外部知识检索 |
| 元数据生成（MetadataGenerator） | 部分实现 | AI 生成 YAML front-matter |
| 版本历史对比 | 部分实现 | `VersionHistoryView` 需完善对比功能 |
| 订阅设置（InboxTopics） | 部分实现 | 按话题订阅简报内容 |

---

## 9. 设计原则

1. **本地优先**：笔记数据默认存储在本地 SwiftData
2. **AI 透明**：所有 AI 功能均标注数据来源和处理方式
3. **性能优先**：大笔记库使用分批分析，避免单次 Token 超出限制
4. **可扩展**：Provider 模式支持新增 AI 服务商
5. **隐私友好**：个人画像本地生成，不上传云端

---

## 10. 参考资料

- [SwiftUI 文档](https://developer.apple.com/documentation/swiftui)
- [SwiftData 文档](https://developer.apple.com/documentation/swiftdata)
- [NSTextView 编程指南](https://developer.apple.com/documentation/appkit/nstextview)
- [Claude API 文档](https://docs.anthropic.com/api/reference)
