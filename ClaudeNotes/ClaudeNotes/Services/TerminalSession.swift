import Foundation
import Darwin

class TerminalSession: ObservableObject {
    @Published var output: String = ""
    @Published var isRunning = false

    private var masterFD: Int32 = -1
    private var process: Process?
    private var readSource: DispatchSourceRead?
    private let ptyQueue = DispatchQueue(label: "com.claudenotes.pty", qos: .userInteractive)

    // MARK: - Lifecycle

    func start(workingDirectory: String? = nil) {
        guard !isRunning else { return }

        var slaveFD: Int32 = -1
        var localMaster: Int32 = -1
        var ws = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&localMaster, &slaveFD, nil, nil, &ws) == 0 else {
            appendOutput("[错误: 无法创建伪终端]\n")
            return
        }
        masterFD = localMaster

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l"]   // login shell — loads user PATH (homebrew, etc.)

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = "200"
        env["LINES"] = "50"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        p.environment = env

        if let dir = workingDirectory, FileManager.default.fileExists(atPath: dir) {
            p.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        p.standardInput = slaveHandle
        p.standardOutput = slaveHandle
        p.standardError = slaveHandle

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.appendOutput("\n[会话结束 (exit \(proc.terminationStatus))]\n")
            }
        }

        do {
            try p.launch()
        } catch {
            appendOutput("[启动失败: \(error.localizedDescription)]\n")
            Darwin.close(localMaster)
            Darwin.close(slaveFD)
            masterFD = -1
            return
        }

        // Close slave in parent after fork
        Darwin.close(slaveFD)

        process = p
        isRunning = true

        // Async read output from master PTY
        let source = DispatchSource.makeReadSource(fileDescriptor: localMaster, queue: ptyQueue)
        source.setEventHandler { [weak self] in
            guard let self, self.masterFD != -1 else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(self.masterFD, &buf, 4096)
            guard n > 0 else { return }
            let data = Data(buf[..<n])
            let raw = String(data: data, encoding: .utf8)
                   ?? String(data: data, encoding: .isoLatin1)
                   ?? ""
            let stripped = self.stripANSI(raw)
            DispatchQueue.main.async { self.appendOutput(stripped) }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.masterFD != -1 else { return }
            Darwin.close(self.masterFD)
            self.masterFD = -1
        }
        source.resume()
        readSource = source
    }

    func stop() {
        process?.interrupt()
        readSource?.cancel()
        readSource = nil
        process = nil
    }

    func restart(workingDirectory: String? = nil) {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.output = ""
            self?.start(workingDirectory: workingDirectory)
        }
    }

    // MARK: - Input

    /// Send raw text (call with "\n" appended for a command).
    func sendInput(_ text: String) {
        guard masterFD != -1, isRunning else { return }
        ptyQueue.async { [weak self] in
            guard let self, self.masterFD != -1 else { return }
            var bytes = Array(text.utf8)
            Darwin.write(self.masterFD, &bytes, bytes.count)
        }
    }

    /// Send a single control byte (e.g. 0x03 = Ctrl+C, 0x04 = Ctrl+D, 0x09 = Tab).
    func sendControlByte(_ byte: UInt8) {
        guard masterFD != -1, isRunning else { return }
        ptyQueue.async { [weak self] in
            guard let self, self.masterFD != -1 else { return }
            var b = byte
            Darwin.write(self.masterFD, &b, 1)
        }
    }

    // MARK: - Helpers

    private func appendOutput(_ text: String) {
        output += text
        // Keep memory bounded
        if output.count > 120_000 {
            let idx = output.index(output.endIndex, offsetBy: -80_000)
            output = String(output[idx...])
        }
    }

    private func stripANSI(_ s: String) -> String {
        var result = s
        // CSI sequences: ESC [ params final
        // OSC sequences: ESC ] ... BEL/ST
        // Other ESC sequences
        let patterns: [String] = [
            #"\x1B\[[0-9;?]*[ -/]*[@-~]"#,
            #"\x1B\][^\x07]*\x07"#,
            #"\x1B[^[\]]"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let r = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: r, withTemplate: "")
            }
        }
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        return result
    }
}
