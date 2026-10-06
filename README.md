# ClaudeNotes

A native macOS note-taking app with AI built in (SwiftUI + SwiftData).

自己做的 macOS 原生笔记 App。全程用 Claude Code（agent + skills）vibe coding 完成，从写 PRD、定架构和约定文档，到长期迭代一个几十个文件的 Swift 项目。

## 功能

| 模块 | 做了什么 |
|---|---|
| 大纲式编辑器 | 自己重写的图层编辑器（CoreText + 行级 layer），支持大纲折叠、双链高亮、Markdown 渲染、版本历史 |
| 任务管理 | 从笔记里提取待办，看板视图（Kanban） |
| 个人画像 | 让 AI 读整个笔记库，分析 MBTI、荣格八维、性格特质、兴趣和写作风格，再以画像为背景和用户对话 |
| AI 写作 | 续写、改写、按平台风格改写（公众号 / 小红书等），生成元数据 |
| 每日简报 | Inbox：从笔记提炼当天待办、灵感与摘要；股票 / 基金板块的当日分析 |
| 多模型 | 本机 Claude CLI、Claude / OpenAI / Gemini API，以及内嵌网页版 Chat；API Key 存 Keychain |

## 文档

项目文档都在 [`ClaudeNotes/`](ClaudeNotes) 下，也是给 AI 协作用的上下文：

- [PRD.md](ClaudeNotes/PRD.md)：产品需求文档
- [ARCHITECTURE.md](ClaudeNotes/ARCHITECTURE.md)：架构与数据流
- [CONVENTIONS.md](ClaudeNotes/CONVENTIONS.md)：编码约定
- [CLAUDE.md](ClaudeNotes/CLAUDE.md)：给 Claude Code 的工作规则
- [docs/superpowers/plans/](ClaudeNotes/docs/superpowers/plans)：编辑器重写的实施计划

## 运行

macOS 14+，Xcode 打开 `ClaudeNotes/ClaudeNotes.xcodeproj` 直接运行。AI 功能需要在设置里填 API Key，或者本机装好 Claude Code CLI。
