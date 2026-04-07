# ClaudeNotes

> macOS 原生笔记应用，SwiftUI + SwiftData，深度集成 AI 辅助。

## 项目概述

ClaudeNotes 是一款面向知识工作者的双链笔记工具，核心功能包括：
Markdown 沉浸式编辑（基于 NSTextView）、多标签工作区、AI 个人画像分析、每日简报生成、外部 Library 文件管理和任务看板。

## 核心代码位置

```
ClaudeNotes/ClaudeNotes/
├── App/ClaudeNotesApp.swift          # @main 入口，菜单命令
├── Models/                          # SwiftData 模型（Note, NoteFolder, AIAnalysis, UserPersona...）
├── ViewModels/                      # @Observable VM（NoteEditorViewModel, AIInsightsViewModel）
├── Views/                           # SwiftUI 视图，按功能分子目录
│   ├── Editor/MarkdownTextView.swift # NSTextView 子类，最核心的编辑逻辑
│   └── Chat/AIService.swift         # AI 服务 actor（多 Provider 统一入口）
├── Services/                        # 纯业务逻辑服务（Keychain, Markdown, PanguSpacing...）
└── Extensions/                      # 扩展
```

## 技术规范

- **部署目标**：macOS 14.0+
- **Swift 版本**：5.0
- **框架**：SwiftUI + SwiftData + AppKit（NSTextView）
- **代码风格**：遵循 Apple 官方 API 设计指南，变量命名使用 **camelCase**，类型名使用 **PascalCase**。如有不确定的风格规范，**直接问用户**，不要猜测。

## 红线（绝对禁止）

1. **不要删除或绕过 fold 同步逻辑**：`MarkdownTextView` 中 `trueContent()` 与 `foldRecords` 的同步是 editor 的核心不变量。任何改动必须保持两者一致，否则会导致内容丢失或光标错位。
2. **不要修改 SwiftData 模型结构而不迁移数据**：`Note`、`NoteFolder`、`AIAnalysis`、`NoteVersion` 的 `@Model` 属性变更需要兼容旧数据。
3. **不要把 API 密钥硬编码或写入代码**：所有密钥必须通过 `KeychainService` 访问。
4. **不要在 `@Observable` 类中直接调用 `try? await`**：异步调用应通过 `Task {}` 包装，避免阻塞主 actor。
5. **不要跳过 SourceKit 索引重建来"修复"编译错误**：工作树中 SourceKit 报 "Cannot find type X in scope" 是索引延迟，不等于编译失败。先 `Product > Clean Build Folder` 再判断。

## 工作流程

> **每次写代码前，必须先完成以下步骤：**

1. **自然语言复述需求**：用中文写出你理解的需求是什么、你的假设是什么、计划怎么实现。
2. **等待确认**：等用户确认你的理解没有偏差，再开始写代码。每一个你没主动确认的假设，都等于你默认获得了批准。

看不懂需求？不知道用户想要什么？**先问，不要猜**。

---

详细规范见同级目录：

| 文件 | 内容 |
|------|------|
| `CONVENTIONS.md` | 代码风格、命名规范、注释规范 |
| `ARCHITECTURE.md` | 架构决策、数据流、关键设计模式 |
