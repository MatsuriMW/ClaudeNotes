import SwiftUI
import SwiftData

// MARK: - Main View

struct PersonaView: View {
    @Query private var notes: [Note]
    @Environment(\.modelContext) private var modelContext

    @State private var store = PersonaStore.shared

    private var activeNotes: [Note] { notes.filter { !$0.isDeleted } }

    /// Notes that are new or modified since the last analysis.
    private var unseen: [Note] {
        guard let p = store.persona else { return activeNotes }
        let seen   = Set(p.analyzedNoteIDs)
        let cutoff = p.lastPatchedAt ?? p.generatedAt
        return activeNotes.filter { !seen.contains($0.id) || $0.modifiedAt > cutoff }
    }
    private var hasNewContent: Bool { store.persona != nil && !unseen.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let persona = store.persona {
                    personaContent(persona)
                } else {
                    emptyState
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let persona = store.persona {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("基于 \(persona.noteCount) 篇笔记")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("更新于\(persona.ageDescription)")
                            .font(.caption2)
                            .foregroundStyle(persona.isStale ? .orange : .secondary)
                    }
                    if !store.isAnalyzing {
                        Button {
                            store.startPatch(existing: persona, newNotes: unseen, allActiveNotes: activeNotes)
                        } label: {
                            Label(hasNewContent ? "增量更新" : "重新分析", systemImage: hasNewContent ? "arrow.triangle.2.circlepath" : "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(hasNewContent ? "有 \(unseen.count) 篇新笔记，增量更新画像" : "使用全部笔记重新分析")
                    }
                }
                if store.isAnalyzing {
                    ProgressView().controlSize(.small)
                } else if store.analysisCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuGeneratePersona)) { _ in
            guard !activeNotes.isEmpty else { return }
            store.startAnalysis(notes: activeNotes)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuUpdatePersona)) { _ in
            guard hasNewContent, let persona = store.persona else { return }
            store.startPatch(existing: persona, newNotes: unseen, allActiveNotes: activeNotes)
        }
    }

    // MARK: - Sub-Views

    @ViewBuilder
    private func personaContent(_ p: UserPersona) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header: MBTI + summary
            MBTICard(mbti: p.mbti)

            // Recent focus
            if !p.recentFocus.isEmpty {
                InfoCard(title: "近期关注", icon: "eye", content: p.recentFocus)
            }

            // Overall portrait
            InfoCard(title: "人格画像", icon: "person.text.rectangle", content: p.summary)

            // Interests
            if !p.interests.isEmpty {
                InterestsSection(interests: p.interests.sorted { $0.intensity > $1.intensity })
            }

            // Personality traits
            if !p.personalityTraits.isEmpty {
                TraitsSection(traits: p.personalityTraits)
            }

            // Writing style
            if !p.writingStyle.isEmpty {
                InfoCard(title: "写作与思维风格", icon: "text.alignleft", content: p.writingStyle)
            }

            // Suggestions
            if !p.suggestions.isEmpty {
                SuggestionsSection(suggestions: p.suggestions)
            }

            // Footer
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tertiary)
                    Text("初次分析于 \(p.generatedAt.formatted(.dateTime.year().month().day())) · \(p.noteCount) 篇笔记 · \(p.totalWords) 字")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let patched = p.lastPatchedAt {
                    HStack {
                        Image(systemName: "sparkle")
                            .foregroundStyle(.tertiary)
                        Text("最近增量更新于 \(patched.formatted(.dateTime.year().month().day().hour().minute()))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 8)

            if p.isStale {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("画像已超过 \(UserPersona.updateIntervalDays) 天，建议重新分析以反映最新状态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 80)
            if store.isAnalyzing {
                ProgressView().scaleEffect(1.5)
                Text("正在深度分析笔记库…")
                    .font(.headline)
                Text(store.analysisProgress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
                Text("你的个人画像")
                    .font(.title2.weight(.semibold))
                Text("AI 将阅读你的笔记库，分析你的性格特质、兴趣分布、MBTI 类型，并给出个性化建议。\n\n所有分析使用本地 Claude Code 完成。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                if let err = store.analysisError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }
                if activeNotes.isEmpty {
                    Text("请先写几篇笔记再来生成画像")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("开始分析") {
                        store.startAnalysis(notes: activeNotes)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("分析全部 \(activeNotes.count) 篇笔记")
                }
            }
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

}

// MARK: - MBTI Card

private struct MBTICard: View {
    let mbti: UserPersona.MBTI

    private var typeColor: Color {
        switch mbti.type.prefix(1) {
        case "I": return .indigo
        case "E": return .orange
        default:  return .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mbti.type)
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(typeColor)
                    HStack(spacing: 8) {
                        ForEach(Array(mbti.type), id: \.self) { letter in
                            Text(String(letter))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(typeColor.opacity(0.12))
                                .foregroundStyle(typeColor)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("置信度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(mbti.confidence)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(confidenceColor(mbti.confidence).opacity(0.12))
                        .foregroundStyle(confidenceColor(mbti.confidence))
                        .clipShape(Capsule())
                }
            }

            // Dimension bars (shown when available)
            if let dim = mbti.dimensions {
                VStack(spacing: 6) {
                    DimensionBar(leftLabel: "I", rightLabel: "E", score: dim.iVsE, color: typeColor)
                    DimensionBar(leftLabel: "N", rightLabel: "S", score: dim.nVsS, color: typeColor)
                    DimensionBar(leftLabel: "T", rightLabel: "F", score: dim.tVsF, color: typeColor)
                    DimensionBar(leftLabel: "J", rightLabel: "P", score: dim.jVsP, color: typeColor)
                }
                .padding(.top, 4)
            }

            if !mbti.reasoning.isEmpty {
                Text(mbti.reasoning)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(typeColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(typeColor.opacity(0.2), lineWidth: 1)
        )
    }

    private func confidenceColor(_ c: String) -> Color {
        switch c {
        case "高": return .green
        case "中": return .orange
        default:   return .red
        }
    }
}

// MARK: - Dimension Bar

private struct DimensionBar: View {
    let leftLabel: String
    let rightLabel: String
    /// 0 = 100% right, 100 = 100% left
    let score: Int
    let color: Color

    private var fraction: Double { Double(max(0, min(100, score))) / 100.0 }
    private var dominantLabel: String { score >= 50 ? leftLabel : rightLabel }
    private var dominantPercent: Int { score >= 50 ? score : 100 - score }

    var body: some View {
        HStack(spacing: 6) {
            Text(leftLabel)
                .font(.system(size: 11, weight: score >= 50 ? .bold : .regular, design: .rounded))
                .foregroundStyle(score >= 50 ? color : .secondary)
                .frame(width: 14, alignment: .center)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.1))
                    Capsule()
                        .fill(color.opacity(0.65))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)

            Text(rightLabel)
                .font(.system(size: 11, weight: score < 50 ? .bold : .regular, design: .rounded))
                .foregroundStyle(score < 50 ? color : .secondary)
                .frame(width: 14, alignment: .center)

            Text("\(dominantPercent)% \(dominantLabel)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Interests Section

private struct InterestsSection: View {
    let interests: [UserPersona.InterestArea]
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "兴趣分布", icon: "star")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(interests) { area in
                    InterestCard(area: area, isExpanded: expanded == area.id)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expanded = expanded == area.id ? nil : area.id
                            }
                        }
                }
            }
        }
    }
}

private struct InterestCard: View {
    let area: UserPersona.InterestArea
    let isExpanded: Bool

    private var accentColor: Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        let idx = abs(area.name.hashValue) % colors.count
        return colors[idx]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(area.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                IntensityDots(value: area.intensity, color: accentColor)
            }
            if isExpanded {
                Text(area.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(isExpanded ? 0.4 : 0.15), lineWidth: 1)
        )
    }
}

private struct IntensityDots: View {
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= value ? color : color.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

// MARK: - Traits Section

private struct TraitsSection: View {
    let traits: [UserPersona.PersonalityTrait]
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "性格特质", icon: "brain.head.profile")
            VStack(spacing: 8) {
                ForEach(traits) { trait in
                    TraitRow(trait: trait, isExpanded: expanded == trait.id)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expanded = expanded == trait.id ? nil : trait.id
                            }
                        }
                }
            }
        }
    }
}

private struct TraitRow: View {
    let trait: UserPersona.PersonalityTrait
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.teal)
                    .font(.callout)
                Text(trait.name)
                    .font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trait.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !trait.evidence.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Rectangle()
                                .fill(.teal.opacity(0.6))
                                .frame(width: 3)
                                .clipShape(Capsule())
                            Text(trait.evidence)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Suggestions

private struct SuggestionsSection: View {
    let suggestions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "个性化建议", icon: "lightbulb")
            VStack(spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(i + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.blue)
                            .clipShape(Circle())
                        Text(s)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(12)
                    .background(.blue.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

// MARK: - Shared Components

private struct InfoCard: View {
    let title: String
    let icon: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, icon: icon)
            Text(content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

