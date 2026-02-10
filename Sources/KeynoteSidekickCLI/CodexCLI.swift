import Foundation

enum CodexCLIError: LocalizedError {
    case commandNotFound(String)
    case timedOut
    case cancelled
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let hint):
            return "Codex CLI not found for path '\(hint)'. Install Codex CLI or update Settings."
        case .timedOut:
            return "Codex request timed out."
        case .cancelled:
            return "Codex request was canceled."
        case .executionFailed(let message):
            return message
        }
    }
}

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

struct ProtoEvent {
    let id: String
    let type: String
    let payload: [String: Any]
}

struct ProtoTurnResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let events: [ProtoEvent]
    let sessionModel: String?
    let lastAgentMessage: String?
    let errorMessage: String?
}

enum CodexLoginState {
    case authenticated(String)
    case unauthenticated(String)
    case unknown(String)
}

enum CodexCLI {
    static let preferredModelCandidates: [String] = [
        "gpt-5.2-codex",
        "gpt-5.1-codex",
        "gpt-5-codex"
    ]

    static func loginStatus(codexPath: String) -> String {
        switch loginState(codexPath: codexPath) {
        case .authenticated(let text), .unauthenticated(let text), .unknown(let text):
            return text
        }
    }

    static func loginState(codexPath: String) -> CodexLoginState {
        do {
            let result = try run(
                executableHint: codexPath,
                arguments: ["login", "status"],
                timeout: 8
            )

            let merged = [result.stdout, result.stderr]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if merged.isEmpty, result.exitCode == 0 {
                return .unknown("Codex login status is unavailable.")
            }
            if merged.isEmpty, result.exitCode != 0 {
                return .unauthenticated("Codex is not logged in.")
            }

            let lowered = merged.lowercased()
            if lowered.contains("not logged") ||
                lowered.contains("login required") ||
                lowered.contains("log in") ||
                lowered.contains("authenticate") {
                return .unauthenticated(merged)
            }
            if lowered.contains("logged in") ||
                lowered.contains("authenticated") {
                return .authenticated(merged)
            }
            if result.exitCode == 0 {
                return .unknown(merged)
            }
            return .unauthenticated(merged)
        } catch {
            return .unknown("Status check failed: \(error.localizedDescription)")
        }
    }

    static func discoverAccessibleModels(
        codexPath: String,
        candidates: [String] = preferredModelCandidates
    ) -> [String] {
        let cwd = FileManager.default.currentDirectoryPath
        var accessible: [String] = []
        for model in candidates {
            do {
                let result = try runProtoUserTurn(
                    executableHint: codexPath,
                    prompt: "Reply with exactly: ok",
                    model: model,
                    cwd: cwd,
                    timeout: 25
                )
                let detail = [result.errorMessage ?? "", result.stderr, result.stdout]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if containsModelAccessError(detail) {
                    continue
                }
                if let message = result.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !message.isEmpty {
                    accessible.append(model)
                    continue
                }
                if result.exitCode == 0, detail.isEmpty {
                    accessible.append(model)
                }
            } catch {
                continue
            }
        }
        return accessible
    }

