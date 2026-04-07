import Foundation
import AppKit

// MARK: - Editor Settings

@Observable
final class EditorSettings {
    static let shared = EditorSettings()

    // MARK: - Types

    enum IndentShortcut: String, CaseIterable {
        case tab = "tab"
        case command = "command"

        var displayName: String {
            switch self {
            case .tab:      return "Tab / ⇧Tab"
            case .command:  return "⌘[ / ⌘]"
            }
        }
    }

    // MARK: - Typewriter Mode Types

    /// Where in the visible viewport the cursor line is pinned during typewriter mode.
    enum TypewriterScrollPosition: String, CaseIterable {
        case off      = "off"
        case top      = "top"
        case middle   = "middle"
        case bottom   = "bottom"

        var displayName: String {
            switch self {
            case .off:    return "关"
            case .top:    return "上"
            case .middle: return "中"
            case .bottom: return "下"
            }
        }

        /// Y-fraction of the visible viewport height where the cursor should sit.
        var fraction: CGFloat? {
            switch self {
            case .off:    return nil
            case .top:    return 0.25
            case .middle: return 0.50
            case .bottom: return 0.75
            }
        }
    }

    /// How much surrounding text to dim in typewriter focus mode.
    enum TypewriterFocusMode: String, CaseIterable {
        case off       = "off"
        case line      = "line"
        case sentence  = "sentence"
        case paragraph = "paragraph"

        var displayName: String {
            switch self {
            case .off:       return "关"
            case .line:      return "行"
            case .sentence:  return "句"
            case .paragraph: return "段落"
            }
        }
    }

    enum EditorMode: String, CaseIterable {
        case document = "document"
        case outline  = "outline"

        var displayName: String {
            switch self {
            case .document: return "文档"
            case .outline:  return "大纲"
            }
        }
    }

    enum IndentUnit: String, CaseIterable {
        case spaces2 = "spaces2"
        case spaces4 = "spaces4"
        case tab1    = "tab1"
        case tab2    = "tab2"

        var displayName: String {
            switch self {
            case .spaces2: return "2 个空格"
            case .spaces4: return "4 个空格"
            case .tab1:    return "1 个 Tab"
            case .tab2:    return "2 个 Tab"
            }
        }

        var string: String {
            switch self {
            case .spaces2: return "  "
            case .spaces4: return "    "
            case .tab1:    return "\t"
            case .tab2:    return "\t\t"
            }
        }
    }

    // MARK: - Stored Properties

