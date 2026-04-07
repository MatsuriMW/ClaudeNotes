import Foundation

// MARK: - Topic

struct InboxTopic: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var searchPrompt: String
    var enabled: Bool
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, icon: String, searchPrompt: String, enabled: Bool = false, isBuiltIn: Bool) {
        self.id = id; self.name = name; self.icon = icon
        self.searchPrompt = searchPrompt; self.enabled = enabled; self.isBuiltIn = isBuiltIn
    }

    static let builtIns: [InboxTopic] = [
        .init(name: "HackerNews 热门", icon: "flame",
              searchPrompt: "HackerNews top stories today (data will be provided)",
              enabled: true, isBuiltIn: true),
        .init(name: "科技资讯", icon: "cpu",
              searchPrompt: "latest technology news, product launches, and industry developments",
              enabled: true, isBuiltIn: true),
        .init(name: "AI / 机器学习", icon: "brain",
              searchPrompt: "latest AI and machine learning research, model releases, and industry news",
              enabled: false, isBuiltIn: true),
        .init(name: "NBA 动态", icon: "sportscourt",
              searchPrompt: "latest NBA basketball game results, standings, trades, and news",
              enabled: false, isBuiltIn: true),
        .init(name: "股市要闻", icon: "chart.line.uptrend.xyaxis",
              searchPrompt: "today's stock market key movements, earnings, macroeconomic news",
              enabled: false, isBuiltIn: true),
        .init(name: "B 站热门", icon: "play.tv",
              searchPrompt: "Bilibili (B站) today's top trending videos, their titles and topics",
              enabled: false, isBuiltIn: true),
        .init(name: "开源 / GitHub", icon: "chevron.left.forwardslash.chevron.right",
              searchPrompt: "latest open source releases and GitHub trending repositories this week",
              enabled: false, isBuiltIn: true),
        .init(name: "游戏资讯", icon: "gamecontroller",
              searchPrompt: "latest video game news, releases, and industry events",
              enabled: false, isBuiltIn: true),
    ]
}

// MARK: - Digest

struct InboxDigest: Codable, Identifiable {
    var id: UUID
    var generatedAt: Date
    var content: String
    var topicNames: [String]

    init(id: UUID = UUID(), generatedAt: Date = .now, content: String, topicNames: [String]) {
        self.id = id; self.generatedAt = generatedAt
        self.content = content; self.topicNames = topicNames
    }

    var shortDate: String {
        generatedAt.formatted(.dateTime.month().day().hour().minute())
    }

    var topicsLabel: String {
        topicNames.prefix(3).joined(separator: "、") + (topicNames.count > 3 ? "…" : "")
    }
}

// MARK: - Store

@Observable
final class InboxStore {
    static let shared = InboxStore()

    var topics: [InboxTopic] = []
    var keywords: [String] = []
    var digests: [InboxDigest] = []

    // Generation state (observed by SidebarView and InboxView)
    var isGenerating: Bool = false
    var generationProgress: String = ""
    var generationCompleted: Bool = false
    var generationError: String? = nil
    private var lastAutoDate: String = ""
    private var timer: Timer?

    private struct Persistence: Codable {
        var topics: [InboxTopic]
        var keywords: [String]
        var digests: [InboxDigest]
    }

    private var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("ClaudeNotes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("inbox_store.json")
    }

    private init() {
        load()
        lastAutoDate = UserDefaults.standard.string(forKey: "inboxLastAutoDate") ?? ""
        startDailyTimer()
    }

