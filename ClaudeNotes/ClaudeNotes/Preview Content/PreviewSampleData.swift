import SwiftData
import Foundation

@MainActor
let previewContainer: ModelContainer = {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Note.self, NoteFolder.self, AIAnalysis.self,
        configurations: config
    )

    // Sample data
    let workFolder = NoteFolder(name: "工作")
    let personalFolder = NoteFolder(name: "个人")
    container.mainContext.insert(workFolder)
    container.mainContext.insert(personalFolder)

    let note1 = Note(
        title: "项目计划",
        content: """
        # Q2 项目计划

        ## 目标
        - 完成 ClaudeNotes MVP
        - 集成 AI 分析功能
        - 支持 Markdown 编辑

        ## 时间线
        1. 第一周：基础架构
        2. 第二周：编辑器和搜索
        3. 第三周：AI 功能
        """,
        folder: workFolder
    )
    note1.isPinned = true

    let note2 = Note(
        title: "读书笔记",
        content: "今天读了《设计模式》第三章，主要讲了工厂模式和抽象工厂模式的区别……",
        folder: personalFolder
    )

    let note3 = Note(
        title: "会议记录",
        content: "与团队讨论了下季度的技术选型，决定使用 SwiftUI + SwiftData。",
        folder: workFolder
    )

    container.mainContext.insert(note1)
    container.mainContext.insert(note2)
    container.mainContext.insert(note3)

    return container
}()
