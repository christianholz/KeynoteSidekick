import Foundation

enum LLMPlannerError: LocalizedError {
    case requestFailed(String)
    case missingOutputText
    case invalidJSONPayload(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return "LLM request failed: \(message)"
        case .missingOutputText:
            return "LLM response did not contain output text"
        case .invalidJSONPayload(let message):
            return "LLM output was not valid plan JSON: \(message)"
        }
    }
}

enum PlanStatus: String {
    case `continue`
    case complete
}

struct LLMPlan {
    let assistantReply: String
    let status: PlanStatus
    let operations: [[String: Any]]
    let completionCheck: PlanCompletionCheck?
    let codexRequest: String
    let codexResponseRaw: String
}

struct PlanCompletionCheck {
    let notes: String
    let targetSlideKeys: [String]
}

private let planningProtocolVersion = "1.0"
private let planningRequestType = "keynote_sidekick_planning_request"
private let planningResponseType = "keynote_sidekick_planning_response"

final class LLMPlanner: @unchecked Sendable {
    func generatePlan(
        objective: String,
        settings: LLMSettingsSnapshot,
        presentationContext: String,
        domSnapshot: PresentationDOMSnapshot,
        focusContext: PresentationFocusContext,
        contextMode: ContextDetailLevel,
        knownSlideBindings: [String: Int],
        workingSlideKey: String?,
        cycle: Int,
        executionFeedback: String?,
        onPreparedRequest: ((String) -> Void)? = nil,
        onCodexEvent: ((String) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) throws -> LLMPlan {
        let persistentPrompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingSlideText = workingSlideKey ?? "none"
        let feedbackText = (executionFeedback?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? executionFeedback!
            : "none"
        let envelope = requestEnvelope(
            objective: objective,
            contextMode: contextMode,
            presentationContext: presentationContext,
            domSnapshot: domSnapshot,
            focusContext: focusContext,
            knownSlideBindings: knownSlideBindings,
            workingSlideKey: workingSlideText,
            cycle: cycle,
            persistentPrompt: persistentPrompt,
            executionFeedback: feedbackText
        )
        let requestJSON = prettyJSONString(from: envelope)

        var requestLogChunks: [String] = []
        var responseLogChunks: [String] = []

        let planningPrompt = planningPrompt(with: requestJSON)
        onPreparedRequest?(planningPrompt)
        requestLogChunks.append("planning:\n\(planningPrompt)")

        let firstRaw = try runCodex(
            prompt: planningPrompt,
            settings: settings,
            onCodexEvent: onCodexEvent,
            shouldCancel: shouldCancel
        )
        responseLogChunks.append("planning:\n\(firstRaw)")

        let decoded: [String: Any]
        do {
            decoded = try decodeResponsePayload(from: firstRaw)
        } catch let error as LLMPlannerError {
            guard case .invalidJSONPayload = error else { throw error }

            let repairPrompt = repairPrompt(
                requestJSON: requestJSON,
                invalidResponse: firstRaw
            )
            onPreparedRequest?(repairPrompt)
            requestLogChunks.append("repair:\n\(repairPrompt)")
            let repairedRaw = try runCodex(
                prompt: repairPrompt,
                settings: settings,
                onCodexEvent: onCodexEvent,
                shouldCancel: shouldCancel
            )
            responseLogChunks.append("repair:\n\(repairedRaw)")
            decoded = try decodeResponsePayload(from: repairedRaw)
        }

        let assistantReply = (decoded["assistantReply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Done."

        let statusRaw = (decoded["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "continue"
        let status = PlanStatus(rawValue: statusRaw) ?? .continue
        let completionCheck = decodeCompletionCheck(from: decoded["completionCheck"])

        guard let operationsAny = decoded["operations"] as? [Any] else {
            if status == .complete {
                return LLMPlan(
                    assistantReply: assistantReply,
                    status: status,
                    operations: [],
                    completionCheck: completionCheck,
                    codexRequest: requestLogChunks.joined(separator: "\n\n"),
                    codexResponseRaw: responseLogChunks.joined(separator: "\n\n")
                )
            }
            throw LLMPlannerError.invalidJSONPayload("missing operations array")
        }

        let operations: [[String: Any]] = operationsAny.compactMap { $0 as? [String: Any] }
        if status == .continue && operations.isEmpty {
            throw LLMPlannerError.invalidJSONPayload("operations array is empty")
        }

        return LLMPlan(
            assistantReply: assistantReply,
            status: status,
            operations: operations,
            completionCheck: completionCheck,
            codexRequest: requestLogChunks.joined(separator: "\n\n"),
            codexResponseRaw: responseLogChunks.joined(separator: "\n\n")
        )
    }

    private func planningPrompt(with requestJSON: String) -> String {
        """
        You are a planning loop for KeynoteSidekick.
        The input is a JSON envelope. Parse it and return ONLY a JSON envelope with:
        {
          "protocolVersion": "\(planningProtocolVersion)",
          "type": "\(planningResponseType)",
          "payload": {
            "status": "continue" | "complete",
            "assistantReply": "short user-facing summary",
            "operations": [
              {"op":"...","target":{},"args":{},"verify":{}}
            ],
            "completionCheck": {"notes": "...", "targetSlideKeys": ["..."]}
          }
        }
        If objective is complete, return payload.status="complete" and payload.operations=[].
        No markdown. No extra text.
        On cycle > 1 after successful execution feedback, return status="complete" unless there is a specific unmet objective.
        Do not expand scope beyond the user objective. Do not invent extra examples/slides.
        If the objective asks to add/insert/preface slides, include explicit structural operations (`ensureSlide` and/or `moveSlide`) instead of text-only edits.
        Keep plans minimal: avoid redundant operations, and prefer `ensureSlide.args.title` over a separate title `ensureTextBox` when creating a slide.

        \(requestJSON)
        """
    }

    private func decodeCompletionCheck(from raw: Any?) -> PlanCompletionCheck? {
        guard let rawObject = raw as? [String: Any] else { return nil }
        let notes = (rawObject["notes"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetSlideKeys = (rawObject["targetSlideKeys"] as? [Any] ?? [])
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if notes.isEmpty && targetSlideKeys.isEmpty {
            return nil
        }
        return PlanCompletionCheck(notes: notes, targetSlideKeys: targetSlideKeys)
    }

    private func repairPrompt(requestJSON: String, invalidResponse: String) -> String {
        """
        You are a strict JSON formatter.
        Convert the INVALID response below into a VALID envelope for KeynoteSidekick.
        Keep intent the same; do not add narrative text.
        Return ONLY JSON with exact top-level keys:
        - "protocolVersion": "\(planningProtocolVersion)"
        - "type": "\(planningResponseType)"
        - "payload": object containing:
          - "status": "continue" | "complete"
          - "assistantReply": string
          - "operations": array
          - optional "completionCheck": object

        Original request envelope:
        \(requestJSON)

        Invalid model response to repair:
        \(invalidResponse)
        """
    }

    private func runCodex(
        prompt: String,
        settings: LLMSettingsSnapshot,
        onCodexEvent: ((String) -> Void)?,
        shouldCancel: (() -> Bool)?
    ) throws -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let configuredModel = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = protoModelCandidates(configuredModel: configuredModel)
        var lastProtoError: String?

        for model in candidates {
            let protoResult: ProtoTurnResult
            do {
                onCodexEvent?("proto.user_turn start (model=\(model))")
                protoResult = try runProtoTurn(
                    prompt: prompt,
                    settings: settings,
                    cwd: cwd,
                    model: model,
                    onCodexEvent: onCodexEvent,
                    shouldCancel: shouldCancel
                )
            } catch let error as CodexCLIError {
                if case .cancelled = error {
                    throw error
                }
                lastProtoError = error.localizedDescription
                onCodexEvent?("proto transport failed: \(error.localizedDescription)")
                continue
            } catch let error as LLMPlannerError {
                if case .requestFailed(let message) = error,
                   message.lowercased().contains("timed out") {
                    throw error
                }
                lastProtoError = error.localizedDescription
                onCodexEvent?("proto transport failed: \(error.localizedDescription)")
                continue
            } catch {
                lastProtoError = error.localizedDescription
                onCodexEvent?("proto transport failed: \(error.localizedDescription)")
                continue
            }

            if let finalMessage = protoResult.lastAgentMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !finalMessage.isEmpty {
                return finalMessage
            }

            if let sessionModel = protoResult.sessionModel, sessionModel != model {
                onCodexEvent?("proto.session_model=\(sessionModel) requested=\(model)")
            }

            let detail = [protoResult.errorMessage ?? "", protoResult.stderr, protoResult.stdout]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if looksLikeModelAccessError(detail), model != candidates.last {
                onCodexEvent?("proto model unavailable: \(model)")
                lastProtoError = detail
                continue
            }

            if !detail.isEmpty {
                throw LLMPlannerError.requestFailed(detail)
            }
            throw LLMPlannerError.missingOutputText
        }

        if shouldCancel?() == true {
            throw CodexCLIError.cancelled
        }

        if let lastProtoError, !lastProtoError.isEmpty {
            onCodexEvent?("proto fallback to exec: \(lastProtoError)")
        } else {
            onCodexEvent?("proto fallback to exec")
        }

        return try runCodexViaExec(
            prompt: prompt,
            settings: settings,
            onCodexEvent: onCodexEvent,
            shouldCancel: shouldCancel
        )
    }

    private func runProtoTurn(
        prompt: String,
        settings: LLMSettingsSnapshot,
        cwd: String,
        model: String,
        onCodexEvent: ((String) -> Void)?,
        shouldCancel: (() -> Bool)?
    ) throws -> ProtoTurnResult {
        let progressFormatter = ProtoProgressFormatter(
            showRawReasoning: settings.showRawAgentReasoning
        )
        let maxTransportBudget: TimeInterval = 180
        let timeout = min(initialTimeout(for: prompt), maxTransportBudget)
        let retryTimeout = max(0, maxTransportBudget - timeout)

        let invoke: (TimeInterval) throws -> ProtoTurnResult = { turnTimeout in
            try CodexCLI.runProtoUserTurn(
                executableHint: settings.codexPath,
                prompt: prompt,
                model: model,
                effort: settings.reasoningEffort,
                hideAgentReasoning: settings.hideAgentReasoning,
                modelReasoningSummary: settings.modelReasoningSummary,
                showRawAgentReasoning: settings.showRawAgentReasoning,
                cwd: cwd,
                timeout: turnTimeout,
                shouldCancel: shouldCancel,
                onEvent: { event in
                    if let summary = progressFormatter.summary(for: event) {
                        onCodexEvent?(summary)
                    }
                },
                onHeartbeat: { elapsed in
                    onCodexEvent?(progressFormatter.heartbeatSummary(elapsed: elapsed))
                }
            )
        }

        do {
            return try invoke(timeout)
        } catch let error as CodexCLIError {
            guard case .timedOut = error else { throw error }
            guard retryTimeout >= 15 else {
                throw LLMPlannerError.requestFailed("Codex request timed out after \(Int(timeout))s.")
            }
            onCodexEvent?("proto timeout after \(Int(timeout))s; retrying same model with \(Int(retryTimeout))s timeout")
            do {
                return try invoke(retryTimeout)
            } catch let retryError as CodexCLIError {
                guard case .timedOut = retryError else { throw retryError }
                throw LLMPlannerError.requestFailed(
                    "Codex request timed out after \(Int(timeout + retryTimeout))s total."
                )
            }
        }
    }

    private func runCodexViaExec(
        prompt: String,
        settings: LLMSettingsSnapshot,
        onCodexEvent: ((String) -> Void)?,
        shouldCancel: (() -> Bool)?
    ) throws -> String {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keynote-sidekick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("last-message.json")

        var args: [String] = [
            "exec",
            "--skip-git-repo-check",
            "--output-last-message", outputURL.path
        ]
        let configuredModel = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredModel.isEmpty {
            args.append(contentsOf: ["-m", configuredModel])
        }
        args.append(prompt)

        onCodexEvent?("exec fallback start")
        let result = try runWithTimeoutRetry(
            executableHint: settings.codexPath,
            arguments: args,
            prompt: prompt,
            shouldCancel: shouldCancel
        )

        let outputText = try? String(contentsOf: outputURL, encoding: .utf8)
        let rawOutput = outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawOutput.isEmpty {
            let detail = [result.stderr, result.stdout]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !detail.isEmpty {
                throw LLMPlannerError.requestFailed(detail)
            }
            if result.exitCode != 0 {
                throw LLMPlannerError.requestFailed("Codex exited with code \(result.exitCode).")
            }
            throw LLMPlannerError.missingOutputText
        }
        return rawOutput
    }

    private func protoModelCandidates(configuredModel: String) -> [String] {
        let cleaned = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return CodexCLI.preferredModelCandidates
        }
        return [cleaned]
    }

    private func runWithTimeoutRetry(
        executableHint: String,
        arguments: [String],
        prompt: String,
        shouldCancel: (() -> Bool)?
    ) throws -> ProcessResult {
        let maxTransportBudget: TimeInterval = 180
        let primaryTimeout = min(initialTimeout(for: prompt), maxTransportBudget)
        let retryTimeout = max(0, maxTransportBudget - primaryTimeout)
        do {
            return try CodexCLI.run(
                executableHint: executableHint,
                arguments: arguments,
                timeout: primaryTimeout,
                shouldCancel: shouldCancel
            )
        } catch let error as CodexCLIError {
            guard case .timedOut = error else { throw error }
            guard retryTimeout >= 15 else {
                throw LLMPlannerError.requestFailed("Codex request timed out after \(Int(primaryTimeout))s.")
            }
            do {
                return try CodexCLI.run(
                    executableHint: executableHint,
                    arguments: arguments,
                    timeout: retryTimeout,
                    shouldCancel: shouldCancel
                )
            } catch let retryError as CodexCLIError {
                guard case .timedOut = retryError else { throw retryError }
                throw LLMPlannerError.requestFailed(
                    "Codex request timed out after \(Int(primaryTimeout + retryTimeout))s total."
                )
            }
        }
    }

    private func initialTimeout(for prompt: String) -> TimeInterval {
        let size = prompt.utf8.count
        if size > 45_000 {
            return 300
        }
        if size > 25_000 {
            return 210
        }
        if size > 12_000 {
            return 150
        }
        return 120
    }

    private func looksLikeModelAccessError(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("does not exist or you do not have access") ||
            (lowered.contains("model") && lowered.contains("does not exist")) ||
            lowered.contains("unknown model")
    }

    private func decodeResponsePayload(from raw: String) throws -> [String: Any] {
        if let decoded = try? parseJSONObject(raw) {
            return try unwrapStrictPayload(decoded)
        }

        if let fenced = extractFencedJSON(raw),
           let decoded = try? parseJSONObject(fenced) {
            return try unwrapStrictPayload(decoded)
        }

        if let braced = extractFirstJSONObject(raw),
           let decoded = try? parseJSONObject(braced) {
            return try unwrapStrictPayload(decoded)
        }

        throw LLMPlannerError.invalidJSONPayload("unable to parse JSON object from model output")
    }

    private func unwrapStrictPayload(_ decoded: [String: Any]) throws -> [String: Any] {
        guard let version = decoded["protocolVersion"] as? String, version == planningProtocolVersion else {
            throw LLMPlannerError.invalidJSONPayload("missing or invalid protocolVersion")
        }
        guard let type = decoded["type"] as? String, type == planningResponseType else {
            throw LLMPlannerError.invalidJSONPayload("missing or invalid response type")
        }
        guard let payload = decoded["payload"] as? [String: Any] else {
            throw LLMPlannerError.invalidJSONPayload("missing payload object")
        }
        return payload
    }

    private func requestEnvelope(
        objective: String,
        contextMode: ContextDetailLevel,
        presentationContext: String,
        domSnapshot: PresentationDOMSnapshot,
        focusContext: PresentationFocusContext,
        knownSlideBindings: [String: Int],
        workingSlideKey: String,
        cycle: Int,
        persistentPrompt: String,
        executionFeedback: String
    ) -> [String: Any] {
        [
            "protocolVersion": planningProtocolVersion,
            "type": planningRequestType,
            "payload": [
                "objective": objective,
                "cycle": cycle,
                "contextMode": contextMode.rawValue,
                "workingSlideKey": workingSlideKey,
                "knownSlideBindings": knownSlideBindings,
                "persistentSystemPrompt": persistentPrompt,
                "executionFeedback": executionFeedback,
                "activeSlide": [
                    "index": focusContext.currentSlideIndex as Any,
                    "title": focusContext.currentSlideTitle,
                    "slideKeyAlias": "current_slide"
                ],
                "selectedElements": focusContext.selectedItems.enumerated().map { offset, item in
                    [
                        "alias": "selected_\(offset + 1)",
                        "name": item.name,
                        "type": item.type,
                        "textSnippet": item.textSnippet
                    ]
                },
                "presentationDOM": domSnapshot.plannerPayload(),
                "presentationContext": presentationContext
            ],
            "rules": [
                "deterministicOnly": true,
                "idempotentEnsures": true,
                "supportedOps": [
                    "attachToFrontPresentation",
                    "transaction",
                    "assertState",
                    "resolveTarget",
                    "ensureSlide",
                    "duplicateSlide",
                    "deleteSlide",
                    "hideSlide",
                    "moveSlide",
                    "ensureTextBox",
                    "ensureBullets",
                    "ensureImage",
                    "ensureShape",
                    "deleteElement",
                    "setFrame",
                    "setOpacity",
                    "setZOrder",
                    "setPresenterNotes",
                    "setTextStyle",
                    "setParagraphStyle",
                    "setFillStyle",
                    "setStrokeStyle",
                    "alignElements",
                    "distributeElements",
                    "savePresentation"
                ],
                "layoutPreference": "Title & Bullets for content slides with bullets",
                "bulletTextRule": "Provide clean bullet item text without literal bullet symbols",
                "deicticReferenceRule": "When user says 'this slide', target slideKey 'current_slide'. When user says 'a slide after this', target slideKey 'slide_after_current' (or use ensureSlide.args.index = activeSlide.index + 1). When user refers to selected object, use payload.selectedElements.name, and if name is empty use payload.selectedElements.alias with useSelection=true.",
                "selectorRule": "For ambiguous targets, use resolveTarget with args.selector fields: role, type, textEquals, textContains, textPrefix, index, isSelected, boundsNear. For element resolution, include target.elementName and reuse it in follow-up ops. For slide resolution, set selector.type='slide' and use target.slideKey alias in follow-up ops.",
                "domHandleRule": "Prefer payload.presentationDOM canonical handles: slideKey for slides, and role-backed element handles (title/body/text) when available. If title text is ambiguous across slides, include selector.index or exact slideKey from presentationDOM instead of fuzzy title matching.",
                "intentCompilerRule": "Model output is intent-level. A local compiler will resolve handles and reject unsafe or ambiguous operations. Keep intent minimal, explicit, and bounded to objective.",
                "strictContractRule": "Use only canonical fields. Put slideKey/elementName in target, never in args. For text roles use args.role ('title'|'body') or args.selector.role. Do not use non-canonical keys like kind, textType, existingSlideKey, slideTitleEquals. resolveTarget for slides does not require target.elementName.",
                "destructiveSafetyRule": "Before deleteSlide/deleteElement, include assertState for the same target.",
                "selectionGroupRule": "If user says 'align them' or refers to selected items, use alignElements/distributeElements with args.useSelection=true or explicit target.elementNames from payload.selectedElements.",
                "avoidDuplicateSlides": true
            ]
        ]
    }

    private func prettyJSONString(from object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func parseJSONObject(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMPlannerError.invalidJSONPayload("text is not a JSON object")
        }
        return json
    }

    private func extractFencedJSON(_ text: String) -> String? {
        let pattern = "```(?:json)?\\s*([\\s\\S]*?)\\s*```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[capture])
    }

    private func extractFirstJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
    }
}

private final class ProtoProgressFormatter {
    private let showRawReasoning: Bool
    private var lastInputTokens: Int?
    private var lastOutputTokens: Int?
    private var taskStartedAt: Date?
    private var lastUsageAt: Date?
    private var seenUnhandledEventTypes: Set<String> = []

    init(showRawReasoning: Bool = false) {
        self.showRawReasoning = showRawReasoning
    }

    func summary(for event: ProtoEvent) -> String? {
        switch event.type {
        case "task_started":
            taskStartedAt = Date()
            lastUsageAt = nil
            lastInputTokens = nil
            lastOutputTokens = nil
            return "proto.task_started"
        case "session_configured":
            if let model = event.payload["model"] as? String, !model.isEmpty {
                return "proto.session_configured model=\(model)"
            }
            return "proto.session_configured"
        case "stream_error":
            if let message = event.payload["message"] as? String {
                return "proto.stream_error: \(message)"
            }
            return "proto.stream_error"
        case "error":
            if let message = event.payload["message"] as? String {
                return "proto.error: \(message)"
            }
            return "proto.error"
        case "agent_message":
            return "proto.agent_message received (finalizing)"
        case "agent_reasoning", "agent_reasoning_delta":
            guard showRawReasoning else { return nil }
            if let text = extractReasoningText(from: event.payload), !text.isEmpty {
                return "proto.\(event.type): \(text)"
            }
            return "proto.\(event.type)"
        case "token_count":
            let input = intValue(event.payload["input_tokens"])
            let output = intValue(event.payload["output_tokens"])
            let inputDelta = delta(current: input, previous: lastInputTokens)
            let outputDelta = delta(current: output, previous: lastOutputTokens)
            let inputDeltaText = inputDelta.map { signed($0) } ?? "n/a"
            let outputDeltaText = outputDelta.map { signed($0) } ?? "n/a"

            var detail = "proto.usage cumulative in=\(input) (\(inputDeltaText)) out=\(output) (\(outputDeltaText))"
            if let previousInput = lastInputTokens,
               let previousOutput = lastOutputTokens,
               input > previousInput,
               output < previousOutput {
                detail += " [internal retry/replan pass]"
            }

            lastUsageAt = Date()
            lastInputTokens = input
            lastOutputTokens = output
            return detail
        case "task_complete":
            return "proto.task_complete (response ready)"
        default:
            if seenUnhandledEventTypes.insert(event.type).inserted {
                return "proto.event \(event.type)"
            }
            return nil
        }
    }

    func heartbeatSummary(elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        guard taskStartedAt != nil else {
            return "proto.heartbeat \(seconds)s waiting (starting)"
        }
        guard let lastUsageAt else {
            return "proto.heartbeat \(seconds)s waiting (connected, no token telemetry yet)"
        }
        let idleSeconds = Int(Date().timeIntervalSince(lastUsageAt))
        return "proto.heartbeat \(seconds)s waiting (last usage update \(idleSeconds)s ago)"
    }

    private func intValue(_ any: Any?) -> Int {
        if let value = any as? Int {
            return value
        }
        if let number = any as? NSNumber {
            return number.intValue
        }
        return -1
    }

    private func delta(current: Int, previous: Int?) -> Int? {
        guard let previous else { return nil }
        return current - previous
    }

    private func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value)" : "\(value)"
    }

    private func extractReasoningText(from payload: [String: Any]) -> String? {
        let keys = ["text", "delta", "content", "message"]
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            if let nested = payload[key] as? [String: Any] {
                if let nestedText = extractReasoningText(from: nested), !nestedText.isEmpty {
                    return nestedText
                }
            }
            if let list = payload[key] as? [Any] {
                for item in list {
                    if let nested = item as? [String: Any],
                       let nestedText = extractReasoningText(from: nested),
                       !nestedText.isEmpty {
                        return nestedText
                    }
                    if let value = item as? String {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }
            }
        }
        return nil
    }
}
