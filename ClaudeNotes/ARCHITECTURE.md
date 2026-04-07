# 架构文档（ARCHITECTURE.md）

> 与 `CLAUDE.md` 配套使用，AI 按需查阅。

---

## 1. 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                      SwiftUI Views                          │
│  (ContentView, SidebarView, NoteEditorView...)               │
└─────────────────────────────┬───────────────────────────────┘
                              │ @Bindable / @State
┌─────────────────────────────▼───────────────────────────────┐
│                   ViewModels (@Observable)                   │
│  (NoteEditorViewModel, AIInsightsViewModel, PersonaStore...)  │
└─────────────────────────────┬───────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  SwiftData      │  │  Services       │  │  AppKit         │
│  (Note,         │  │  (AIService,    │  │  (NSTextView    │
│   NoteFolder,   │  │   Keychain...)   │  │   editor)       │
│   AIAnalysis)   │  │                  │  │                 │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

---

## 2. 数据流

### 2.1 笔记编辑数据流

```
用户输入
  │
  ▼
MarkdownEditorNSTextView (NSTextView 子类)
  │
  │ textDidChange → onTextChange
  ▼
NoteEditorViewModel.content (真实内容，含折叠展开)
  │
  │ scheduleSave (500ms debounce)
  ▼
SwiftData Note.content 持久化
  │
  │ foldRecords 同步更新
  ▼
MarkdownTextView.foldRecords[] 保持一致
```

**关键不变量**：`NoteEditorViewModel.content == trueContent()`（折叠展开后的文本）

### 2.2 AI 服务数据流

```
用户触发 AI 操作
  │
  ▼
ViewModel / Store
  │
  │ async/await (在 Task 中)
  ▼
AIService actor
  │
  ├── 本地 CLI 模式 → /bin/zsh → claude CLI subprocess
  │
  └── API 模式 → URLSession → 各 Provider HTTP API
       │
       ├── Claude API (api.anthropic.com)
       ├── OpenAI API (api.openai.com / 自定义 baseURL)
       └── Gemini API (generativelanguage.googleapis.com)
  │
  ▼
JSON 解析 → 业务模型
  │
  ▼
MainActor.run → UI 状态更新
```

### 2.3 个人画像分析数据流

```
用户触发生成个人画像
  │
  ▼
PersonaStore.startAnalysis(notes:)
  │
  ├── 笔记 ≤60 篇 → 单次全量分析
  │
  └── 笔记 >60 篇 → 分批提取性格信号 → 综合生成
  │
  ▼
UserPersona → 持久化到 ~/Library/Application Support/ClaudeNotes/user_persona.json
  │
  ▼
systemPromptContext → 注入所有 AI 对话的 system prompt
```

---

## 3. 核心模块详解

### 3.1 MarkdownTextView（编辑核心）

**文件**：`Views/Editor/MarkdownTextView.swift`

**职责**：
- `MarkdownEditorNSTextView`：NSTextView 子类，处理所有击键、格式化操作
- `TextViewHolder`：桥接 NSTextView 与 SwiftUI 的访问器
- `MarkdownTextView`：SwiftUI `NSViewRepresentable` 包装

**关键设计**：
- 使用 `performKeyEquivalent` 拦截所有键盘事件，优先于菜单和系统快捷键处理
- `foldRecords[]` 存储折叠状态，与 `NoteEditorViewModel.content` 保持同步
- `isFolding` 标志：防止折叠操作触发文本变化回调的死循环

**⚠️ 编辑器 fold 同步协议**：
1. 用户折叠 → `foldRecords.append()` + 文本替换为占位符 → `isFolding=true` → 触发 `onTextChange`
2. ViewModel 的 `content` 更新为 `trueContent()`（含占位符）
3. `updateNSView` 检测到 `text != trueContent()` → 全量重置文本（光标跳到末尾）
4. 用户展开 → `foldRecords.remove()` + 占位符替换为原文 → 同上流程

### 3.2 NoteEditorViewModel

**文件**：`ViewModels/NoteEditorViewModel.swift`

**职责**：
- 管理单个笔记的编辑状态（title, content, filePath, hasUnsavedChanges）
- 500ms 防抖自动保存
- 文件 I/O（打开 .md / 保存到文件）

