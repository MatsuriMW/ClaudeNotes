import SwiftUI
import AppKit

// MARK: - LayerEditorView

struct LayerEditorView: NSViewRepresentable {

    @Binding var text: String
    var noteID: UUID
    var shortcutSettings: ShortcutSettings
    var editorSettings: EditorSettings
    var holder: TextViewHolder?
    var onTextChange: (() -> Void)?
    var onTogglePreview: (() -> Void)?
    var onClaudeWrite: (() -> Void)?
    var onRevealInFinder: (() -> Void)?
    var outlineMode: Bool = false
    var typewriterMode: Bool = false
    var typewriterScrollFraction: CGFloat = 0.5
    var typewriterFocusMode: EditorSettings.TypewriterFocusMode = .off
    var typewriterMarkLine: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize

        // Create the editor stack
        let textStorage = EditorTextStorage()
        let renderer = EditorRenderer(textStorage: textStorage)
        let inputView = EditorTextInputView(frame: NSRect(origin: .zero, size: contentSize))
        inputView.textStorage = textStorage
        inputView.renderer = renderer
        renderer.textInputView = inputView

        // Apply settings
        renderer.font = editorSettings.makeNSFont()
        renderer.lineHeightMultiple = CGFloat(editorSettings.lineHeightMultiple)
        renderer.typewriterMode = typewriterMode
        renderer.typewriterScrollFraction = typewriterScrollFraction
        renderer.typewriterMarkLine = typewriterMarkLine

        // Map EditorSettings.TypewriterFocusMode to EditorRenderer.TypewriterFocusMode
        switch typewriterFocusMode {
        case .off:       renderer.typewriterFocusMode = .off
        case .line:      renderer.typewriterFocusMode = .line
        case .sentence:  renderer.typewriterFocusMode = .sentence
        case .paragraph: renderer.typewriterFocusMode = .paragraph
        }

        // Connect typewriter scroll callback
        inputView.onCursorMoved = { [weak renderer] in
            renderer?.scrollToCursor()
        }

        // Connect text callbacks
        textStorage.onTextChanged = { newContent in
            Task { @MainActor in
                context.coordinator.isUpdating = true
                text = newContent
                context.coordinator.isUpdating = false
                onTextChange?()
            }
        }

        // Make the input view the document view
        scrollView.documentView = inputView

        // Configure document view autoresizing (width-only; height grows with content)
        inputView.autoresizingMask = [.width]

        // Track scroll events
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { _ in
            let offset = scrollView.contentView.bounds.origin
            renderer.setScrollOffset(offset)
            renderer.setVisibleRect(scrollView.documentVisibleRect)
        }

        // Initial layout
        renderer.setContentSize(width: contentSize.width, height: contentSize.height)

        // Set initial text
        textStorage.setText(text)

        context.coordinator.renderer = renderer
        context.coordinator.textStorage = textStorage
        context.coordinator.inputView = inputView

        // Note: holder.textView is typed as MarkdownEditorNSTextView?, not EditorTextInputView.
        // The holder slot is provided for compatibility but is not used by the layer editor.

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let inputView = scrollView.documentView as? EditorTextInputView,
              let renderer = context.coordinator.renderer,
              let textStorage = context.coordinator.textStorage else { return }

        // Apply settings changes
        renderer.font = editorSettings.makeNSFont()
        renderer.lineHeightMultiple = CGFloat(editorSettings.lineHeightMultiple)
        renderer.typewriterMode = typewriterMode
        renderer.typewriterScrollFraction = typewriterScrollFraction
        renderer.typewriterMarkLine = typewriterMarkLine
        switch typewriterFocusMode {
        case .off:       renderer.typewriterFocusMode = .off
        case .line:      renderer.typewriterFocusMode = .line
        case .sentence:  renderer.typewriterFocusMode = .sentence
        case .paragraph: renderer.typewriterFocusMode = .paragraph
        }

        // External text change (e.g., note switch)
        if !context.coordinator.isUpdating && textStorage.trueContent() != text {
            context.coordinator.isUpdating = true
            textStorage.setText(text)
            context.coordinator.isUpdating = false
            renderer.rebuildLayout()
        }

        // Resize
        let sz = scrollView.contentSize
        renderer.setContentSize(width: sz.width, height: sz.height)
        inputView.frame.size = sz
    }

    class Coordinator: NSObject {
        var parent: LayerEditorView
        weak var renderer: EditorRenderer?
        weak var textStorage: EditorTextStorage?
        weak var inputView: EditorTextInputView?
        var isUpdating = false

        init(_ parent: LayerEditorView) {
            self.parent = parent
        }
    }
}