    var indentShortcut: IndentShortcut {
        didSet { save("indentShortcut", indentShortcut.rawValue) }
    }
    var indentUnit: IndentUnit {
        didSet { save("indentUnit", indentUnit.rawValue) }
    }
    var fontFamilyName: String {
        didSet { save("fontFamilyName", fontFamilyName); settingsVersion += 1 }
    }
    var fontSize: Double {
        didSet { save("editorFontSize", fontSize); settingsVersion += 1 }
    }
    var lineHeightMultiple: Double {
        didSet { save("lineHeightMultiple", lineHeightMultiple); settingsVersion += 1 }
    }
    var autoPairBrackets: Bool {
        didSet { save("autoPairBrackets", autoPairBrackets) }
    }
    var spellingCheck: Bool {
        didSet { save("spellingCheck", spellingCheck); settingsVersion += 1 }
    }
    var smartQuotes: Bool {
        didSet { save("smartQuotes", smartQuotes); settingsVersion += 1 }
    }
    var wikiLinkColor: NSColor {
        didSet {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: wikiLinkColor, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "wikiLinkColor")
            }
            settingsVersion += 1
        }
    }

    // MARK: - Display settings version (incremented whenever a display-relevant property changes)
    // Used by MarkdownTextView.updateNSView to skip applyEditorSettings on every keystroke.

    private(set) var settingsVersion: Int = 0

    // MARK: - Editing Modes

    var editorMode: EditorMode {
        didSet { save("editorMode", editorMode.rawValue) }
    }
    var isTypewriterMode: Bool {
        didSet { save("isTypewriterMode", isTypewriterMode) }
    }
    var typewriterScrollPosition: TypewriterScrollPosition {
        didSet { save("typewriterScrollPosition", typewriterScrollPosition.rawValue) }
    }
    var typewriterFocusMode: TypewriterFocusMode {
        didSet { save("typewriterFocusMode", typewriterFocusMode.rawValue) }
    }
    var typewriterMarkLine: Bool {
        didSet { save("typewriterMarkLine", typewriterMarkLine) }
    }

    // MARK: - Version Control

    /// Interval in minutes between auto-saved versions while editing. 0 = only on note switch / close.
    var versionIntervalMinutes: Int {
        didSet { save("versionIntervalMinutes", versionIntervalMinutes) }
    }
    /// Max versions retained per note.
    var maxVersionsPerNote: Int {
        didSet { save("maxVersionsPerNote", maxVersionsPerNote) }
    }
    /// Auto-delete versions older than this many days. 0 = never.
    var autoDeleteVersionsDays: Int {
        didSet { save("autoDeleteVersionsDays", autoDeleteVersionsDays) }
    }

    // MARK: - Init

    init() {
        let d = UserDefaults.standard
        indentShortcut   = IndentShortcut(rawValue: d.string(forKey: "indentShortcut") ?? "") ?? .tab
        indentUnit       = IndentUnit(rawValue: d.string(forKey: "indentUnit") ?? "") ?? .spaces4
        if let name = d.string(forKey: "fontFamilyName") {
            fontFamilyName = name
        } else {
            // migrate from old enum
            let legacy = d.string(forKey: "editorFont") ?? ""
            fontFamilyName = legacy  // empty string = system monospaced
        }
        let storedSize   = d.double(forKey: "editorFontSize")
        fontSize         = storedSize > 0 ? storedSize : 14
        let storedLH     = d.double(forKey: "lineHeightMultiple")
        lineHeightMultiple = storedLH > 0 ? storedLH : 1.4
        autoPairBrackets = d.object(forKey: "autoPairBrackets") as? Bool ?? true
        spellingCheck    = d.object(forKey: "spellingCheck") as? Bool ?? false
        smartQuotes      = d.object(forKey: "smartQuotes") as? Bool ?? false
        editorMode       = EditorMode(rawValue: d.string(forKey: "editorMode") ?? "") ?? .document
        isTypewriterMode = d.object(forKey: "isTypewriterMode") as? Bool ?? false
        typewriterScrollPosition = TypewriterScrollPosition(rawValue: d.string(forKey: "typewriterScrollPosition") ?? "") ?? .middle
        typewriterFocusMode      = TypewriterFocusMode(rawValue: d.string(forKey: "typewriterFocusMode") ?? "") ?? .off
        typewriterMarkLine       = d.object(forKey: "typewriterMarkLine") as? Bool ?? false
        let storedInterval = d.object(forKey: "versionIntervalMinutes") as? Int ?? 0
        versionIntervalMinutes = storedInterval
        let storedMax = d.object(forKey: "maxVersionsPerNote") as? Int ?? 50
        maxVersionsPerNote = storedMax > 0 ? storedMax : 50
        let storedDays = d.object(forKey: "autoDeleteVersionsDays") as? Int ?? 0
        autoDeleteVersionsDays = storedDays
        if let data = d.data(forKey: "wikiLinkColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            wikiLinkColor = color
        } else {
            wikiLinkColor = .systemBlue
        }
    }

    // MARK: - Helpers

    func makeNSFont() -> NSFont {
        guard !fontFamilyName.isEmpty else {
            return .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        }
        return NSFontManager.shared.font(withFamily: fontFamilyName, traits: [], weight: 5, size: CGFloat(fontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