**设计决策**：
- `content: String` 始终是"真实内容"（折叠后仍展开），这意味着 `content` 中含占位符文本
- 折叠时的显示文本由 `MarkdownTextView` 独立维护，不影响 ViewModel
- `hasUnsavedChanges` 用于 UI 指示，不用于自动保存逻辑

### 3.3 AIService Actor

**文件**：`Services/AIService.swift`

**职责**：
- 统一的多 AI Provider 调度（Claude CLI / Claude API / ChatGPT / Gemini / ）
- Prompt 构建、响应解析、错误转换
- 大型笔记库的分批处理策略

**Provider 路由**：
```
Provider ID → supportsAPI?
  ├─ true  → HTTP API 调用
  └─ false → Web 模式（由 LLMWebView 处理）
```

### 3.4 PersonaStore

**文件**：`Models/UserPersona.swift`

**职责**：
- 持久化 `UserPersona` 到 JSON 文件
- 管理全量/增量分析任务的生命周期
- 提供 `systemPromptContext` 注入 AI 对话

**过时策略**：
- 时间维度：生成超过 7 天
- 内容维度：新增 ≥5 篇未分析笔记

### 3.5 LibraryManager

**文件**：`Models/LibraryModels.swift`

**职责**：
- 管理多个 Library 文件夹
- 监听文件系统变化（`DispatchSource` / kqueue）
- 文件过滤、排序、自定义顺序

**文件监听设计**：
- 使用 `DispatchSource.makeFileSystemObjectSource` 监听 `EVFILT_VNODE` 事件
- 0.4s 防抖避免原子保存触发多次刷新
- 每个 Library 独立监听，`stopWatching` 在移除时调用

---

## 4. 状态管理

### 4.1 状态层级

| 层级 | 技术 | 示例 |
|------|------|------|
| 全局单例 | `@Observable` + `static shared` | `PersonaStore.shared`, `LibraryManager.shared` |
| 视图状态 | `@State` / `@State private var` | `ContentView` 的 `openTabs`, `activeTabID` |
| 跨视图协调 | `@Binding` | `highlightQuery` 从 VaultSearch 传递到 NoteEditor |
| SwiftData | `@Query` + `@Environment` | 笔记列表、文件夹 |
| UserDefaults | `@AppStorage` | `typewriterFocusMode` 等偏好设置 |
| Keychain | `KeychainService` | API 密钥 |

### 4.2 标签页状态

`openTabs: [OpenTab]` 和 `activeTabID: UUID?` 由 `ContentView` 持有，通过 `@Binding` 传给 `TabBarView`。

---

## 5. Navigation 结构

```
NavigationSplitView
├── Sidebar（NavigationSplitView.sidebar）
│   ├── SidebarView（AI 工具 + 笔记列表 + Library）
│   └── SidebarItem selection → 驱动 detail
└── Detail（NavigationSplitView.detail）
    ├── PersonaView
    ├── InboxView
    ├── KanbanBoardView
    └── NotesWorkspace
        ├── TabBarView
        └── NoteEditorView / FileNoteEditorView
```

---

## 6. 外部依赖

| 库 | 版本 | 用途 |
|----|------|------|
| SwiftTerm | (bundled via Xcode) | 终端模拟组件 |

无第三方 SPM / CocoaPods 依赖。

---

## 7. 关键设计决策记录

### 7.1 为什么用 NSTextView 而不是纯 SwiftUI TextEditor？

- 需要细粒度控制光标位置、选中范围、击键拦截
- 需要实现代码折叠（fold/unfold）—— 这要求对文本替换的精确控制
- SwiftUI `TextEditor` 无法满足这些需求

### 7.2 为什么用 actor 而非 class？

- `AIService` 是共享单例，actor 提供编译期线程安全保证
- 避免锁竞争，所有状态访问序列化

### 7.3 为什么 Persona 存 JSON 文件而非 SwiftData？

- Persona 是分析结果，不是用户直接编辑的数据
- JSON 文件便于调试和跨版本兼容
- SwiftData 用于"活跃数据"，JSON 用于"派生数据"

### 7.4 为什么 fold 占位符要保留在 content 中？

- 保证 `Note.content` 是可序列化的完整文本
- 便于实现版本历史（直接存储 `Note.content`）
- 避免折叠状态丢失导致内容不一致