    /// Timer fires every minute while app is running — if it's past 7 AM and today hasn't
    /// generated yet, trigger generation automatically.
    private func startDailyTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkAndTriggerDaily()
        }
    }

    private func checkAndTriggerDaily() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour >= 7 else { return }
        let today = currentDateString()
        guard lastAutoDate != today else { return }
        lastAutoDate = today
        UserDefaults.standard.set(today, forKey: "inboxLastAutoDate")
        startGenerate()
    }

    var enabledTopics: [InboxTopic] { topics.filter(\.enabled) }

    func load() {
        if let data = try? Data(contentsOf: storeURL),
           let p = try? JSONDecoder().decode(Persistence.self, from: data) {
            topics = p.topics
            keywords = p.keywords
            digests = p.digests
            syncBuiltIns()
        } else {
            topics = InboxTopic.builtIns
        }
    }

    func save() {
        let p = Persistence(topics: topics, keywords: keywords, digests: digests)
        if let data = try? JSONEncoder().encode(p) {
            try? data.write(to: storeURL)
        }
    }

    private func syncBuiltIns() {
        let existingNames = Set(topics.filter(\.isBuiltIn).map(\.name))
        for builtin in InboxTopic.builtIns where !existingNames.contains(builtin.name) {
            topics.append(builtin)
        }
    }

    func addKeyword(_ kw: String) {
        let trimmed = kw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !keywords.contains(trimmed) else { return }
        keywords.append(trimmed)
        save()
    }

    func removeKeyword(_ kw: String) {
        keywords.removeAll { $0 == kw }
        save()
    }

    func addDigest(_ digest: InboxDigest) {
        digests.insert(digest, at: 0)
        if digests.count > 30 { digests = Array(digests.prefix(30)) }
        save()
    }

    func deleteDigest(_ digest: InboxDigest) {
        digests.removeAll { $0.id == digest.id }
        save()
    }

    func clearGenerationError() { generationError = nil }

    // MARK: - Auto-generate

    /// Called on app launch. Triggers background digest generation if after 7 AM and not yet done today.
    func startAutoGenerateIfNeeded() {
        checkAndTriggerDaily()
    }

    /// Start digest generation. Safe to call multiple times — no-ops if already running.
    func startGenerate() {
        guard !isGenerating, !enabledTopics.isEmpty || !keywords.isEmpty else { return }
        isGenerating = true
        generationCompleted = false
        generationError = nil
        let parts = [
            keywords.isEmpty ? nil : "\(keywords.count) 个关键词",
            enabledTopics.isEmpty ? nil : "\(enabledTopics.count) 个主题"
        ].compactMap { $0 }.joined(separator: " + ")
        generationProgress = "正在准备 \(parts)…"
        let enabled = enabledTopics
        let kws = keywords

        // 强制使用本地 Claude CLI
        let progressMsg = "正在调用本地 Claude CLI，请稍候…"

        Task {
            do {
                await MainActor.run { self.generationProgress = progressMsg }
                let digest = try await InboxService.shared.generateDigest(topics: enabled, keywords: kws)
                await MainActor.run {
                    self.addDigest(digest)
                    self.isGenerating = false
                    self.generationProgress = ""
                    self.generationCompleted = true
                    NotificationService.shared.send(
                        title: "今日简报已生成",
                        body: digest.topicsLabel.isEmpty
                            ? "点击查看今日资讯摘要"
                            : "涵盖：\(digest.topicsLabel)",
                        identifier: "inbox-generated"
                    )
                }
            } catch {
                await MainActor.run {
                    self.generationError = error.localizedDescription
                    self.isGenerating = false
                    self.generationProgress = ""
                }
            }
        }
    }

    private func currentDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }

    func addCustomTopic(name: String, prompt: String) {
        let t = InboxTopic(name: name, icon: "magnifyingglass", searchPrompt: prompt, enabled: true, isBuiltIn: false)
        topics.append(t)
        save()
    }

    func deleteTopic(_ topic: InboxTopic) {
        topics.removeAll { $0.id == topic.id }
        save()
    }

    func setEnabled(_ topic: InboxTopic, enabled: Bool) {
        if let idx = topics.firstIndex(where: { $0.id == topic.id }) {
            topics[idx].enabled = enabled
            save()
        }
    }

    func updateTopicFromPersona(interests: [String]) {
        for interest in interests {
            let alreadyExists = topics.contains { $0.name.localizedCaseInsensitiveContains(interest) }
            if !alreadyExists {
                addCustomTopic(name: interest, prompt: "latest news and developments about \(interest)")
            }
        }
    }
}