    static func run(
        executableHint: String,
        arguments: [String],
        timeout: TimeInterval,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> ProcessResult {
        guard let executable = resolveExecutable(hint: executableHint) else {
            throw CodexCLIError.commandNotFound(executableHint)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            if !existing.contains("/opt/homebrew/bin") {
                env["PATH"] = existing + ":" + defaultPath
            }
        } else {
            env["PATH"] = defaultPath
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexCLIError.executionFailed("Failed to launch Codex CLI: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if shouldCancel?() == true {
                terminateAndWait(process)
                throw CodexCLIError.cancelled
            }
            if Date() >= deadline {
                terminateAndWait(process)
                throw CodexCLIError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func runProtoUserTurn(
        executableHint: String,
        prompt: String,
        model: String,
        effort: String = "medium",
        hideAgentReasoning: Bool = true,
        modelReasoningSummary: String = "auto",
        showRawAgentReasoning: Bool = false,
        cwd: String,
        timeout: TimeInterval,
        shouldCancel: (() -> Bool)? = nil,
        onEvent: ((ProtoEvent) -> Void)? = nil,
        onHeartbeat: ((TimeInterval) -> Void)? = nil
    ) throws -> ProtoTurnResult {
        guard let executable = resolveExecutable(hint: executableHint) else {
            throw CodexCLIError.commandNotFound(executableHint)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "proto",
            "-c", "model=\(jsonStringLiteral(model))"
        ]

        var env = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existing = env["PATH"], !existing.isEmpty {
            if !existing.contains("/opt/homebrew/bin") {
                env["PATH"] = existing + ":" + defaultPath
            }
        } else {
            env["PATH"] = defaultPath
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let parser = ProtoStreamParser(onEvent: onEvent)
        let stderrCollector = SynchronizedTextCollector()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readGroup.leave() }
            while true {
                let data = stdoutPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                parser.appendStdout(data)
            }
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readGroup.leave() }
            while true {
                let data = stderrPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                stderrCollector.append(data: data)
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexCLIError.executionFailed("Failed to launch Codex CLI proto mode: \(error.localizedDescription)")
        }

        do {
            let submission = try buildProtoUserTurnSubmission(
                prompt: prompt,
                model: model,
                effort: effort,
                hideAgentReasoning: hideAgentReasoning,
                modelReasoningSummary: modelReasoningSummary,
                showRawAgentReasoning: showRawAgentReasoning,
                cwd: cwd
            )
            if let payload = (submission + "\n").data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(payload)
            }
            try? stdinPipe.fileHandleForWriting.close()
        } catch {
            terminateAndWait(process)
            throw CodexCLIError.executionFailed("Failed to submit proto request: \(error.localizedDescription)")
        }

        let startTime = Date()
        var lastHeartbeatEmission = startTime
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if shouldCancel?() == true {
                terminateAndWait(process)
                throw CodexCLIError.cancelled
            }
            if parser.hasTerminalEvent {
                terminateAndWait(process)
                break
            }
            let now = Date()
            if now.timeIntervalSince(lastHeartbeatEmission) >= 5 {
                onHeartbeat?(now.timeIntervalSince(startTime))
                lastHeartbeatEmission = now
            }
            if let streamError = parser.errorMessage,
               containsModelAccessError(streamError) {
                terminateAndWait(process)
                break
            }
            if now >= deadline {
                terminateAndWait(process)
                throw CodexCLIError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            waitForExit(process)
        }

        _ = readGroup.wait(timeout: .now() + 2.0)

        return ProtoTurnResult(
            exitCode: process.terminationStatus,
            stdout: parser.stdoutText,
            stderr: stderrCollector.text,
            events: parser.events,
            sessionModel: parser.sessionModel,
            lastAgentMessage: parser.lastAgentMessage,
            errorMessage: parser.errorMessage
        )
    }

    private static func buildProtoUserTurnSubmission(
        prompt: String,
        model: String,
        effort: String,
        hideAgentReasoning: Bool,
        modelReasoningSummary: String,
        showRawAgentReasoning: Bool,
        cwd: String
    ) throws -> String {
        let normalizedEffort: String
        switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low", "medium", "high":
            normalizedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default:
            normalizedEffort = "medium"
        }

        let normalizedSummary: String
        switch modelReasoningSummary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto", "brief", "detailed":
            normalizedSummary = modelReasoningSummary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default:
            normalizedSummary = "auto"
        }

        let payload: [String: Any] = [
            "id": "turn-\(UUID().uuidString)",
            "op": [
                "type": "user_turn",
                "items": [
                    [
                        "type": "text",
                        "text": prompt
                    ]
                ],
                "cwd": cwd,
                "approval_policy": "never",
                "sandbox_policy": [
                    "mode": "read-only"
                ],
                "model": model,
                "effort": normalizedEffort,
                "summary": normalizedSummary,
                "hide_agent_reasoning": hideAgentReasoning,
                "model_reasoning_summary": normalizedSummary,
                "show_raw_agent_reasoning": showRawAgentReasoning
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexCLIError.executionFailed("Could not encode proto request payload as UTF-8.")
        }
        return text
    }

    private static func resolveExecutable(hint: String) -> String? {
        let fm = FileManager.default
        if hint.contains("/") {
            return fm.isExecutableFile(atPath: hint) ? hint : nil
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = path.split(separator: ":").map(String.init)
        let fixedCandidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        for directory in pathCandidates + fixedCandidates {
            let candidate = (directory as NSString).appendingPathComponent(hint)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func containsModelAccessError(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("does not exist or you do not have access") ||
            (lowered.contains("model") && lowered.contains("does not exist")) ||
            lowered.contains("unknown model")
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func terminateAndWait(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        waitForExit(process)
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval = 3.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.waitUntilExit()
        }
    }
}

private final class SynchronizedTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    var text: String {
        lock.lock()
        let current = storage
        lock.unlock()
        return current
    }

    func append(data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }
}

private final class ProtoStreamParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var output = ""
    private var parsedEvents: [ProtoEvent] = []
    private var parsedSessionModel: String?
    private var parsedLastAgentMessage: String?
    private var parsedErrorMessage: String?
    private var sawTerminalEvent = false
    private let onEvent: ((ProtoEvent) -> Void)?

    init(onEvent: ((ProtoEvent) -> Void)?) {
        self.onEvent = onEvent
    }

    var stdoutText: String {
        lock.lock()
        let current = output
        lock.unlock()
        return current
    }

    var events: [ProtoEvent] {
        lock.lock()
        let current = parsedEvents
        lock.unlock()
        return current
    }

    var sessionModel: String? {
        lock.lock()
        let current = parsedSessionModel
        lock.unlock()
        return current
    }

    var lastAgentMessage: String? {
        lock.lock()
        let current = parsedLastAgentMessage
        lock.unlock()
        return current
    }

    var errorMessage: String? {
        lock.lock()
        let current = parsedErrorMessage
        lock.unlock()
        return current
    }

    var hasTerminalEvent: Bool {
        lock.lock()
        let current = sawTerminalEvent
        lock.unlock()
        return current
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(...newlineIndex)

            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }
            output.append(line)
            output.append("\n")
            parseLineLocked(line)
        }

        lock.unlock()
    }

    private func parseLineLocked(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = object["msg"] as? [String: Any],
              let type = msg["type"] as? String else {
            return
        }

        let id = (object["id"] as? String) ?? ""
        let event = ProtoEvent(id: id, type: type, payload: msg)
        parsedEvents.append(event)

        if type == "session_configured", let model = msg["model"] as? String {
            parsedSessionModel = model
        }
        if type == "agent_message", let message = msg["message"] as? String {
            parsedLastAgentMessage = message
        }
        if type == "task_complete", let message = msg["last_agent_message"] as? String {
            parsedLastAgentMessage = message
        }
        if (type == "error" || type == "stream_error"), let message = msg["message"] as? String {
            parsedErrorMessage = message
        }
        if type == "task_complete" || type == "error" {
            sawTerminalEvent = true
        }

        onEvent?(event)
    }
}
