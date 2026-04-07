import SwiftUI
import SwiftTerm

struct ClaudeTerminalView: View {
    let note: Note?
    /// Optional system-prompt context injected silently (not shown in terminal).
    let initialContext: String?
    /// Explicit session ID — when it changes the terminal restarts.
    let sessionID: UUID?

    init(note: Note? = nil, initialContext: String? = nil, sessionID: UUID? = nil) {
        self.note = note
        self.initialContext = initialContext
        self.sessionID = sessionID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalContainerView(
                workingDirectory: workingDirectory,
                sessionID: resolvedSessionID,
                initialContext: initialContext
            )
        }
    }

    private var workingDirectory: String {
        if let path = note?.filePath {
            return URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
        return NSHomeDirectory()
    }

    private var resolvedSessionID: UUID {
        sessionID ?? note?.id ?? UUID(uuidString: "00000000-CCCC-0000-0000-000000000000")!
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.secondary)
            Text("Claude Code")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - NSViewRepresentable

private struct TerminalContainerView: NSViewRepresentable {
    let workingDirectory: String
    let sessionID: UUID
    let initialContext: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: .zero)
        tv.processDelegate = context.coordinator
        context.coordinator.terminalView = tv
        context.coordinator.currentSessionID = sessionID
        launch(in: tv)
        return tv
    }

    func updateNSView(_ tv: LocalProcessTerminalView, context: Context) {
        guard context.coordinator.currentSessionID != sessionID else { return }
        context.coordinator.currentSessionID = sessionID
        launch(in: tv)
    }

    private func launch(in tv: LocalProcessTerminalView) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"

        // Inject context as env var so it never appears as typed text in the terminal.
        // Claude is started with --system-prompt "$CLAUDENOTES_CTX" which is a short,
        // non-revealing command even though the actual content may be long.
        let claudeCmd: String
        if let ctx = initialContext, !ctx.isEmpty {
            env["CLAUDENOTES_CTX"] = ctx
            claudeCmd = "claude --system-prompt \"$CLAUDENOTES_CTX\"\n"
        } else {
            claudeCmd = "claude\n"
        }

        let envArray = env.map { "\($0.key)=\($0.value)" }

        tv.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: envArray,
            execName: "zsh",
            currentDirectory: workingDirectory
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            tv.send(data: Array(claudeCmd.utf8)[...])
        }
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var terminalView: LocalProcessTerminalView?
        var currentSessionID: UUID?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
