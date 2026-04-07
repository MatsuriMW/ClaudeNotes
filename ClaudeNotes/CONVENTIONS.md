# 代码规范（CONVENTIONS.md）

> 与 `CLAUDE.md` 配套使用，AI 按需查阅。

---

## 1. 命名规范

| 类别 | 规范 | 示例 |
|------|------|------|
| 变量 / 函数参数 | camelCase | `noteContent`, `filePath` |
| 函数名 | camelCase，动词优先 | `loadNote()`, `onContentChanged()` |
| 类型名 / 协议名 | PascalCase | `NoteEditorViewModel`, `LLMProvider` |
| 常量 | camelCase，必要时全大写下划线分隔 | `singlePassCharBudget` |
| 文件名 | PascalCase（与主类型同名） | `NoteEditorViewModel.swift` |
| SwiftData `@Model` 类 | PascalCase，无后缀 | `Note`, `AIAnalysis` |
| `@Observable` 类 | PascalCase，后缀 `Store` 或 `ViewModel` | `PersonaStore`, `NoteEditorViewModel` |
| `actor` 类型 | PascalCase | `AIService` |

---

## 2. 注释规范

### 2.1 文件级注释（每个 .swift 文件）

文件顶部的 `// MARK: -` 分隔符 + 功能分组：

```swift
// MARK: - File Commands

struct FileCommands: Commands { ... }

// MARK: - Helpers

private func formatDate(_ date: Date) -> String { ... }
```

### 2.2 复杂逻辑注释

在非显而易见的逻辑上方添加 `//` 注释，说明 **why** 而非 **what**：

```swift
// Debounce: rapid events (e.g. atomic save) coalesce into one refresh
refreshWorkItems[path]?.cancel()
```

### 2.3 禁止的注释风格

- 不要写废话注释：`// increment i` → `// i += 1`（什么都没说）
- 不要注释掉代码后提交（用 git 历史）
- 不要在注释里写中文以外的语言（除非是外部 API 文档引用）

---

## 3. 访问控制

| 场景 | 修饰符 |
|------|--------|
| 对外暴露的 API | `public` 或默认（internal） |
| 仅本模块使用 | `private` |
| 仅测试使用 | `internal`（默认） |
| 子类覆盖 | `override`（无需额外标记） |

**规则**：优先用 `private`，暴露最少接口。

---

## 4. 异步与并发

### 4.1 actor 使用

- `AIService` 等共享服务用 `actor` 单例，避免锁
- 不要在 `@Observable` 类中直接 `try? await`，用 `Task {}` 包装

```swift
// ✅ 正确
Task {
    let result = try await AIService.shared.analyzePersona(notes: notes)
    await MainActor.run { self.save(result) }
}

// ❌ 错误：阻塞主 actor
func analyze() async {
    let result = try await AIService.shared.analyzePersona(notes: notes)
    self.save(result) // 不要 await MainActor
}
```

### 4.2 Task 管理

- 长时间运行的任务（如 AI 分析）用 `@State private var task: Task<Void, Never>?` 保存引用
- 在 `.onDisappear` 或 `deinit` 中 cancel：

```swift
deinit {
    task?.cancel()
}
```

### 4.3 `@MainActor`

- ViewModel 更新 UI 状态时用 `@MainActor`
- 回调中切换到主线程：

```swift
} onProgress: { msg in
    Task { @MainActor in self.analysisProgress = msg }
}
```

---

## 5. SwiftUI 规范

### 5.1 View 规范

- View 文件名：`PascalCase`，与主 struct 同名
- View 尽量用 `some View` 返回类型
- 复杂视图拆分为多个 `private var computed view` 子视图（以 `.` 开头以示私有）：

```swift
var body: some View {
    VStack {
        toolbarContent
        editorArea
    }
}

private var toolbarContent: some View { ... }
```

### 5.2 `@State` / `@Binding` 使用

| 数据来源 | 修饰符 |
|----------|--------|
| 子 View 私有状态 | `@State` |
| 父子双向同步 | `@Binding` |
| 环境注入 | `@Environment` |
| SwiftData | `@Query` + `@Environment(\.modelContext)` |
| 外部单例（不可变） | `@State private var store = Store.shared` |

### 5.3 `@Observable`（替代 `@StateObject` / `@ObservedObject`）

- 用于 ViewModel：`final class FooViewModel: @Observable`
- 用于共享状态：`final class FooStore: @Observable`
- 使用 `@Bindable` 让 View 能绑定 `@Observable` 属性的 `@Binding`：

```swift
struct MyView: View {
    @Bindable var viewModel: MyViewModel
}
```

---

## 6. SwiftData 规范

### 6.1 `@Model` 类

- 继承自 `NSObject` 的类用 `@Model` 宏
- 不要在 `@Model` 中直接使用 `async` 方法
- 关系用 `@Relationship`：

```swift
@Relationship(deleteRule: .nullify, inverse: \NoteFolder.notes)
var folder: NoteFolder?

@Relationship(deleteRule: .cascade)
var aiAnalysis: AIAnalysis?
```

### 6.2 数据迁移

- 新增可选属性：安全（SwiftData 自动处理）
- 删除属性：创建 migration plan
- 修改属性类型：创建 migration plan

---

## 7. 文件组织顺序

每个 `.swift` 文件内，成员按以下顺序排列：

1. `import` 语句
2. `// MARK: -` 分组
3. 类型声明（`struct` / `class` / `enum`）
4. 嵌套类型（`enum`、`struct`）
5. 静态常量 / 静态方法
6. 实例属性
7. 初始化器 `init`
8. 实例方法（`public` / `private` / `fileprivate`）
9. `deinit`（如有）
10. `override` 方法
11. 私有辅助方法

---

## 8. 错误处理

- 使用 `enum FooError: Error, LocalizedError` 定义业务错误
- 错误信息返回中文（面向用户）：

```swift
enum AIError: Error, LocalizedError {
    case noAPIKey
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "请先在设置中配置该服务的 API Key"
        case .requestFailed(let msg):
            return "请求失败: \(msg)"
        }
    }
}
```

- 不要用 `try!` 除非极度确定不会失败
- 不要吞掉错误：用 `try?` + 日志记录，或显式 `throw`

---

## 9. 常量定义

| 类型 | 定义方式 |
|------|----------|
| 应用级配置 | `static let` 在类型内（`AIService.singlePassCharBudget`） |
| UserDefaults | `UserDefaults.standard` 配合 `@AppStorage` |
| 密钥 | KeychainService（禁止硬编码） |
| Magic numbers | 命名常量（`chunkSize = 60`） |

---

## 10. 禁止事项

1. **禁止裸 `force unwrap`**：用 `guard` / `if let` / `??` 替代 `!`
2. **禁止 `AnyObject`**：使用协议或泛型
3. **禁止在 View body 中执行副作用**：body 应该是纯函数
4. **禁止在 `init` 中启动 `Task`**：用 `.task` modifier 或 `@State` lazy 初始化
5. **禁止 `var someProperty: SomeType!`**（隐式解包）：除非有充分理由并加注释
