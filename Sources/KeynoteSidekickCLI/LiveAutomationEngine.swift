import Foundation
import KeynoteSidekickCore
import KeynoteSidekickAdapters

struct AutomationOutcome {
    let success: Bool
    let cancelled: Bool
    let reply: String
    let progress: [String]
}

private enum FailureSource: String {
    case codex
    case keynote_script
    case keynotesidekick
    case unknown
}

private enum FailureStage: String {
    case context_collection
    case codex_planning
    case execution
}

private struct FailureClassification {
    let source: FailureSource
    let stage: FailureStage
    let code: String
    let message: String
    let retryWithCodex: Bool
}

final class LiveAutomationEngine: @unchecked Sendable {
    private let adapter: KeynoteAutomationAdapter
    private let fallback: AXFallbackAdapter
    private let planner: LLMPlanner
    private let contextCollector: PresentationContextCollector
    private let intentCompiler: IntentToOpCompiler
    private let runLogWriter: RunLogWriter

    private var connected = false
    private var currentSlideKey: String?
    private var slideSequence = 1
    private var elementSequence = 1
    private var opSequence = 1
    private let reflectionMaxIterations = 10

    init(
        adapter: KeynoteAutomationAdapter = AppleScriptKeynoteAdapter(),
        fallback: AXFallbackAdapter = SystemEventsAXFallbackAdapter(),
        planner: LLMPlanner = LLMPlanner(),
        contextCollector: PresentationContextCollector = PresentationContextCollector(),
        intentCompiler: IntentToOpCompiler = IntentToOpCompiler(),
        runLogWriter: RunLogWriter = .shared
    ) {
        self.adapter = adapter
        self.fallback = fallback
        self.planner = planner
        self.contextCollector = contextCollector
        self.intentCompiler = intentCompiler
        self.runLogWriter = runLogWriter
    }

    func handle(
        input: String,
        settings: LLMSettingsSnapshot,
        shouldCancel: (() -> Bool)? = nil,
        onCodexActivity: ((Bool) -> Void)? = nil,
        onProgress: ((String) -> Void)? = nil
    ) -> AutomationOutcome {
        if settings.reflectionBasedEditsEnabled {
            return handleWithReflection(
                input: input,
                settings: settings,
                shouldCancel: shouldCancel,
                onCodexActivity: onCodexActivity,
                onProgress: onProgress
            )
        }
        return handlePrimary(
            input: input,
            settings: settings,
            shouldCancel: shouldCancel,
            onCodexActivity: onCodexActivity,
            onProgress: onProgress
        )
    }

    private func handlePrimary(
        input: String,
        settings: LLMSettingsSnapshot,
        shouldCancel: (() -> Bool)? = nil,
        onCodexActivity: ((Bool) -> Void)? = nil,
        onProgress: ((String) -> Void)? = nil
    ) -> AutomationOutcome {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return AutomationOutcome(success: false, cancelled: false, reply: "Please type a request.", progress: [])
        }
        let debugLoggingEnabled = settings.debugLoggingEnabled
        let diagnosticLoggingEnabled = debugLoggingEnabled || settings.reflectionBasedEditsEnabled

        var progress: [String] = []
        func note(_ line: String) {
            progress.append(line)
            onProgress?(line)
        }

        do {
            try ensureConnected(note: note)
            var plannerFeedback: String? = nil
            var lastFailure: String? = nil
            var lastFailureSignature: String? = nil
            var repeatedFailureCount = 0
            var cycle = 0
            let maxPlanningCycles = 8
            let maxContinueSuccessCycles = 3
            let objectiveSlideBudget = PlanningScopeGuard.explicitSlideBudget(objective: trimmed)
            let objectiveTouchedSlideBudget = PlanningScopeGuard.touchedSlideBudget(objective: trimmed)
            var recentPlanFingerprint: String?
            var repeatedFingerprintCount = 0
            var continueSuccessCount = 0
            var lockedSlideScope = Set<String>()
            var lastFailureContextSignature: String? = nil
            var stagnantFailureCount = 0
            var failureSequence = 0
            var cachedSnapshot: PresentationContextSnapshot?
            var cachedContextLevel: ContextDetailLevel?
            var reuseCachedContextNextCycle = false

            while true {
                if shouldCancel?() == true {
                    note("Run canceled by user.")
                    return AutomationOutcome(success: false, cancelled: true, reply: "Canceled by user.", progress: progress)
                }
                cycle += 1
                if cycle > maxPlanningCycles {
                    let halted = "Stopping run: reached planning cycle limit (\(maxPlanningCycles)) without completion."
                    note(halted)
                    return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                }

                let knownBindingsRaw = (try? adapter.knownSlideBindings()) ?? [:]
                var contextLevel = chooseContextLevel(
                    objective: trimmed,
                    cycle: cycle,
                    lastFailure: lastFailure,
                    repeatedFingerprintCount: repeatedFingerprintCount
                )
                if reuseCachedContextNextCycle, let cachedContextLevel {
                    contextLevel = cachedContextLevel
                }
                let snapshot: PresentationContextSnapshot
                if reuseCachedContextNextCycle,
                   let cachedSnapshot,
                   cachedContextLevel == contextLevel {
                    note("Reusing previous presentation context (no deck changes detected after planner-side failure).")
                    let refreshedFocus = (try? contextCollector.collectFocusContext()) ?? cachedSnapshot.focus
                    snapshot = PresentationContextSnapshot(
                        context: cachedSnapshot.context,
                        focus: refreshedFocus,
                        focusWarning: cachedSnapshot.focusWarning,
                        dom: cachedSnapshot.dom
                    )
                    reuseCachedContextNextCycle = false
                } else {
                    if contextLevel == .full {
                        note("Collecting full presentation context from Keynote...")
                    } else {
                        note("Collecting presentation context from Keynote...")
                    }
                    do {
                        snapshot = try contextCollector.collectSnapshot(level: contextLevel)
                        cachedSnapshot = snapshot
                        cachedContextLevel = contextLevel
                    } catch {
                        let classification = classifyFailure(error, stage: .context_collection)
                        failureSequence += 1
                        logFailure(
                            note: note,
                            id: failureId(cycle: cycle, sequence: failureSequence),
                            classification: classification
                        )

                        guard classification.retryWithCodex else {
                            throw error
                        }

                        if let cachedSnapshot {
                            note("Continuing with cached context because live Keynote collection failed.")
                            let refreshedFocus = (try? contextCollector.collectFocusContext()) ?? cachedSnapshot.focus
                            snapshot = PresentationContextSnapshot(
                                context: cachedSnapshot.context,
                                focus: refreshedFocus,
                                focusWarning: classification.message,
                                dom: cachedSnapshot.dom
                            )
                        } else {
                            note("Continuing with minimal context because live Keynote collection failed.")
                            snapshot = PresentationContextSnapshot(
                                context: "",
                                focus: .empty,
                                focusWarning: classification.message,
                                dom: .empty
                            )
                        }
                    }
                }
                let context = snapshot.context
                let focus = snapshot.focus
                let contextSlidesForBindings = contextSlides(from: snapshot.dom, fallbackContext: context)
                let knownBindings = sanitizeKnownBindings(
                    knownBindingsRaw,
                    contextSlides: contextSlidesForBindings
                )
                if intentCompiler.isObjectiveSatisfied(objective: trimmed, dom: snapshot.dom) {
                    note("Objective already satisfied from current deck state. No further edits needed.")
                    return AutomationOutcome(
                        success: true,
                        cancelled: false,
                        reply: "Already done.",
                        progress: progress
                    )
                }
                let contextSignature = failureContextSignature(context: context, focus: focus)
                if let focusWarning = snapshot.focusWarning, !focusWarning.isEmpty {
                    note("Focus context warning: \(focusWarning)")
                }
                note("Focus context:\n\(contextCollector.describeFocus(focus))")
                let plannerBindings = plannerBindingsForCodex(
                    baseBindings: knownBindings,
                    contextSlides: contextSlidesForBindings,
                    focus: focus
                )

                if let localPlan = intentCompiler.compileDirectIntent(
                    objective: trimmed,
                    dom: snapshot.dom
                ) {
                    note("Using DOM-driven local intent compiler path (\(localPlan.reason)).")
                    if diagnosticLoggingEnabled {
                        note("Plan sanitized:\n\(prettyJSON(from: localPlan.operations))")
                    }
                    let report = try execute(operations: localPlan.operations)
                    updateWorkingState(from: localPlan.operations)
                    for line in progressLines(from: report) {
                        note(line)
                    }
                    note("Execution complete.")
                    return AutomationOutcome(
                        success: true,
                        cancelled: false,
                        reply: localPlan.assistantReply,
                        progress: progress
                    )
                }

                let plan: LLMPlan
                note("Sending request to Codex...")
                onCodexActivity?(true)
                do {
                    plan = try planner.generatePlan(
                        objective: trimmed,
                        settings: settings,
                        presentationContext: context,
                        domSnapshot: snapshot.dom,
                        focusContext: focus,
                        contextMode: contextLevel,
                        knownSlideBindings: plannerBindings,
                        workingSlideKey: currentSlideKey,
                        cycle: cycle,
                        executionFeedback: plannerFeedback,
                        onPreparedRequest: { prompt in
                            guard diagnosticLoggingEnabled else { return }
                            note("Codex request:\n\(prompt)")
                        },
                        onCodexEvent: { event in
                            guard diagnosticLoggingEnabled else { return }
                            note("Codex event: \(event)")
                        },
                        shouldCancel: shouldCancel
                    )
                    onCodexActivity?(false)
                } catch {
                    onCodexActivity?(false)
                    let failureMessage = "Codex planning failed: \(error.localizedDescription)"
                    note("Execution failed: \(failureMessage)")
                    let classification = classifyFailure(error, stage: .codex_planning)
                    failureSequence += 1
                    logFailure(
                        note: note,
                        id: failureId(cycle: cycle, sequence: failureSequence),
                        classification: classification
                    )
                    let failureSignature = normalizeFailureSignature(failureMessage)
                    if lastFailureSignature == failureSignature {
                        repeatedFailureCount += 1
                    } else {
                        repeatedFailureCount = 1
                        lastFailureSignature = failureSignature
                    }
                    if repeatedFailureCount >= 3 {
                        let halted = "Stopping run: no forward progress after repeated planner failures."
                        note(halted)
                        return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                    }
                    if classification.source == .keynotesidekick {
                        let halted = "Stopping run due to KeynoteSidekick internal error. See FAILURE_JSON above."
                        note(halted)
                        return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                    }
                    lastFailure = failureMessage
                    reuseCachedContextNextCycle = true
                    plannerFeedback = buildPlannerFeedback(
                        objective: trimmed,
                        cycle: cycle,
                        operations: [],
                        errorMessage: failureMessage,
                        repeatedFingerprintCount: repeatedFingerprintCount,
                        knownSlideBindings: plannerBindings
                    )
                    note("Requesting corrective actions from Codex...")
                    continue
                }
                if diagnosticLoggingEnabled {
                    note("Codex response raw:\n\(plan.codexResponseRaw)")
                }
                note("Received plan status=\(plan.status.rawValue) with \(plan.operations.count) operation(s).")
                let opNames = plan.operations.compactMap { $0["op"] as? String }
                if !opNames.isEmpty {
                    note("Plan ops: \(opNames.joined(separator: ", "))")
                }
                if diagnosticLoggingEnabled {
                    let rawPlan: [String: Any] = [
                        "status": plan.status.rawValue,
                        "assistantReply": plan.assistantReply,
                        "operations": plan.operations
                    ]
                    note("Plan raw:\n\(prettyJSON(from: rawPlan))")
                }

                let protocolViolations = PlanProtocolGate.validate(operations: plan.operations)
                if !protocolViolations.isEmpty {
                    let failureMessage = "Protocol gate rejected plan: \(PlanProtocolGate.summarize(protocolViolations))"
                    note("Execution failed: \(failureMessage)")
                    let classification = FailureClassification(
                        source: .keynotesidekick,
                        stage: .codex_planning,
                        code: "PROTOCOL_CONTRACT_VIOLATION",
                        message: failureMessage,
                        retryWithCodex: true
                    )
                    failureSequence += 1
                    logFailure(
                        note: note,
                        id: failureId(cycle: cycle, sequence: failureSequence),
                        classification: classification
                    )
                    lastFailure = failureMessage
                    updateStagnation(
                        contextSignature: contextSignature,
                        lastSignature: &lastFailureContextSignature,
                        count: &stagnantFailureCount
                    )
                    if stagnantFailureCount >= 3 {
                        let halted = "Stopping run: no forward progress (planner keeps violating protocol contract)."
                        note(halted)
                        return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                    }
                    reuseCachedContextNextCycle = true
                    plannerFeedback = buildProtocolGateFeedback(
                        objective: trimmed,
                        cycle: cycle,
                        operations: plan.operations,
                        violations: protocolViolations,
                        knownSlideBindings: plannerBindings
                    )
                    note("Requesting corrective actions from Codex...")
                    continue
                }

                let compiledIntent = intentCompiler.compile(
                    operations: plan.operations,
                    objective: trimmed,
                    dom: snapshot.dom,
                    knownBindings: plannerBindings,
                    focus: focus,
                    workingSlideKey: currentSlideKey
                )
                let droppedDestructiveOps = droppedDestructiveOps(from: compiledIntent.diagnostics)
                if !droppedDestructiveOps.isEmpty, objectiveRequestsDestructiveChange(trimmed) {
                    let droppedSummary = droppedDestructiveOps.sorted().joined(separator: ", ")
                    let message = "Destructive edits were requested but not confirmed (\(droppedSummary)). Re-run with explicit confirmation, for example: \"confirm delete all slides, then ...\"."
                    note("Execution failed: \(message)")
                    return AutomationOutcome(success: false, cancelled: false, reply: message, progress: progress)
                }
                if diagnosticLoggingEnabled, !compiledIntent.diagnostics.isEmpty {
                    note("Intent compiler diagnostics:\n\(compiledIntent.diagnostics.joined(separator: "\n"))")
                }

                let operations = sanitizeOperations(
                    compiledIntent.operations,
                    userInput: trimmed,
                    presentationContext: context,
                    domSnapshot: snapshot.dom,
                    knownBindings: plannerBindings,
                    selectedItems: focus.selectedItems
                )
                if diagnosticLoggingEnabled {
                    note("Plan sanitized:\n\(prettyJSON(from: operations))")
                }

                if let objectiveTouchedSlideBudget {
                    let touchedSlides = extractSlideKeys(from: operations)
                    if touchedSlides.count > objectiveTouchedSlideBudget {
                        let sortedTouched = touchedSlides.sorted()
                        let failureMessage = "Scope gate rejected plan: touched \(touchedSlides.count) slide target(s), budget is \(objectiveTouchedSlideBudget)."
                        note("Execution failed: \(failureMessage)")
                        let classification = FailureClassification(
                            source: .keynotesidekick,
                            stage: .codex_planning,
                            code: "SCOPE_TOUCH_BUDGET_EXCEEDED",
                            message: failureMessage,
                            retryWithCodex: true
                        )
                        failureSequence += 1
                        logFailure(
                            note: note,
                            id: failureId(cycle: cycle, sequence: failureSequence),
                            classification: classification
                        )
                        lastFailure = failureMessage
                        updateStagnation(
                            contextSignature: contextSignature,
                            lastSignature: &lastFailureContextSignature,
                            count: &stagnantFailureCount
                        )
                        if stagnantFailureCount >= 3 {
                            let halted = "Stopping run: no forward progress (planner keeps exceeding touched-slide scope budget)."
                            note(halted)
                            return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                        }
                        reuseCachedContextNextCycle = true
                        plannerFeedback = buildScopeDriftFeedback(
                            objective: trimmed,
                            cycle: cycle,
                            operations: operations,
                            unexpectedSlideKeys: sortedTouched,
                            knownSlideBindings: plannerBindings,
                            objectiveSlideBudget: objectiveSlideBudget
                        )
                        note("Requesting corrective actions from Codex...")
                        continue
                    }
                }

                if lockedSlideScope.isEmpty, let objectiveSlideBudget {
                    let newSlideCreates = PlanningScopeGuard.newSlideCreateTargets(
                        operations: operations,
                        knownBindings: plannerBindings
                    )
                    if newSlideCreates.count > objectiveSlideBudget {
                        let failureMessage = "Scope gate rejected plan: requested \(objectiveSlideBudget) new slide(s), plan attempts \(newSlideCreates.count) (\(newSlideCreates.sorted().joined(separator: ", ")))."
                        note("Execution failed: \(failureMessage)")
                        let classification = FailureClassification(
                            source: .keynotesidekick,
                            stage: .codex_planning,
                            code: "SCOPE_BUDGET_EXCEEDED",
                            message: failureMessage,
                            retryWithCodex: true
                        )
                        failureSequence += 1
                        logFailure(
                            note: note,
                            id: failureId(cycle: cycle, sequence: failureSequence),
                            classification: classification
                        )
                        lastFailure = failureMessage
                        updateStagnation(
                            contextSignature: contextSignature,
                            lastSignature: &lastFailureContextSignature,
                            count: &stagnantFailureCount
                        )
                        if stagnantFailureCount >= 3 {
                            let halted = "Stopping run: no forward progress (planner keeps exceeding objective slide budget)."
                            note(halted)
                            return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                        }
                        reuseCachedContextNextCycle = true
                        plannerFeedback = buildScopeDriftFeedback(
                            objective: trimmed,
                            cycle: cycle,
                            operations: operations,
                            unexpectedSlideKeys: newSlideCreates.sorted(),
                            knownSlideBindings: plannerBindings,
                            objectiveSlideBudget: objectiveSlideBudget
                        )
                        note("Requesting corrective actions from Codex...")
                        continue
                    }
                }

                let allowedSlideScope = lockedSlideScope.union(
                    PlanningScopeGuard.baseAllowedScope(
                        knownBindings: plannerBindings,
                        currentSlideKey: currentSlideKey
                    )
                )
                if !lockedSlideScope.isEmpty {
                    let unexpectedSlideTargets = PlanningScopeGuard.unexpectedSlideTargets(
                        operations: operations,
                        allowedScope: allowedSlideScope,
                        knownBindings: plannerBindings
                    )
                    if !unexpectedSlideTargets.isEmpty {
                        let sortedUnexpected = unexpectedSlideTargets.sorted()
                        let failureMessage = "Scope gate rejected plan: unexpected slide targets introduced (\(sortedUnexpected.joined(separator: ", ")))."
                        note("Execution failed: \(failureMessage)")
                        let classification = FailureClassification(
                            source: .keynotesidekick,
                            stage: .codex_planning,
                            code: "SCOPE_DRIFT",
                            message: failureMessage,
                            retryWithCodex: true
                        )
                        failureSequence += 1
                        logFailure(
                            note: note,
                            id: failureId(cycle: cycle, sequence: failureSequence),
                            classification: classification
                        )
                        lastFailure = failureMessage
                        updateStagnation(
                            contextSignature: contextSignature,
                            lastSignature: &lastFailureContextSignature,
                            count: &stagnantFailureCount
                        )
                        if stagnantFailureCount >= 3 {
                            let halted = "Stopping run: no forward progress (planner keeps drifting scope)."
                            note(halted)
                            return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                        }
                        reuseCachedContextNextCycle = true
                        plannerFeedback = buildScopeDriftFeedback(
                            objective: trimmed,
                            cycle: cycle,
                            operations: operations,
                            unexpectedSlideKeys: sortedUnexpected,
                            knownSlideBindings: plannerBindings,
                            objectiveSlideBudget: objectiveSlideBudget
                        )
                        note("Requesting corrective actions from Codex...")
                        continue
                    }
                }

                let planFingerprint = fingerprint(operations: operations)
                if let recentPlanFingerprint, recentPlanFingerprint == planFingerprint {
                    repeatedFingerprintCount += 1
                } else {
                    repeatedFingerprintCount = 0
                }
                recentPlanFingerprint = planFingerprint

                if operations.isEmpty {
                    if plan.status == .complete {
                        note("Objective complete with no additional operations required.")
                        return AutomationOutcome(success: true, cancelled: false, reply: plan.assistantReply, progress: progress)
                    }
                    let failureMessage = "Plan produced no executable operations after sanitization."
                    note("Execution failed: \(failureMessage)")
                    failureSequence += 1
                    let classification = FailureClassification(
                        source: .codex,
                        stage: .codex_planning,
                        code: "EMPTY_PLAN",
                        message: failureMessage,
                        retryWithCodex: true
                    )
                    logFailure(
                        note: note,
                        id: failureId(cycle: cycle, sequence: failureSequence),
                        classification: classification
                    )
                    lastFailure = failureMessage
                    updateStagnation(
                        contextSignature: contextSignature,
                        lastSignature: &lastFailureContextSignature,
                        count: &stagnantFailureCount
                    )
                    if stagnantFailureCount >= 3 {
                        let halted = "Stopping run: no forward progress (deck context unchanged across repeated failures)."
                        note(halted)
                        return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                    }
                    reuseCachedContextNextCycle = true
                    plannerFeedback = buildPlannerFeedback(
                        objective: trimmed,
                        cycle: cycle,
                        operations: plan.operations,
                        errorMessage: failureMessage
                    )
                    note("Requesting corrective actions from Codex...")
                    continue
                }

                do {
                    let report = try execute(operations: operations)
                    updateWorkingState(from: operations)
                    let refreshedBindings = (try? adapter.knownSlideBindings()) ?? knownBindings
                    lockedSlideScope = PlanningScopeGuard.seedScope(
                        existing: lockedSlideScope,
                        operations: operations,
                        completionCheck: plan.completionCheck,
                        knownBindings: refreshedBindings,
                        currentSlideKey: currentSlideKey
                    )

                    for line in progressLines(from: report) {
                        note(line)
                    }
                    note("Execution complete.")
                    if plan.status == .continue {
                        if repeatedFingerprintCount >= 2 {
                            let halted = "Stopping run: repeated identical plan cycles without completion."
                            note(halted)
                            return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                        }
                        continueSuccessCount += 1
                        if continueSuccessCount >= maxContinueSuccessCycles {
                            let halted = "Stopping run: planner kept returning status=continue after \(continueSuccessCount) successful execution cycle(s)."
                            note(halted)
                            return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                        }
                        plannerFeedback = buildPlannerFeedback(
                            objective: trimmed,
                            cycle: cycle,
                            operations: operations,
                            report: report,
                            knownSlideBindings: refreshedBindings
                        )
                        lastFailure = nil
                        lastFailureSignature = nil
                        repeatedFailureCount = 0
                        stagnantFailureCount = 0
                        reuseCachedContextNextCycle = false
                        note("Objective not complete yet (status=continue). Requesting next steps from Codex...")
                        continue
                    }
                    continueSuccessCount = 0
                    return AutomationOutcome(success: true, cancelled: false, reply: plan.assistantReply, progress: progress)
                } catch {
                    let failureMessage = error.localizedDescription
                    note("Execution failed: \(failureMessage)")
                    let classification = classifyFailure(error, stage: .execution)
                    failureSequence += 1
                    logFailure(
                        note: note,
                        id: failureId(cycle: cycle, sequence: failureSequence),
                        classification: classification
                    )
                    let failureSignature = normalizeFailureSignature(failureMessage)
                    if lastFailureSignature == failureSignature {
                        repeatedFailureCount += 1
                    } else {
                        repeatedFailureCount = 1
                        lastFailureSignature = failureSignature
                    }
                    if repeatedFailureCount >= 3 {
                        let halted = "Stopping run: no forward progress after repeated execution failures. You can edit the deck manually or retry with a more specific request."
                        note(halted)
                        return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                    }
                    if classification.source == .keynotesidekick {
                        let halted = "Stopping run due to KeynoteSidekick internal error. See FAILURE_JSON above."
                        note(halted)
                        return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                    }
                    updateStagnation(
                        contextSignature: contextSignature,
                        lastSignature: &lastFailureContextSignature,
                        count: &stagnantFailureCount
                    )
                    if stagnantFailureCount >= 3 {
                        let halted = "Stopping run: no forward progress (deck context unchanged across repeated failures). You can retry with a more specific request."
                        note(halted)
                        return AutomationOutcome(success: false, cancelled: false, reply: halted, progress: progress)
                    }
                    reuseCachedContextNextCycle = false
                    lastFailure = failureMessage
                    plannerFeedback = buildPlannerFeedback(
                        objective: trimmed,
                        cycle: cycle,
                        operations: operations,
                        errorMessage: failureMessage,
                        repeatedFingerprintCount: repeatedFingerprintCount,
                        knownSlideBindings: plannerBindings
                    )
                    note("Requesting corrective actions from Codex...")
                }
            }
        } catch {
            onCodexActivity?(false)
            if isCancellation(error) || shouldCancel?() == true {
                note("Run canceled by user.")
                return AutomationOutcome(success: false, cancelled: true, reply: "Canceled by user.", progress: progress)
            }
            note("Execution failed: \(error.localizedDescription)")
            let classification = classifyFailure(error, stage: .execution)
            logFailure(
                note: note,
                id: "ERR-final",
                classification: classification
            )
            return AutomationOutcome(success: false, cancelled: false, reply: error.localizedDescription, progress: progress)
        }
    }

    private func handleWithReflection(
        input: String,
        settings: LLMSettingsSnapshot,
        shouldCancel: (() -> Bool)? = nil,
        onCodexActivity: ((Bool) -> Void)? = nil,
        onProgress: ((String) -> Void)? = nil
    ) -> AutomationOutcome {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return AutomationOutcome(success: false, cancelled: false, reply: "Please type a request.", progress: [])
        }

        let reflectionLog = runLogWriter.startReflectionRun(prompt: trimmed)
        var progress: [String] = []
        func note(_ line: String) {
            progress.append(line)
            onProgress?(line)
            runLogWriter.appendReflection(line, to: reflectionLog)
        }
        func detail(_ text: String) {
            runLogWriter.appendReflection(text, to: reflectionLog)
        }

        note("Reflection-based edits enabled.")
        let beforeSnapshot = collectSnapshotForReflection(label: "before edits", note: note)
        if let beforeSnapshot {
            detail("STATE BEFORE:\n\(stateDigest(beforeSnapshot))")
        }

        let primary = handlePrimary(
            input: trimmed,
            settings: settings,
            shouldCancel: shouldCancel,
            onCodexActivity: onCodexActivity,
            onProgress: note
        )
        var finalOutcome = AutomationOutcome(
            success: primary.success,
            cancelled: primary.cancelled,
            reply: primary.reply,
            progress: progress
        )

        if !primary.success,
           primary.reply.lowercased().contains("explicit confirmation") {
            let keptPath = runLogWriter.finishReflectionRun(reflectionLog, retain: true)
            if let keptPath {
                note("Reflection run log retained: \(keptPath)")
            }
            return finalOutcome
        }

        var keepReflectionLog = true
        var repairsApplied = 0
        var reflectionConfirmed = false
        var lastStateFingerprint: String?
        var repeatedStateCount = 0
        var lastOpFingerprint: String?
        var repeatedOpCount = 0

        if primary.cancelled || shouldCancel?() == true {
            let keptPath = runLogWriter.finishReflectionRun(reflectionLog, retain: true)
            if let keptPath {
                note("Reflection run log retained: \(keptPath)")
            }
            return AutomationOutcome(
                success: false,
                cancelled: true,
                reply: "Canceled by user.",
                progress: progress
            )
        }

        for iteration in 1...reflectionMaxIterations {
            if shouldCancel?() == true {
                let keptPath = runLogWriter.finishReflectionRun(reflectionLog, retain: true)
                if let keptPath {
                    note("Reflection run log retained: \(keptPath)")
                }
                return AutomationOutcome(
                    success: false,
                    cancelled: true,
                    reply: "Canceled by user.",
                    progress: progress
                )
            }

            guard let afterSnapshot = collectSnapshotForReflection(label: "after iteration \(iteration)", note: note) else {
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: "Reflection failed: could not collect post-edit deck state.",
                    progress: progress
                )
                break
            }
            detail("STATE AFTER ITERATION \(iteration):\n\(stateDigest(afterSnapshot))")
            let currentStateFingerprint = reflectionStateFingerprint(afterSnapshot)
            if let lastStateFingerprint, lastStateFingerprint == currentStateFingerprint {
                repeatedStateCount += 1
            } else {
                repeatedStateCount = 0
                lastStateFingerprint = currentStateFingerprint
            }
            if repeatedStateCount >= 2 {
                let halted = "Stopping reflection: no forward progress (deck state unchanged across repeated reflection cycles)."
                note(halted)
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: halted,
                    progress: progress
                )
                break
            }

            let knownBindingsRaw = (try? adapter.knownSlideBindings()) ?? [:]
            let plannerBindings = plannerBindingsForReflection(snapshot: afterSnapshot, rawBindings: knownBindingsRaw)
            let reflectionFeedback = buildReflectionFeedback(
                objective: trimmed,
                iteration: iteration,
                repairsApplied: repairsApplied,
                primaryOutcome: primary,
                beforeSnapshot: beforeSnapshot,
                afterSnapshot: afterSnapshot
            )
            detail("REFLECTION FEEDBACK ITERATION \(iteration):\n\(reflectionFeedback)")

            note("Reflection iteration \(iteration)/\(reflectionMaxIterations): verifying deck outcome with Codex...")

            let reflectionPlan: LLMPlan
            onCodexActivity?(true)
            do {
                reflectionPlan = try planner.generatePlan(
                    objective: reflectionObjective(for: trimmed, iteration: iteration),
                    settings: settings,
                    presentationContext: afterSnapshot.context,
                    domSnapshot: afterSnapshot.dom,
                    focusContext: afterSnapshot.focus,
                    contextMode: .full,
                    knownSlideBindings: plannerBindings,
                    workingSlideKey: currentSlideKey,
                    cycle: iteration,
                    executionFeedback: reflectionFeedback,
                    onPreparedRequest: { prompt in
                        note("Codex request:\n\(prompt)")
                    },
                    onCodexEvent: { event in
                        note("Codex event: \(event)")
                    },
                    shouldCancel: shouldCancel
                )
                onCodexActivity?(false)
            } catch {
                onCodexActivity?(false)
                note("Reflection planning failed: \(error.localizedDescription)")
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: "Reflection failed: \(error.localizedDescription)",
                    progress: progress
                )
                break
            }

            note("Reflection plan status=\(reflectionPlan.status.rawValue) with \(reflectionPlan.operations.count) operation(s).")
            let reflectionOpNames = reflectionPlan.operations.compactMap { $0["op"] as? String }
            if !reflectionOpNames.isEmpty {
                note("Reflection plan ops: \(reflectionOpNames.joined(separator: ", "))")
            }
            note("Codex response raw:\n\(reflectionPlan.codexResponseRaw)")

            let protocolViolations = PlanProtocolGate.validate(operations: reflectionPlan.operations)
            if !protocolViolations.isEmpty {
                let message = "Reflection protocol gate rejected plan: \(PlanProtocolGate.summarize(protocolViolations))"
                note(message)
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: message,
                    progress: progress
                )
                break
            }

            let compiledIntent = intentCompiler.compile(
                operations: reflectionPlan.operations,
                objective: trimmed,
                dom: afterSnapshot.dom,
                knownBindings: plannerBindings,
                focus: afterSnapshot.focus,
                workingSlideKey: currentSlideKey
            )
            let operations = sanitizeOperations(
                compiledIntent.operations,
                userInput: trimmed,
                presentationContext: afterSnapshot.context,
                domSnapshot: afterSnapshot.dom,
                knownBindings: plannerBindings,
                selectedItems: afterSnapshot.focus.selectedItems
            )
            note("Plan sanitized:\n\(prettyJSON(from: operations))")
            let currentOpFingerprint = reflectionOperationsFingerprint(operations)
            if let lastOpFingerprint, lastOpFingerprint == currentOpFingerprint {
                repeatedOpCount += 1
            } else {
                repeatedOpCount = 0
                lastOpFingerprint = currentOpFingerprint
            }
            if repeatedOpCount >= 2 {
                let halted = "Stopping reflection: no forward progress (same repair plan repeated)."
                note(halted)
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: halted,
                    progress: progress
                )
                break
            }

            if operations.isEmpty {
                if reflectionPlan.status == .complete {
                    reflectionConfirmed = true
                    if !primary.success {
                        finalOutcome = AutomationOutcome(
                            success: true,
                            cancelled: false,
                            reply: reflectionPlan.assistantReply,
                            progress: progress
                        )
                    }
                    note("Reflection confirmed objective is satisfied.")
                    break
                }
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: "Reflection could not produce actionable repair operations.",
                    progress: progress
                )
                break
            }
            if iteration == reflectionMaxIterations {
                let halted = "Stopping reflection: reached max iterations (\(reflectionMaxIterations)) before a clean verification pass."
                note(halted)
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: halted,
                    progress: progress
                )
                break
            }

            do {
                let report = try execute(operations: operations)
                updateWorkingState(from: operations)
                for line in progressLines(from: report) {
                    note("Reflection \(line)")
                }
                repairsApplied += 1
                finalOutcome = AutomationOutcome(
                    success: true,
                    cancelled: false,
                    reply: reflectionPlan.assistantReply,
                    progress: progress
                )
            } catch {
                note("Reflection execution failed: \(error.localizedDescription)")
                finalOutcome = AutomationOutcome(
                    success: false,
                    cancelled: false,
                    reply: "Reflection repair failed: \(error.localizedDescription)",
                    progress: progress
                )
                break
            }
        }

        if reflectionConfirmed && repairsApplied == 0 && primary.success {
            keepReflectionLog = false
        }
        let keptPath = runLogWriter.finishReflectionRun(reflectionLog, retain: keepReflectionLog)
        if let keptPath {
            note("Reflection run log retained: \(keptPath)")
        }

        return AutomationOutcome(
            success: finalOutcome.success,
            cancelled: finalOutcome.cancelled,
            reply: finalOutcome.reply,
            progress: progress
        )
    }

    private func collectSnapshotForReflection(
        label: String,
        note: (String) -> Void
    ) -> PresentationContextSnapshot? {
        note("Capturing presentation state (\(label))...")
        do {
            return try contextCollector.collectSnapshot(level: .full)
        } catch {
            note("Reflection warning: could not capture \(label) state: \(error.localizedDescription)")
            return nil
        }
    }

    private func plannerBindingsForReflection(
        snapshot: PresentationContextSnapshot,
        rawBindings: [String: Int]
    ) -> [String: Int] {
        let contextSlidesForBindings = contextSlides(from: snapshot.dom, fallbackContext: snapshot.context)
        let sanitized = sanitizeKnownBindings(rawBindings, contextSlides: contextSlidesForBindings)
        return plannerBindingsForCodex(
            baseBindings: sanitized,
            contextSlides: contextSlidesForBindings,
            focus: snapshot.focus
        )
    }

    private func reflectionObjective(for objective: String, iteration: Int) -> String {
        """
        Reflection pass \(iteration) for the objective below.
        Determine if the CURRENT deck already satisfies it.
        If satisfied, return status="complete" and operations=[].
        If not satisfied, return minimal repair operations for the CURRENT deck only.
        Do not expand scope or invent extra content.

        User objective:
        \(objective)
        """
    }

    private func buildReflectionFeedback(
        objective: String,
        iteration: Int,
        repairsApplied: Int,
        primaryOutcome: AutomationOutcome,
        beforeSnapshot: PresentationContextSnapshot?,
        afterSnapshot: PresentationContextSnapshot
    ) -> String {
        let beforeDigest = beforeSnapshot.map(stateDigest) ?? "unavailable"
        let afterDigest = stateDigest(afterSnapshot)
        return """
        Reflection iteration: \(iteration)
        Repairs applied so far: \(repairsApplied)
        Primary outcome success: \(primaryOutcome.success)
        Primary outcome reply: \(primaryOutcome.reply)
        Objective: \(objective)
        BEFORE STATE:
        \(beforeDigest)
        CURRENT STATE:
        \(afterDigest)
        Decide if CURRENT STATE satisfies Objective. If not, propose minimal repair operations.
        """
    }

    private func stateDigest(_ snapshot: PresentationContextSnapshot) -> String {
        if snapshot.dom.slides.isEmpty {
            return snapshot.context.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = snapshot.dom.slides.map { slide in
            let title = truncateForDigest(slide.title, limit: 120)
            let body = truncateForDigest(slide.body, limit: 160)
            return "slide \(slide.index): title=\(title) | body=\(body)"
        }
        return lines.joined(separator: "\n")
    }

    private func truncateForDigest(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit, limit > 3 else { return cleaned }
        let end = cleaned.index(cleaned.startIndex, offsetBy: limit - 3)
        return String(cleaned[..<end]) + "..."
    }

    private func reflectionStateFingerprint(_ snapshot: PresentationContextSnapshot) -> String {
        if snapshot.dom.slides.isEmpty {
            return snapshot.context.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = snapshot.dom.slides.map { slide in
            [
                String(slide.index),
                slide.slideKey,
                slide.title,
                slide.body,
                slide.notes
            ].joined(separator: "|")
        }
        return parts.joined(separator: "||")
    }

    private func reflectionOperationsFingerprint(_ operations: [[String: Any]]) -> String {
        operations.map { raw in
            let op = (raw["op"] as? String) ?? "?"
            let target = prettyJSON(from: raw["target"] as? [String: Any] ?? [:])
            let args = prettyJSON(from: raw["args"] as? [String: Any] ?? [:])
            return "\(op)|\(target)|\(args)"
        }
        .joined(separator: "||")
    }

    private func isCancellation(_ error: Error) -> Bool {
        if let codexError = error as? CodexCLIError, case .cancelled = codexError {
            return true
        }
        return false
    }

    private func ensureConnected(note: (String) -> Void) throws {
        guard !connected else { return }

        note("Attaching to the front Keynote presentation...")
        let report = try execute(operations: [
            op(
                name: "attachToFrontPresentation",
                target: [:],
                args: [:],
                verify: ["presentationOpen": true]
            )
        ])
        connected = true
        for line in progressLines(from: report) {
            note(line)
        }
    }

    private func sanitizeOperations(
        _ operations: [[String: Any]],
        userInput: String,
        presentationContext: String = "",
        domSnapshot: PresentationDOMSnapshot = .empty,
        knownBindings: [String: Int] = [:],
        selectedItems: [PresentationSelectionItem] = [],
        depth: Int = 0
    ) -> [[String: Any]] {
        guard depth <= 2 else { return [] }

        var output: [[String: Any]] = []
        var aliasScopedSlideKeys: [String: String] = [:]
        var activeSlideAliasTargets: [String: String] = [:]
        var elementSlideBindings: [String: String] = [:]
        var slideKeyRewrites: [String: String] = [:]
        var insertedSlideAliasByIndex: [Int: String] = [:]
        var createdSlideAliases = Set<String>()
        var consumedEnsureSlideTitles = Set<String>()
        var plannedInsertions: [Int] = []
        var materializedSlideKeys = Set(knownBindings.keys)
        if let currentSlideKey {
            materializedSlideKeys.insert(currentSlideKey)
        }
        let allowSave = userRequestedSave(userInput)
        let allowFrameControl = userRequestedFrameControl(userInput)
        let insertionObjective = PlanningScopeGuard.explicitSlideBudget(objective: userInput) != nil
        let plannedTitleBySlideKey = plannedTitleHints(from: operations)
        let contextSlides = contextSlides(from: domSnapshot, fallbackContext: presentationContext)
        let maxContextSlideIndex = contextSlides.map(\.index).max() ?? 0
        let selectedNames = selectedItems
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let firstSelectedName = selectedNames.first
        let bulletSlideKeys = Set(
            operations.compactMap { raw -> String? in
                guard let opName = raw["op"] as? String,
                      opName == "ensureBullets",
                      let slideKey = ((raw["target"] as? [String: Any])?["slideKey"] as? String)
                        ?? ((raw["args"] as? [String: Any])?["slideKey"] as? String) else {
                    return nil
                }
                return slideKey
            }
        )

        for raw in operations {
            guard let rawOpName = raw["op"] as? String, !rawOpName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            var opName = normalizeOperationName(rawOpName)

            // Live sidecar mode is strictly "front presentation only".
            // Never allow planner-generated document open/switch operations.
            if opName == "openPresentation" {
                continue
            }

            if opName == "savePresentation" && !allowSave {
                continue
            }

            var target = raw["target"] as? [String: Any] ?? [:]
            var args = raw["args"] as? [String: Any] ?? [:]
            var verify = raw["verify"] as? [String: Any] ?? [:]
            var deferredOps: [[String: Any]] = []
            target = normalizeTargetShape(target)
            args = normalizeArgsShape(args)
            if opName == "moveBefore" || opName == "moveAfter" {
                if opName == "moveBefore" {
                    if args["beforeSlideKey"] == nil {
                        if let ref = args["slideKey"] ?? args["before"] ?? args["referenceSlideKey"] ?? target["beforeSlideKey"] ?? target["before"] {
                            args["beforeSlideKey"] = ref
                        }
                    }
                } else {
                    if args["afterSlideKey"] == nil {
                        if let ref = args["slideKey"] ?? args["after"] ?? args["referenceSlideKey"] ?? target["afterSlideKey"] ?? target["after"] {
                            args["afterSlideKey"] = ref
                        }
                    }
                }
                args.removeValue(forKey: "slideKey")
                args.removeValue(forKey: "referenceSlideKey")
                args.removeValue(forKey: "before")
                args.removeValue(forKey: "after")
                target.removeValue(forKey: "beforeSlideKey")
                target.removeValue(forKey: "afterSlideKey")
                target.removeValue(forKey: "before")
                target.removeValue(forKey: "after")
                opName = "moveSlide"
            }
            liftTargetFieldsFromArgs(target: &target, args: &args)
            let plannerOriginalSlideKey = (target["slideKey"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            normalizeLegacyPlannerShapes(
                opName: opName,
                target: &target,
                args: &args,
                verify: &verify,
                knownBindings: knownBindings
            )

            if target["slideKey"] == nil,
               let slideKeyAlias = target["slideKeyAlias"] as? String,
               let resolvedSlideKey = resolveSlideKeyAlias(slideKeyAlias, knownBindings: knownBindings) {
                target["slideKey"] = resolvedSlideKey
            }
            target.removeValue(forKey: "slideKeyAlias")

            if opName == "transaction",
               let nestedOps = extractNestedOperations(args["operations"]) {
                let nested = sanitizeOperations(
                    nestedOps,
                    userInput: userInput,
                    presentationContext: presentationContext,
                    domSnapshot: domSnapshot,
                    knownBindings: knownBindings,
                    selectedItems: selectedItems,
                    depth: depth + 1
                )
                args["operations"] = nested
            }

            if let rawSlideKey = target["slideKey"] as? String {
                target["slideKey"] = normalizeDeicticSlideKey(rawSlideKey)
            }
            if let rawSlideKey = target["slideKey"] as? String {
                target["slideKey"] = rewriteDeicticSlideKey(
                    opName: opName,
                    slideKey: rawSlideKey,
                    args: args,
                    aliasScopedSlideKeys: &aliasScopedSlideKeys,
                    activeSlideAliasTargets: &activeSlideAliasTargets
                )
            }
            if let rewrittenSlideKey = target["slideKey"] as? String {
                target["slideKey"] = canonicalSlideKeyForExecution(
                    opName: opName,
                    slideKey: rewrittenSlideKey,
                    knownBindings: knownBindings
                )
            }
            if let rewrittenSlideKey = target["slideKey"] as? String,
               let mappedSlideKey = slideKeyRewrites[rewrittenSlideKey] {
                target["slideKey"] = mappedSlideKey
            }
            if let concreteSlideKey = target["slideKey"] as? String {
                let normalizedConcrete = normalizeDeicticSlideKey(concreteSlideKey)
                let isKnownBoundSlide = knownBindings[concreteSlideKey] != nil || knownBindings[normalizedConcrete] != nil
                let allowRebase = isKnownBoundSlide &&
                    !createdSlideAliases.contains(concreteSlideKey) &&
                    !createdSlideAliases.contains(normalizedConcrete) &&
                    (slideIndexHint(from: concreteSlideKey).map { $0 <= maxContextSlideIndex } ?? false)
                target["slideKey"] = SlideKeyRebaser.rebaseIfNeeded(
                    opName: opName,
                    slideKey: concreteSlideKey,
                    args: args,
                    insertionIndices: plannedInsertions,
                    allowRebase: allowRebase
                )
            }
            let selectorAwareTarget = target

            var selector = extractSelector(target: target, args: args)
            selector = normalizeSelector(selector)
            let resolvesSlideTarget = isSlideResolveTarget(opName: opName, selector: selector)
            if (selector["isSelected"] as? Bool) == true,
               needsElementName(opName) && !resolvesSlideTarget,
               let firstSelectedName {
                target["elementName"] = firstSelectedName
                selector.removeValue(forKey: "isSelected")
            }
            target = removeSelectorFields(from: target, includeIndex: true)
            args = removeSelectorFields(from: args, includeIndex: false)

            if needsSlideKey(opName), target["slideKey"] == nil,
               let selectorIndex = positiveInt(from: selector["index"]),
               let insertedAlias = insertedSlideAliasByIndex[selectorIndex] {
                target["slideKey"] = insertedAlias
            }

            if opName == "ensureSlide",
               target["slideKey"] == nil,
               shouldTreatEnsureSlideAsCreateIntent(args: args) {
                let aliasSeed = textValue(from: args["title"]) ?? "inserted_slide"
                target["slideKey"] = nextSlideKey(fromTitle: aliasSeed)
            }

            if needsSlideKey(opName), target["slideKey"] == nil,
               let inferredSlideKey = inferSlideKeyFromSelector(
                opName: opName,
                selector: selector,
                contextSlides: contextSlides,
                knownBindings: knownBindings
               ) {
                target["slideKey"] = inferredSlideKey
            }

            if needsSlideKey(opName), target["slideKey"] == nil,
               let elementName = target["elementName"] as? String,
               let boundSlideKey = elementSlideBindings[elementName] {
                target["slideKey"] = boundSlideKey
            }

            if needsSlideKey(opName), target["slideKey"] == nil,
               let inferredSlideKey = inferSlideKey(
                opName: opName,
                target: target,
                args: args,
                knownBindings: knownBindings
               ) {
                target["slideKey"] = inferredSlideKey
            }

            if needsSlideKey(opName), target["slideKey"] == nil {
                if let currentSlideIndex = knownBindings["current_slide"] {
                    target["slideKey"] = preferredSlideKey(for: currentSlideIndex, knownBindings: knownBindings)
                } else {
                    target["slideKey"] = currentSlideKey ?? nextSlideKey(fromTitle: "slide")
                }
            }

            if needsElementName(opName) && !resolvesSlideTarget, target["elementName"] == nil,
               let roleElementName = roleElementNameForDirectTarget(opName: opName, selector: selector) {
                target["elementName"] = roleElementName
            }

            if needsElementName(opName) && !resolvesSlideTarget,
               let rawElementName = target["elementName"] as? String,
               isSelectionAlias(rawElementName) {
                if let firstSelectedName {
                    target["elementName"] = firstSelectedName
                } else if opName == "deleteElement",
                          let selectedSentinel = selectedElementSentinel(from: rawElementName) {
                    target["elementName"] = selectedSentinel
                }
            }

            if needsElementName(opName) && !resolvesSlideTarget,
               let rawElementName = target["elementName"] as? String,
               let canonicalRoleElementName = canonicalRoleElementName(
                rawElementName,
                selector: selector,
                opName: opName
               ) {
                target["elementName"] = canonicalRoleElementName
            }

            if needsElementName(opName) && !resolvesSlideTarget, target["elementName"] == nil {
                let selectionOnlyDelete = opName == "deleteElement" && (selector["isSelected"] as? Bool) == true
                if !selector.isEmpty && !selectionOnlyDelete {
                    let slide = (target["slideKey"] as? String) ?? (currentSlideKey ?? nextSlideKey(fromTitle: "slide"))
                    target["elementName"] = nextElementName(slideKey: slide, role: "resolved", slug: "target")
                }
            }

            if needsElementName(opName) && !resolvesSlideTarget, target["elementName"] == nil {
                var deleteInferenceTarget = selectorAwareTarget
                if deleteInferenceTarget["useSelection"] == nil,
                   let isSelected = selector["isSelected"] as? Bool {
                    deleteInferenceTarget["useSelection"] = isSelected
                }
                if opName == "deleteElement",
                   let inferredName = inferDeleteElementName(target: deleteInferenceTarget, selectedItemName: firstSelectedName) {
                    target["elementName"] = inferredName
                }
            }

            if needsElementName(opName) && !resolvesSlideTarget, target["elementName"] == nil {
                if let firstSelectedName, prefersSelectedElementName(opName) {
                    target["elementName"] = firstSelectedName
                } else if shouldAutoGenerateElementName(opName) {
                    let slide = (target["slideKey"] as? String) ?? (currentSlideKey ?? nextSlideKey(fromTitle: "slide"))
                    target["elementName"] = nextElementName(slideKey: slide, role: "auto", slug: "item")
                }
            }

            if opName == "alignElements" || opName == "distributeElements" {
                normalizeMultiTarget(opName: opName, target: &target, args: &args, selectedNames: selectedNames, selectedCount: selectedItems.count)
            }

            if opName == "ensureBullets" {
                args = normalizeBulletsArgs(args)
            }

            if opName == "ensureSlide" {
                var effectiveSlideKey = target["slideKey"] as? String
                let hadExplicitLayout = args["layout"] != nil ||
                    args["layoutName"] != nil ||
                    args["master"] != nil ||
                    args["masterName"] != nil
                let forceBulletsLayout = effectiveSlideKey.map { bulletSlideKeys.contains($0) } ?? false
                args = normalizeEnsureSlideArgs(args, forceTitleAndBullets: forceBulletsLayout)
                if let slideKey = effectiveSlideKey,
                   shouldAssignManagedAliasForCreatedSlide(
                    slideKey: slideKey,
                    createsNewSlide: shouldTreatEnsureSlideAsCreateIntent(args: args),
                    knownBindings: knownBindings
                   ) {
                    let managedSlideKey = nextSlideKey(
                        fromTitle: textValue(from: args["title"]) ?? "inserted_slide"
                    )
                    slideKeyRewrites[slideKey] = managedSlideKey
                    target["slideKey"] = managedSlideKey
                    effectiveSlideKey = managedSlideKey
                }
                if insertionObjective,
                   let slideKey = effectiveSlideKey,
                   shouldBindExistingSlideByTitleHint(
                    slideKey: slideKey,
                    args: args,
                    plannedTitle: plannedTitleBySlideKey[slideKey],
                    contextSlides: contextSlides,
                    knownBindings: knownBindings
                   ) {
                    args.removeValue(forKey: "layout")
                    args.removeValue(forKey: "master")
                    args.removeValue(forKey: "masterName")
                }
                if let slideKey = effectiveSlideKey,
                   textValue(from: args["title"]) == nil,
                   let hintedTitle = plannedTitleBySlideKey[slideKey],
                   !hintedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    args["title"] = hintedTitle
                    consumedEnsureSlideTitles.insert(consumedTitleKey(slideKey: slideKey, title: hintedTitle))
                }
                if let slideKey = effectiveSlideKey,
                   positiveInt(from: args["index"]) == nil,
                   args["layout"] == nil,
                   args["master"] == nil,
                   args["masterName"] == nil,
                   let hintedIndex = slideIndexHint(from: slideKey),
                   hintedIndex > 0 {
                    // Title-only ensureSlide against concrete slide keys should bind
                    // to the existing index rather than accidentally creating slides.
                    args["index"] = hintedIndex
                }
                if let slideKey = effectiveSlideKey,
                   shouldRekeyEnsureSlideCreate(
                    slideKey: slideKey,
                    args: args,
                    plannedTitle: plannedTitleBySlideKey[slideKey],
                    knownBindings: knownBindings,
                    contextSlides: contextSlides
                   ) {
                    let insertSlideKey = nextSlideKey(fromTitle: "inserted_slide")
                    slideKeyRewrites[slideKey] = insertSlideKey
                    target["slideKey"] = insertSlideKey
                    effectiveSlideKey = insertSlideKey
                }
                if let slideKey = effectiveSlideKey, materializedSlideKeys.contains(slideKey), !hadExplicitLayout {
                    args.removeValue(forKey: "layout")
                    args.removeValue(forKey: "master")
                    args.removeValue(forKey: "masterName")
                }
                if shouldForceBindExistingSlideForEnsureSlide(
                    originalSlideKey: plannerOriginalSlideKey,
                    targetSlideKey: effectiveSlideKey,
                    args: args,
                    contextSlides: contextSlides,
                    knownBindings: knownBindings
                ) {
                    args.removeValue(forKey: "layout")
                    args.removeValue(forKey: "master")
                    args.removeValue(forKey: "masterName")
                }
                if let slideKey = effectiveSlideKey,
                   let titleText = textValue(from: args["title"]),
                   !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    consumedEnsureSlideTitles.insert(consumedTitleKey(slideKey: slideKey, title: titleText))
                    deferredOps.append(
                        op(
                            name: "ensureTextBox",
                            target: ["slideKey": slideKey, "elementName": "__ksk_role_title__"],
                            args: [
                                "text": titleText,
                                "style": ["role": "title"]
                            ],
                            verify: ["textPrefix": titleText]
                        )
                    )
                }
                if let bodyItems = extractEnsureSlideBodyItems(args),
                   let slideKey = effectiveSlideKey {
                    deferredOps.append(
                        op(
                            name: "ensureBullets",
                            target: ["slideKey": slideKey, "elementName": "__ksk_role_body__"],
                            args: ["items": bodyItems],
                            verify: ["bulletCount": bodyItems.count]
                        )
                    )
                }
            }

            if opName == "duplicateSlide",
               let slideKey = target["slideKey"] as? String,
               shouldAssignManagedAliasForCreatedSlide(
                slideKey: slideKey,
                createsNewSlide: true,
                knownBindings: knownBindings
               ) {
                let managedSlideKey = nextSlideKey(fromTitle: "duplicated_slide")
                slideKeyRewrites[slideKey] = managedSlideKey
                target["slideKey"] = managedSlideKey
            }

            if opName == "ensureTextBox", args["text"] == nil {
                args["text"] = ""
            }
            if opName == "ensureTextBox" {
                args = normalizeTextBoxArgs(
                    args,
                    elementName: target["elementName"] as? String,
                    selector: selector
                )
                if let slideKey = target["slideKey"] as? String,
                   let text = textValue(from: args["text"]),
                   isTitleTextOperation(args: args),
                   consumedEnsureSlideTitles.contains(consumedTitleKey(slideKey: slideKey, title: text)) {
                    continue
                }
            }

            if opName == "ensureShape" {
                args = normalizeShapeArgs(args)
            }

            if opName == "setOpacity" {
                args = normalizeOpacityArgs(args)
            }

            if opName == "hideSlide" {
                args = normalizeHideSlideArgs(args)
            }

            if opName == "moveSlide" {
                args = normalizeMoveSlideArgs(
                    args,
                    target: target,
                    knownBindings: knownBindings
                )
            }

            if opName == "setPresenterNotes" {
                args = normalizePresenterNotesArgs(args)
            }

            if (opName == "ensureTextBox" || opName == "ensureBullets" || opName == "ensureShape"), !allowFrameControl {
                args.removeValue(forKey: "frame")
            }

            var adjustedVerify = normalizeVerify(verify, for: opName)
            if (opName == "ensureTextBox" || opName == "ensureBullets" || opName == "ensureShape"), !allowFrameControl {
                adjustedVerify.removeValue(forKey: "frameApprox")
            }

            if opName == "resolveTarget",
               resolvesSlideTarget,
               let aliasSlideKey = target["slideKey"] as? String {
                if let resolvedIndex = resolveSlideIndexFromSelector(
                    selector: selector,
                    contextSlides: contextSlides,
                    knownBindings: knownBindings
                ) {
                    let hasExplicitSelectorIndex = positiveInt(from: selector["index"]) != nil
                    if hasExplicitSelectorIndex {
                        let maxContextIndex = contextSlides.map(\.index).max() ?? 0
                        let maxReachableIndex = maxContextIndex + plannedInsertions.count
                        if maxReachableIndex > 0, resolvedIndex > maxReachableIndex {
                            output.append(op(
                                name: "assertState",
                                target: ["slideKey": aliasSlideKey],
                                args: [:],
                                verify: ["slideExists": true]
                            ))
                            materializedSlideKeys.insert(aliasSlideKey)
                            continue
                        }
                    }
                    let rebasedIndex: Int
                    if hasExplicitSelectorIndex {
                        // Explicit selector indices are typically intentional absolute targets.
                        rebasedIndex = resolvedIndex
                    } else {
                        rebasedIndex = SlideIndexRewriter.adjustedIndex(
                            original: resolvedIndex,
                            insertionIndices: plannedInsertions
                        )
                    }
                    output.append(op(
                        name: "ensureSlide",
                        target: ["slideKey": aliasSlideKey],
                        args: ["index": rebasedIndex],
                        verify: ["slideExists": true]
                    ))
                } else {
                    output.append(op(
                        name: "assertState",
                        target: ["slideKey": aliasSlideKey],
                        args: [:],
                        verify: ["slideExists": true]
                    ))
                }
                materializedSlideKeys.insert(aliasSlideKey)
                continue
            }

            if opName == "resolveTarget",
               let slideKey = target["slideKey"] as? String,
               let elementName = target["elementName"] as? String {
                rememberElementSlideBinding(
                    elementName: elementName,
                    slideKey: slideKey,
                    bindings: &elementSlideBindings
                )
                var resolveArgs = args
                if !selector.isEmpty {
                    resolveArgs["selector"] = selector
                }
                output.append(op(
                    name: "resolveTarget",
                    target: ["slideKey": slideKey, "elementName": elementName],
                    args: resolveArgs,
                    verify: adjustedVerify
                ))
                continue
            }

            if needsElementName(opName) && !resolvesSlideTarget,
               !selector.isEmpty,
               let slideKey = target["slideKey"] as? String,
               let elementName = target["elementName"] as? String {
                let skipResolve = shouldBypassResolveTarget(opName: opName, elementName: elementName, selector: selector)
                let isSelectionDelete = opName == "deleteElement" &&
                    ((selector["isSelected"] as? Bool) == true || isSelectionAlias(elementName))
                if !isSelectionDelete && !skipResolve {
                    output.append(op(
                        name: "resolveTarget",
                        target: ["slideKey": slideKey, "elementName": elementName],
                        args: ["selector": selector],
                        verify: ["elementExists": true]
                    ))
                }
            }

            if let assertOp = makeAssertStateOp(opName: opName, target: target),
               !hasEquivalentAssert(alreadyIn: output, candidate: assertOp) {
                output.append(assertOp)
            }

            if let slideKey = target["slideKey"] as? String,
               let elementName = target["elementName"] as? String {
                rememberElementSlideBinding(
                    elementName: elementName,
                    slideKey: slideKey,
                    bindings: &elementSlideBindings
                )
            }

            if let slideKey = target["slideKey"] as? String {
                if opName == "ensureSlide" {
                    let normalizedSlideKey = normalizeDeicticSlideKey(slideKey)
                    if knownBindings[slideKey] == nil && knownBindings[normalizedSlideKey] == nil {
                        createdSlideAliases.insert(slideKey)
                    }
                    if shouldTreatEnsureSlideAsInsert(
                        slideKey: slideKey,
                        args: args,
                        materializedSlideKeys: materializedSlideKeys
                    ),
                       let insertIndex = positiveInt(from: args["index"]) {
                        plannedInsertions.append(insertIndex)
                        insertedSlideAliasByIndex[insertIndex] = slideKey
                    }
                    materializedSlideKeys.insert(slideKey)
                } else if opName == "duplicateSlide" {
                    let normalizedSlideKey = normalizeDeicticSlideKey(slideKey)
                    if knownBindings[slideKey] == nil && knownBindings[normalizedSlideKey] == nil {
                        createdSlideAliases.insert(slideKey)
                    }
                    if !materializedSlideKeys.contains(slideKey),
                       let insertIndex = positiveInt(from: args["index"]) {
                        plannedInsertions.append(insertIndex)
                    }
                    materializedSlideKeys.insert(slideKey)
                } else if opName == "moveSlide" ||
                            opName == "hideSlide" ||
                            opName == "deleteSlide" ||
                            opName == "assertState" {
                    materializedSlideKeys.insert(slideKey)
                }
            }
            output.append(op(name: opName, target: target, args: args, verify: adjustedVerify))
            if !deferredOps.isEmpty {
                output.append(contentsOf: deferredOps)
            }
        }

        return healSlideReferences(in: output, contextSlides: contextSlides, knownBindings: knownBindings)
    }

    private func normalizeEnsureSlideArgs(_ args: [String: Any], forceTitleAndBullets: Bool) -> [String: Any] {
        var normalized = args
        if normalized["layout"] == nil, let layoutName = normalized["layoutName"] as? String {
            normalized["layout"] = layoutName
        }
        normalized.removeValue(forKey: "layoutName")

        if let titleText = textValue(from: normalized["title"]) {
            normalized["title"] = titleText
        } else {
            normalized.removeValue(forKey: "title")
        }

        if forceTitleAndBullets {
            normalized["layout"] = "Title & Bullets"
            return normalized
        }

        let requested = (normalized["layout"] as? String)
            ?? (normalized["master"] as? String)
            ?? (normalized["masterName"] as? String)

        guard let requested else {
            return normalized
        }

        if let mapped = mapLayoutName(requested) {
            normalized["layout"] = mapped
        } else {
            normalized["layout"] = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return normalized
    }

    private func extractEnsureSlideBodyItems(_ args: [String: Any]) -> [String]? {
        if let items = normalizedBulletItems(from: args["items"]) {
            return items
        }
        if let bodyText = textValue(from: args["body"]) {
            let split = splitBulletText(bodyText)
            return split.isEmpty ? nil : split
        }
        return nil
    }

    private func textValue(from raw: Any?) -> String? {
        guard let raw else { return nil }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let object = raw as? [String: Any] {
            let candidates = ["text", "value", "content", "title"]
            for key in candidates {
                if let text = object[key] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }
        return nil
    }

    private func shouldForceBindExistingSlideForEnsureSlide(
        originalSlideKey: String?,
        targetSlideKey: String?,
        args: [String: Any],
        contextSlides: [ContextSlide],
        knownBindings: [String: Int]
    ) -> Bool {
        guard let targetSlideKey else { return false }
        let hasStructuralCreateSignal =
            args["layout"] != nil ||
            args["master"] != nil ||
            args["masterName"] != nil
        if hasStructuralCreateSignal {
            return false
        }
        let normalizedOriginal = normalizeDeicticSlideKey(originalSlideKey ?? "")
        if normalizedOriginal == "current_slide" {
            return true
        }

        let maxContextIndex = contextSlides.map(\.index).max() ?? knownBindings.values.max() ?? 0
        let targetHint = slideIndexHint(from: targetSlideKey)
        let requestedIndex = positiveInt(from: args["index"])

        if let targetHint,
           let requestedIndex,
           targetHint == requestedIndex,
           requestedIndex > 0,
           requestedIndex <= maxContextIndex {
            return true
        }

        if let boundIndex = knownBindings[targetSlideKey] ?? knownBindings[normalizeDeicticSlideKey(targetSlideKey)],
           let requestedIndex,
           requestedIndex == boundIndex {
            return true
        }

        return false
    }

    private func shouldRekeyEnsureSlideCreate(
        slideKey: String,
        args: [String: Any],
        plannedTitle: String?,
        knownBindings: [String: Int],
        contextSlides: [ContextSlide]
    ) -> Bool {
        guard slideIndexHint(from: slideKey) != nil else { return false }

        let normalizedSlideKey = normalizeDeicticSlideKey(slideKey)
        guard let boundIndex = knownBindings[slideKey] ?? knownBindings[normalizedSlideKey],
              let requestedIndex = positiveInt(from: args["index"]) else {
            return false
        }

        // Rekeying must stay strictly structural. Title-only ensureSlide on a bound
        // concrete slide key is usually a retitle update, not a request to insert.
        let hasStructuralCreateSignal =
            args["layout"] != nil ||
            args["master"] != nil ||
            args["masterName"] != nil
        guard hasStructuralCreateSignal else { return false }

        if requestedIndex != boundIndex {
            // Structural ensureSlide targeting a different index than the bound
            // concrete slide key should insert under a fresh alias, not overwrite.
            return true
        }

        guard let existing = contextSlides.first(where: { $0.index == requestedIndex }) else {
            return false
        }

        let requestedTitle = textValue(from: args["title"]) ?? plannedTitle
        guard let requestedTitle = requestedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !requestedTitle.isEmpty else {
            return false
        }

        let existingTitle = existing.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if existingTitle.caseInsensitiveCompare(requestedTitle) == .orderedSame {
            return false
        }

        // If the concrete bound slide already has a title, rewriting the same key
        // is likely an accidental overwrite; create under a fresh alias instead.
        return !existingTitle.isEmpty
    }

    private func shouldBindExistingSlideByTitleHint(
        slideKey: String,
        args: [String: Any],
        plannedTitle: String?,
        contextSlides: [ContextSlide],
        knownBindings: [String: Int]
    ) -> Bool {
        guard let requestedIndex = positiveInt(from: args["index"]) else {
            return false
        }
        guard knownBindings[slideKey] == nil,
              knownBindings[normalizeDeicticSlideKey(slideKey)] == nil else {
            return false
        }
        guard let expected = (textValue(from: args["title"]) ?? plannedTitle)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expected.isEmpty else {
            return false
        }
        guard let existing = contextSlides.first(where: { $0.index == requestedIndex }) else {
            return false
        }
        let existingTitle = existing.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingTitle.isEmpty else { return false }
        return existingTitle.caseInsensitiveCompare(expected) == .orderedSame
    }

    private func plannedTitleHints(from operations: [[String: Any]]) -> [String: String] {
        var hints: [String: String] = [:]

        for raw in operations {
            guard let op = raw["op"] as? String,
                  op == "ensureTextBox",
                  let target = raw["target"] as? [String: Any],
                  let slideKey = (target["slideKey"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !slideKey.isEmpty else {
                continue
            }
            let args = raw["args"] as? [String: Any] ?? [:]
            let role = (args["role"] as? String)?.lowercased()
            var isTitleRole = role == "title"
            if !isTitleRole,
               let style = args["style"] as? [String: Any],
               let styleRole = (style["role"] as? String)?.lowercased() {
                isTitleRole = styleRole == "title"
            }
            guard isTitleRole,
                  let text = textValue(from: args["text"]) else {
                continue
            }
            hints[slideKey] = text
        }

        return hints
    }

    private func shouldTreatEnsureSlideAsInsert(
        slideKey: String,
        args: [String: Any],
        materializedSlideKeys: Set<String>
    ) -> Bool {
        let cleanedSlideKey = slideKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSlideKey.isEmpty else { return false }
        guard !materializedSlideKeys.contains(cleanedSlideKey) else { return false }

        // Only structural create signals should be treated as insertions.
        // Title-only ensureSlide with a concrete index is often a bind/update.
        if args["layout"] != nil || args["master"] != nil || args["masterName"] != nil {
            return true
        }

        return positiveInt(from: args["index"]) == nil
    }

    private func shouldTreatEnsureSlideAsCreateIntent(args: [String: Any]) -> Bool {
        if args["layout"] != nil || args["master"] != nil || args["masterName"] != nil {
            return true
        }
        return false
    }

    private func shouldAssignManagedAliasForCreatedSlide(
        slideKey: String,
        createsNewSlide: Bool,
        knownBindings: [String: Int]
    ) -> Bool {
        _ = createsNewSlide
        let cleaned = slideKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        let normalized = normalizeDeicticSlideKey(cleaned)
        if isPlanAliasSlideKey(normalized) {
            return false
        }

        if knownBindings[cleaned] != nil || knownBindings[normalized] != nil {
            return false
        }

        return true
    }

    private func sanitizeKnownBindings(
        _ raw: [String: Int],
        contextSlides: [ContextSlide]
    ) -> [String: Int] {
        let reservedAliases: Set<String> = [
            "active_slide",
            "current_slide",
            "this_slide",
            "slide_after_current",
            "slide_after_this"
        ]
        let maxContextIndex = contextSlides.map(\.index).max() ?? 0
        var sanitized: [String: Int] = [:]

        for (key, index) in raw {
            guard index > 0 else { continue }
            if reservedAliases.contains(key) {
                sanitized[key] = index
                continue
            }
            if (isConcreteSlideAlias(key) || isStableSlideAlias(key)),
               maxContextIndex == 0 || index <= maxContextIndex {
                sanitized[key] = index
            }
        }

        return sanitized
    }

    private func plannerBindingsForCodex(
        baseBindings: [String: Int],
        contextSlides: [ContextSlide],
        focus: PresentationFocusContext
    ) -> [String: Int] {
        var plannerBindings: [String: Int] = [:]

        for (key, index) in baseBindings {
            guard index > 0 else { continue }
            if isPlannerSafeSlideAlias(key) {
                plannerBindings[key] = index
            }
        }

        for slide in contextSlides where isPlannerSafeSlideAlias(slide.slideKey) {
            plannerBindings[slide.slideKey] = slide.index
        }

        if let currentSlideIndex = focus.currentSlideIndex {
            plannerBindings["current_slide"] = currentSlideIndex
            plannerBindings["this_slide"] = currentSlideIndex
            plannerBindings["active_slide"] = currentSlideIndex
            plannerBindings["slide_after_current"] = currentSlideIndex + 1
            plannerBindings["slide_after_this"] = currentSlideIndex + 1
        }

        return plannerBindings
    }

    private func isPlannerSafeSlideAlias(_ key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        if isReservedPlannerAlias(normalized) { return true }
        if isStableSlideAlias(normalized) { return true }
        if isConcreteSlideAlias(normalized) { return false }
        return true
    }

    private func isReservedPlannerAlias(_ key: String) -> Bool {
        switch key {
        case "active_slide", "current_slide", "this_slide", "slide_after_current", "slide_after_this":
            return true
        default:
            return false
        }
    }

    private func isConcreteSlideAlias(_ key: String) -> Bool {
        let lowered = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.range(of: #"^slide_\d+$"#, options: .regularExpression) != nil
    }

    private func isStableSlideAlias(_ key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("sref_") || normalized.hasPrefix("sid_")
    }

    private func consumedTitleKey(slideKey: String, title: String) -> String {
        let key = slideKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(key)|\(text)"
    }

    private func isTitleTextOperation(args: [String: Any]) -> Bool {
        if let role = (args["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           role == "title" {
            return true
        }
        if let style = args["style"] as? [String: Any],
           let role = (style["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           role == "title" {
            return true
        }
        return false
    }

    private func inferSlideKey(
        opName: String,
        target: [String: Any],
        args: [String: Any],
        knownBindings: [String: Int]
    ) -> String? {
        if let slideIndex = positiveInt(from: target["slideIndex"]) {
            return preferredSlideKey(for: slideIndex, knownBindings: knownBindings)
        }

        if opName == "ensureSlide",
           let index = positiveInt(from: args["index"]) {
            return preferredSlideKey(for: index, knownBindings: knownBindings)
        }

        if opName == "moveSlide",
           let fromIndex = positiveInt(from: target["fromSlideIndex"] ?? args["fromIndex"]) {
            return preferredSlideKey(for: fromIndex, knownBindings: knownBindings)
        }

        return nil
    }

    private func inferSlideKeyFromSelector(
        opName: String,
        selector: [String: Any],
        contextSlides: [ContextSlide],
        knownBindings: [String: Int]
    ) -> String? {
        guard needsSlideKey(opName) else { return nil }
        guard let selectorText = selectorPreferredText(selector), !selectorText.isEmpty else {
            return nil
        }
        guard let matched = matchContextSlide(forSelectorText: selectorText, slides: contextSlides) else {
            return nil
        }
        if let known = preferredKnownSlideKey(for: matched, knownBindings: knownBindings) {
            return known
        }
        return preferredSlideKey(for: matched.index, knownBindings: knownBindings)
    }

    private func isSlideResolveTarget(opName: String, selector: [String: Any]) -> Bool {
        guard opName == "resolveTarget" else { return false }
        let selectorType = (selector["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if selectorType == "slide" {
            return true
        }
        if positiveInt(from: selector["index"]) != nil {
            return true
        }
        return false
    }

    private func resolveSlideIndexFromSelector(
        selector: [String: Any],
        contextSlides: [ContextSlide],
        knownBindings: [String: Int]
    ) -> Int? {
        if let index = positiveInt(from: selector["index"]) {
            return index
        }
        if let text = selectorPreferredText(selector), !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let bound = knownBindings[trimmed] {
                return bound
            }
            if let matched = matchContextSlide(forSelectorText: trimmed, slides: contextSlides) {
                return matched.index
            }
        }
        return nil
    }

    private func selectorPreferredText(_ selector: [String: Any]) -> String? {
        let ordered: [String] = ["textEquals", "slideTitleEquals", "textPrefix", "textContains", "matchText"]
        for key in ordered {
            if let value = selector[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private func preferredKnownSlideKey(for slide: ContextSlide, knownBindings: [String: Int]) -> String? {
        let reservedAliases: Set<String> = [
            "active_slide",
            "current_slide",
            "this_slide",
            "slide_after_current",
            "slide_after_this"
        ]

        let candidates = knownBindings
            .filter { key, index in
                index == slide.index && !reservedAliases.contains(key)
            }
            .map(\.key)

        guard !candidates.isEmpty else { return nil }

        let exact = candidates.first { normalizeSlideToken($0) == slide.slug }
        if let exact {
            return exact
        }

        return candidates.max { lhs, rhs in
            scoreSlideKeyCandidate(lhs, slideSlug: slide.slug) < scoreSlideKeyCandidate(rhs, slideSlug: slide.slug)
        }
    }

    private func scoreSlideKeyCandidate(_ key: String, slideSlug: String) -> Int {
        let normalized = normalizeSlideToken(key)
        let isGeneric = key.range(of: #"^slide_?\d+$"#, options: .regularExpression) != nil

        var score = 0
        if !isGeneric { score += 40 } else { score += 10 }
        if !slideSlug.isEmpty {
            if normalized == slideSlug {
                score += 80
            } else if normalized.contains(slideSlug) || slideSlug.contains(normalized) {
                score += 40
            }
        }
        score += min(key.count, 40)
        return score
    }

    private func mapLayoutName(_ raw: String) -> String? {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)

        switch token {
        case "title", "titleslide", "titleonly", "sectiontitle", "titleandsubtitle", "titlesubtitle":
            return "Title"
        case "titleandbullets", "titlebullets", "titleandbody", "titlebody", "titlebullet", "titleandbullet":
            return "Title & Bullets"
        default:
            return nil
        }
    }

    private func normalizeBulletsArgs(_ args: [String: Any]) -> [String: Any] {
        var normalized = args

        if let items = normalizedBulletItems(from: normalized["items"]) {
            normalized["items"] = items
            return normalized
        }

        if let items = normalizedBulletItems(from: normalized["bullets"]) {
            normalized["items"] = items
            normalized.removeValue(forKey: "bullets")
            return normalized
        }

        if let items = normalizedBulletItems(from: normalized["textItems"]) {
            normalized["items"] = items
            normalized.removeValue(forKey: "textItems")
            return normalized
        }

        if let items = normalizedBulletItems(from: normalized["bulletItems"]) {
            normalized["items"] = items
            normalized.removeValue(forKey: "bulletItems")
            return normalized
        }

        if let textItems = normalizedBulletItems(from: normalized["text"]) {
            normalized["items"] = textItems
            normalized.removeValue(forKey: "text")
            return normalized
        }

        if let text = normalized["text"] as? String {
            normalized["items"] = splitBulletText(text)
            normalized.removeValue(forKey: "text")
            return normalized
        }

        if let contentItems = normalizedBulletItems(from: normalized["content"]) {
            normalized["items"] = contentItems
            normalized.removeValue(forKey: "content")
            return normalized
        }
        if let text = normalized["content"] as? String {
            normalized["items"] = splitBulletText(text)
            normalized.removeValue(forKey: "content")
            return normalized
        }

        if let bodyItems = normalizedBulletItems(from: normalized["body"]) {
            normalized["items"] = bodyItems
            normalized.removeValue(forKey: "body")
            return normalized
        }
        if let text = normalized["body"] as? String {
            normalized["items"] = splitBulletText(text)
            normalized.removeValue(forKey: "body")
            return normalized
        }

        if let number = normalized["items"] as? NSNumber {
            let line = cleanBulletLine(number.stringValue)
            if !line.isEmpty {
                normalized["items"] = [line]
            }
        }

        return normalized
    }

    private func normalizePresenterNotesArgs(_ args: [String: Any]) -> [String: Any] {
        var normalized = args
        if normalized["text"] == nil, let notes = normalized["notes"] as? String {
            normalized["text"] = notes
            normalized.removeValue(forKey: "notes")
        }
        return normalized
    }

    private func normalizeShapeArgs(_ args: [String: Any]) -> [String: Any] {
        var normalized = args
        if normalized["shapeType"] == nil, let rawType = normalized["shape"] as? String {
            normalized["shapeType"] = rawType
            normalized.removeValue(forKey: "shape")
        }
        if normalized["text"] == nil, let content = normalized["content"] as? String {
            normalized["text"] = content
            normalized.removeValue(forKey: "content")
        }
        if normalized["text"] == nil {
            normalized["text"] = ""
        }
        return normalized
    }

    private func normalizeMultiTarget(
        opName: String,
        target: inout [String: Any],
        args: inout [String: Any],
        selectedNames: [String],
        selectedCount: Int
    ) {
        var names = extractElementNames(target: target, args: args)
        let selectedAliasMentioned = names.contains(where: isSelectionAlias)

        if selectedAliasMentioned {
            if !selectedNames.isEmpty {
                names = selectedNames
            } else if selectedCount > 0 {
                args["useSelection"] = true
                names = []
            }
        } else if names.isEmpty {
            if !selectedNames.isEmpty {
                names = selectedNames
            } else if selectedCount > 0 {
                args["useSelection"] = true
            }
        }

        if names.isEmpty {
            target.removeValue(forKey: "elementNames")
            args.removeValue(forKey: "elementNames")
        } else {
            target["elementNames"] = names
            args.removeValue(forKey: "elementNames")
        }

        if args["useSelection"] == nil {
            args["useSelection"] = false
        }

        if opName == "alignElements" {
            if args["alignment"] == nil, let mode = args["mode"] as? String {
                args["alignment"] = mode
                args.removeValue(forKey: "mode")
            }
            if args["alignment"] == nil, let align = target["alignment"] as? String {
                args["alignment"] = align
            }
        } else if opName == "distributeElements" {
            if args["axis"] == nil, let direction = args["direction"] as? String {
                args["axis"] = direction
                args.removeValue(forKey: "direction")
            }
            if args["axis"] == nil, let axis = target["axis"] as? String {
                args["axis"] = axis
            }
            if args["spacing"] == nil, let gap = args["gap"] {
                args["spacing"] = gap
                args.removeValue(forKey: "gap")
            }
        }
    }

    private func extractElementNames(target: [String: Any], args: [String: Any]) -> [String] {
        if let names = normalizeElementNameList(target["elementNames"] ?? args["elementNames"]) {
            return names
        }
        if let single = (target["elementName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !single.isEmpty {
            return [single]
        }
        return []
    }

    private func normalizeElementNameList(_ raw: Any?) -> [String]? {
        guard let raw else { return nil }
        if let values = raw as? [String] {
            let cleaned = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned
        }
        if let anyValues = raw as? [Any] {
            let cleaned = anyValues.compactMap { value -> String? in
                if let text = value as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if let object = value as? [String: Any] {
                    if let text = object["name"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    if let text = object["elementName"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    if let text = object["alias"] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                }
                return nil
            }
            return cleaned.isEmpty ? nil : cleaned
        }
        if let text = raw as? String {
            let parts = text
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }
        return nil
    }

    private func normalizeTextBoxArgs(
        _ args: [String: Any],
        elementName: String?,
        selector: [String: Any]
    ) -> [String: Any] {
        var normalized = args
        let role = inferTextRole(fromElementName: elementName)
            ?? selectorRole(selector)
            ?? inferKindRole(from: args["kind"])
        guard let role else {
            return normalized
        }

        var style = normalized["style"] as? [String: Any] ?? [:]
        if style["role"] == nil {
            style["role"] = role
            normalized["style"] = style
        }
        normalized.removeValue(forKey: "kind")
        return normalized
    }

    private func extractNestedOperations(_ raw: Any?) -> [[String: Any]]? {
        guard let list = raw as? [Any] else { return nil }
        let nested = list.compactMap { $0 as? [String: Any] }
        return nested.isEmpty ? nil : nested
    }

    private func extractSelector(target: [String: Any], args: [String: Any]) -> [String: Any] {
        var selector = target["selector"] as? [String: Any] ?? [:]
        if let argSelector = args["selector"] as? [String: Any] {
            for (key, value) in argSelector {
                selector[key] = value
            }
        }

        if selector["role"] == nil,
           let textType = (target["textType"] as? String) ?? (args["textType"] as? String) {
            let lowered = textType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "title" || lowered == "headline" {
                selector["role"] = "title"
            } else if lowered == "body" || lowered == "content" || lowered == "bullets" || lowered == "bullet" {
                selector["role"] = "body"
            }
        }

        if selector["role"] == nil, let kindRole = inferKindRole(from: target["kind"] ?? args["kind"]) {
            selector["role"] = kindRole
        }

        if let role = (target["role"] as? String) ?? (args["role"] as? String),
           !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selector["role"] = role
        }

        if selector["type"] == nil {
            if let type = (target["type"] as? String) ?? (args["type"] as? String),
               !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selector["type"] = type
            } else if let elementType = (target["elementType"] as? String) ?? (args["elementType"] as? String),
                      !elementType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selector["type"] = elementType
            }
        }

        if selector["textContains"] == nil {
            if let textContains = (target["textContains"] as? String) ?? (args["textContains"] as? String),
               !textContains.isEmpty {
                selector["textContains"] = textContains
            } else if let matchText = (target["matchText"] as? String) ?? (args["matchText"] as? String),
                      !matchText.isEmpty {
                selector["textContains"] = matchText
            }
        }

        if selector["textPrefix"] == nil,
           let textPrefix = (target["textPrefix"] as? String) ?? (args["textPrefix"] as? String),
           !textPrefix.isEmpty {
            selector["textPrefix"] = textPrefix
        }

        if selector["index"] == nil,
           let index = positiveInt(from: target["index"]) ?? positiveInt(from: args["index"]) {
            selector["index"] = index
        }

        if selector["isSelected"] == nil {
            if let isSelected = (target["isSelected"] as? Bool) ?? (args["isSelected"] as? Bool) {
                selector["isSelected"] = isSelected
            } else if let useSelection = (target["useSelection"] as? Bool) ?? (args["useSelection"] as? Bool) {
                selector["isSelected"] = useSelection
            } else if let token = ((target["isSelected"] as? String) ?? (args["isSelected"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
                if token == "true" || token == "yes" || token == "1" {
                    selector["isSelected"] = true
                } else if token == "false" || token == "no" || token == "0" {
                    selector["isSelected"] = false
                }
            } else if let token = ((target["useSelection"] as? String) ?? (args["useSelection"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
                if token == "true" || token == "yes" || token == "1" {
                    selector["isSelected"] = true
                } else if token == "false" || token == "no" || token == "0" {
                    selector["isSelected"] = false
                }
            }
        }

        if selector["boundsNear"] == nil, let bounds = target["boundsNear"] ?? args["boundsNear"] {
            selector["boundsNear"] = bounds
        }

        return selector
    }

    private func normalizeSelector(_ selector: [String: Any]) -> [String: Any] {
        var normalized = selector
        if normalized["textEquals"] == nil,
           let slideTitleEquals = normalized["slideTitleEquals"] as? String,
           !slideTitleEquals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized["textEquals"] = slideTitleEquals
        }
        if normalized["textPrefix"] == nil,
           let textEquals = normalized["textEquals"] as? String,
           !textEquals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized["textPrefix"] = textEquals
        }
        if normalized["textContains"] == nil,
           let matchText = normalized["matchText"] as? String,
           !matchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized["textContains"] = matchText
        }
        return normalized
    }

    private func roleElementNameForDirectTarget(opName: String, selector: [String: Any]) -> String? {
        guard opName == "ensureTextBox" || opName == "ensureBullets" else { return nil }
        guard let roleRaw = selector["role"] as? String else { return nil }
        let role = roleRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch role {
        case "title", "headline":
            return "__ksk_role_title__"
        case "body", "content", "bullets", "bullet":
            return "__ksk_role_body__"
        default:
            return nil
        }
    }

    private func shouldBypassResolveTarget(opName: String, elementName: String, selector: [String: Any]) -> Bool {
        guard opName == "ensureTextBox" || opName == "ensureBullets" else { return false }
        return canonicalRoleElementName(elementName, selector: selector, opName: opName) != nil
    }

    private func canonicalRoleElementName(_ rawName: String, selector: [String: Any], opName: String) -> String? {
        guard opName == "ensureTextBox" || opName == "ensureBullets" else { return nil }
        let token = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        let selectorRole = (selector["role"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if selectorRole == "title" || selectorRole == "headline" || inferredRole(forElementToken: token) == "title" {
            return "__ksk_role_title__"
        }
        if selectorRole == "body" ||
            selectorRole == "content" ||
            selectorRole == "bullets" ||
            selectorRole == "bullet" ||
            inferredRole(forElementToken: token) == "body" {
            return "__ksk_role_body__"
        }

        return nil
    }

    private func removeSelectorFields(from value: [String: Any], includeIndex: Bool) -> [String: Any] {
        var cleaned = value
        var keys = [
            "selector",
            "role",
            "type",
            "elementType",
            "textContains",
            "textEquals",
            "textPrefix",
            "slideTitleEquals",
            "textType",
            "kind",
            "isSelected",
            "useSelection",
            "boundsNear",
            "matchText"
        ]
        if includeIndex {
            keys.append("index")
        }
        for key in keys {
            cleaned.removeValue(forKey: key)
        }
        return cleaned
    }

    private func makeAssertStateOp(opName: String, target: [String: Any]) -> [String: Any]? {
        switch opName {
        case "deleteSlide":
            guard let slideKey = target["slideKey"] as? String, !slideKey.isEmpty else { return nil }
            return op(
                name: "assertState",
                target: ["slideKey": slideKey],
                args: [:],
                verify: ["slideExists": true]
            )
        case "deleteElement":
            guard let slideKey = target["slideKey"] as? String, !slideKey.isEmpty,
                  let elementName = target["elementName"] as? String, !elementName.isEmpty else {
                return nil
            }
            if isSelectionAlias(elementName) {
                return op(
                    name: "assertState",
                    target: ["slideKey": slideKey],
                    args: [:],
                    verify: ["slideExists": true]
                )
            }
            return op(
                name: "assertState",
                target: ["slideKey": slideKey, "elementName": elementName],
                args: [:],
                verify: ["slideExists": true, "elementExists": true]
            )
        default:
            return nil
        }
    }

    private func inferTextRole(fromElementName elementName: String?) -> String? {
        guard let elementName else { return nil }
        let token = elementName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        return inferredRole(forElementToken: token)
    }

    private func inferredRole(forElementToken token: String) -> String? {
        let titleTokens: Set<String> = [
            "__ksk_role_title__",
            "ksk_role_title",
            "kskroletitle",
            "title",
            "title_box",
            "titlebox",
            "title_text",
            "titletext",
            "headline",
            "header",
            "definition_title",
            "default_title_item",
            "defaulttitleitem"
        ]
        if titleTokens.contains(token) || token.hasPrefix("title_") || token.hasSuffix("_title") {
            return "title"
        }
        if token.contains("title") && !token.contains("subtitle") {
            return "title"
        }

        let bodyTokens: Set<String> = [
            "__ksk_role_body__",
            "ksk_role_body",
            "kskrolebody",
            "body",
            "body_box",
            "bodybox",
            "body_text",
            "bodytext",
            "bullets",
            "bullet",
            "content",
            "text",
            "textbox",
            "text_box",
            "definition_body",
            "default_body_item",
            "defaultbodyitem"
        ]
        if bodyTokens.contains(token) || token.hasPrefix("body_") || token.hasSuffix("_body") {
            return "body"
        }
        if token.contains("bullet") || token.contains("content") || token.contains("body") {
            return "body"
        }

        return nil
    }

    private func liftTargetFieldsFromArgs(target: inout [String: Any], args: inout [String: Any]) {
        let fieldPairs: [(target: String, arg: String)] = [
            ("slideKey", "slideKey"),
            ("slideKeyAlias", "slideKeyAlias"),
            ("slideIndex", "slideIndex"),
            ("elementName", "elementName"),
            ("role", "role"),
            ("textType", "textType"),
            ("kind", "kind")
        ]

        for pair in fieldPairs where target[pair.target] == nil {
            if let value = args[pair.arg] {
                target[pair.target] = value
                args.removeValue(forKey: pair.arg)
            }
        }
    }

    private func rememberElementSlideBinding(
        elementName: String,
        slideKey: String,
        bindings: inout [String: String]
    ) {
        let cleanedName = elementName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedSlide = slideKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty, !cleanedSlide.isEmpty else { return }
        if isRoleAliasElementName(cleanedName) { return }
        bindings[cleanedName] = cleanedSlide
    }

    private func isRoleAliasElementName(_ value: String) -> Bool {
        let token = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return token == "__ksk_role_title__" || token == "__ksk_role_body__"
    }

    private func selectorRole(_ selector: [String: Any]) -> String? {
        guard let raw = selector["role"] as? String else { return nil }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowered {
        case "title", "headline":
            return "title"
        case "body", "content", "bullets", "bullet":
            return "body"
        default:
            return nil
        }
    }

    private func inferKindRole(from raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowered {
        case "title", "headline":
            return "title"
        case "body", "content", "bullets", "bullet":
            return "body"
        default:
            return nil
        }
    }

    private func normalizeLegacyPlannerShapes(
        opName: String,
        target: inout [String: Any],
        args: inout [String: Any],
        verify: inout [String: Any],
        knownBindings: [String: Int]
    ) {
        guard opName == "ensureSlide" else { return }

        if args["title"] == nil, let verifyTitle = verify["title"] as? String {
            let cleaned = verifyTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                args["title"] = cleaned
            }
            verify.removeValue(forKey: "title")
        }

        guard let existingRaw = args["existingSlideKey"] else { return }
        args.removeValue(forKey: "existingSlideKey")

        let existingIndex: Int?
        if let intValue = positiveInt(from: existingRaw) {
            existingIndex = intValue
        } else if let text = existingRaw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let hinted = slideIndexHint(from: trimmed) {
                existingIndex = hinted
            } else if let bound = knownBindings[trimmed] {
                existingIndex = bound
            } else {
                existingIndex = nil
            }
        } else {
            existingIndex = nil
        }

        guard let existingIndex else { return }
        args["index"] = existingIndex
        args.removeValue(forKey: "layout")
        args.removeValue(forKey: "master")
        args.removeValue(forKey: "masterName")
    }

    private func inferDeleteElementName(target: [String: Any], selectedItemName: String?) -> String? {
        if let selectedItemName, !selectedItemName.isEmpty {
            return selectedItemName
        }

        if let useSelection = target["useSelection"] as? Bool, useSelection {
            return "__ksk_selected__1"
        }
        if let token = (target["useSelection"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           token == "true" || token == "yes" || token == "1" {
            return "__ksk_selected__1"
        }

        if let elementType = (target["elementType"] as? String ?? target["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if elementType.contains("title") {
                return "Title"
            }
            if elementType.contains("body") || elementType.contains("text") || elementType.contains("bullet") {
                return "Body"
            }
            if elementType.contains("image") {
                return "Image"
            }
            if elementType.contains("shape") {
                return "Shape"
            }
        }

        if let matchText = (target["matchText"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !matchText.isEmpty {
            return "Body"
        }

        return nil
    }

    private func normalizeOpacityArgs(_ args: [String: Any]) -> [String: Any] {
        var normalized = args
        if normalized["opacity"] == nil, let alpha = normalized["alpha"] {
            normalized["opacity"] = alpha
            normalized.removeValue(forKey: "alpha")
        }
        if normalized["opacity"] == nil, let percent = normalized["percent"] {
            normalized["opacity"] = percent
            normalized.removeValue(forKey: "percent")
        }
        return normalized
    }

    private func normalizeHideSlideArgs(_ args: [String: Any]) -> [String: Any] {
        var normalized = args
        if normalized["hidden"] == nil {
            normalized["hidden"] = true
        }
        return normalized
    }

    private func normalizeMoveSlideArgs(
        _ args: [String: Any],
        target: [String: Any],
        knownBindings: [String: Int]
    ) -> [String: Any] {
        var normalized = args
        let nestedTo = normalized["to"] as? [String: Any]
        func unwrapIndexValue(_ value: Any) -> Any? {
            if let object = value as? [String: Any], let nested = object["index"] {
                return nested
            }
            return value
        }
        func slideKeyValue(from value: Any?) -> String? {
            guard let value else { return nil }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let object = value as? [String: Any] {
                let orderedKeys = ["slideKey", "beforeSlideKey", "afterSlideKey", "key", "id"]
                for key in orderedKeys {
                    if let candidate = object[key] as? String {
                        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            return trimmed
                        }
                    }
                }
            }
            return nil
        }
        func resolvedIndex(for rawSlideKey: String?) -> Int? {
            guard let rawSlideKey else { return nil }
            let resolved = resolveSlideKeyAlias(rawSlideKey, knownBindings: knownBindings) ?? rawSlideKey
            let normalizedKey = normalizeDeicticSlideKey(resolved)
            if let direct = knownBindings[resolved], direct > 0 {
                return direct
            }
            if let normalized = knownBindings[normalizedKey], normalized > 0 {
                return normalized
            }
            if let hinted = slideIndexHint(from: resolved), hinted > 0 {
                return hinted
            }
            return nil
        }
        let maxBoundIndex = knownBindings
            .filter { key, value in
                value > 0 && !isReservedPlannerAlias(key)
            }
            .map(\.value)
            .max() ?? 1
        if normalized["index"] == nil {
            let aliases = ["to", "toIndex", "destinationIndex", "targetIndex"]
            for alias in aliases {
                if let value = normalized[alias] {
                    normalized["index"] = unwrapIndexValue(value)
                    break
                }
            }
        }
        normalized.removeValue(forKey: "to")
        normalized.removeValue(forKey: "toIndex")
        normalized.removeValue(forKey: "destinationIndex")
        normalized.removeValue(forKey: "targetIndex")
        if normalized["index"] == nil, let nested = nestedTo, let value = nested["index"] {
            normalized["index"] = value
        }
        if normalized["index"] == nil {
            let beforeKey =
                slideKeyValue(from: normalized["beforeSlideKey"]) ??
                slideKeyValue(from: normalized["before"]) ??
                slideKeyValue(from: target["beforeSlideKey"]) ??
                slideKeyValue(from: target["before"])
            if let referenceIndex = resolvedIndex(for: beforeKey) {
                normalized["index"] = referenceIndex
            }
        }
        if normalized["index"] == nil {
            let afterKey =
                slideKeyValue(from: normalized["afterSlideKey"]) ??
                slideKeyValue(from: normalized["after"]) ??
                slideKeyValue(from: target["afterSlideKey"]) ??
                slideKeyValue(from: target["after"])
            if let referenceIndex = resolvedIndex(for: afterKey) {
                let candidate = referenceIndex + 1
                normalized["index"] = min(max(candidate, 1), maxBoundIndex)
            }
        }
        normalized.removeValue(forKey: "beforeSlideKey")
        normalized.removeValue(forKey: "afterSlideKey")
        normalized.removeValue(forKey: "before")
        normalized.removeValue(forKey: "after")
        return normalized
    }

    private func normalizedBulletItems(from raw: Any?) -> [String]? {
        guard let raw else { return nil }

        if let items = raw as? [String] {
            let cleaned = items.map(cleanBulletLine).filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned
        }

        if let anyItems = raw as? [Any] {
            let cleaned = anyItems.compactMap { value -> String? in
                if let text = value as? String {
                    let line = cleanBulletLine(text)
                    return line.isEmpty ? nil : line
                }
                if let object = value as? [String: Any] {
                    if let text = object["text"] as? String {
                        let line = cleanBulletLine(text)
                        return line.isEmpty ? nil : line
                    }
                    if let text = object["value"] as? String {
                        let line = cleanBulletLine(text)
                        return line.isEmpty ? nil : line
                    }
                }
                if let number = value as? NSNumber {
                    let line = cleanBulletLine(number.stringValue)
                    return line.isEmpty ? nil : line
                }
                return nil
            }
            return cleaned.isEmpty ? nil : cleaned
        }

        if let objectItems = raw as? [String: Any] {
            if let direct = objectItems["items"], let normalized = normalizedBulletItems(from: direct) {
                return normalized
            }

            if let text = objectItems["text"] as? String {
                let cleaned = splitBulletText(text)
                return cleaned.isEmpty ? nil : cleaned
            }

            if let value = objectItems["value"] as? String {
                let cleaned = splitBulletText(value)
                return cleaned.isEmpty ? nil : cleaned
            }

            let cleaned = objectItems
                .sorted(by: { $0.key < $1.key })
                .compactMap { _, value -> String? in
                    if let text = value as? String {
                        let line = cleanBulletLine(text)
                        return line.isEmpty ? nil : line
                    }
                    if let number = value as? NSNumber {
                        let line = cleanBulletLine(number.stringValue)
                        return line.isEmpty ? nil : line
                    }
                    if let nested = value as? [String: Any] {
                        if let text = nested["text"] as? String ?? nested["value"] as? String {
                            let line = cleanBulletLine(text)
                            return line.isEmpty ? nil : line
                        }
                    }
                    return nil
                }
            return cleaned.isEmpty ? nil : cleaned
        }

        if let text = raw as? String {
            let cleaned = splitBulletText(text)
            return cleaned.isEmpty ? nil : cleaned
        }

        return nil
    }

    private func splitBulletText(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map(cleanBulletLine)
            .filter { !$0.isEmpty }
    }

    private func cleanBulletLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.replacingOccurrences(
            of: #"^([•\-\*]|\d+[\.\)])\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private func normalizeVerify(_ verify: [String: Any], for opName: String) -> [String: Any] {
        var normalized = verify

        if let exists = normalized.removeValue(forKey: "exists") as? Bool {
            switch opName {
            case "openPresentation", "attachToFrontPresentation":
                if normalized["presentationOpen"] == nil {
                    normalized["presentationOpen"] = exists
                }
            case "ensureSlide":
                if normalized["slideExists"] == nil {
                    normalized["slideExists"] = exists
                }
            case "ensureTextBox", "ensureBullets", "ensureImage", "ensureShape", "deleteElement", "setFrame", "setOpacity", "setZOrder", "setTextStyle", "setParagraphStyle", "setFillStyle", "setStrokeStyle":
                if normalized["elementExists"] == nil {
                    normalized["elementExists"] = exists
                }
            case "alignElements", "distributeElements":
                if normalized["slideExists"] == nil {
                    normalized["slideExists"] = exists
                }
            default:
                break
            }
        }

        return normalized
    }

    private func normalizeOperationName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        switch trimmed {
        case "removeSlide":
            return "deleteSlide"
        case "removeElement", "deleteObject", "removeObject":
            return "deleteElement"
        case "addTextBox", "createTextBox":
            return "ensureTextBox"
        case "resolveElement":
            return "resolveTarget"
        case "align", "alignObjects", "alignItems":
            return "alignElements"
        case "distribute", "distributeObjects", "distributeItems":
            return "distributeElements"
        case "move_before", "moveBefore", "moveSlideBefore":
            return "moveBefore"
        case "move_after", "moveAfter", "moveSlideAfter":
            return "moveAfter"
        default:
            return trimmed
        }
    }

    private func shouldAutoGenerateElementName(_ op: String) -> Bool {
        switch op {
        case "ensureTextBox", "ensureBullets", "ensureImage", "ensureShape":
            return true
        default:
            return false
        }
    }

    private func prefersSelectedElementName(_ op: String) -> Bool {
        switch op {
        case "deleteElement", "setFrame", "setOpacity", "setZOrder":
            return true
        default:
            return false
        }
    }

    private func healSlideReferences(
        in operations: [[String: Any]],
        contextSlides: [ContextSlide],
        knownBindings: [String: Int]
    ) -> [[String: Any]] {
        let rewritten = operations

        var ensured = Set(knownBindings.keys)
        if let currentSlideKey {
            ensured.insert(currentSlideKey)
        }

        var out: [[String: Any]] = []
        for raw in rewritten {
            guard let opName = raw["op"] as? String else {
                out.append(raw)
                continue
            }

            if needsSlideKey(opName),
               shouldAutoInjectEnsureSlide(for: opName),
               let target = raw["target"] as? [String: Any],
               let slideKey = target["slideKey"] as? String,
               !ensured.contains(slideKey) {
                var ensureArgs: [String: Any] = [:]
                if let knownIndex = knownBindings[slideKey] {
                    ensureArgs["index"] = knownIndex
                } else if let hintedIndex = slideIndexHint(from: slideKey) {
                    ensureArgs["index"] = hintedIndex
                } else if let matched = matchContextSlide(for: slideKey, slides: contextSlides) {
                    ensureArgs["index"] = matched.index
                    if !matched.title.isEmpty {
                        ensureArgs["title"] = matched.title
                    }
                }
                if ensureArgs["index"] == nil {
                    ensureArgs["layout"] = "Title & Bullets"
                }
                out.append(
                    op(
                        name: "ensureSlide",
                        target: ["slideKey": slideKey],
                        args: ensureArgs,
                        verify: ["slideExists": true]
                    )
                )
                ensured.insert(slideKey)
            }

            if opName == "ensureSlide" ||
                opName == "duplicateSlide" ||
                opName == "moveSlide" ||
                opName == "hideSlide" ||
                opName == "deleteSlide" ||
                opName == "assertState",
               let target = raw["target"] as? [String: Any],
               let slideKey = target["slideKey"] as? String {
                ensured.insert(slideKey)
            }

            out.append(raw)
        }

        return out
    }

    private struct ContextSlide {
        let index: Int
        let slideKey: String
        let title: String
        let slug: String
        let text: String
        let textSlug: String
        let anchors: [String]
    }

    private func contextSlides(from dom: PresentationDOMSnapshot, fallbackContext: String) -> [ContextSlide] {
        if !dom.slides.isEmpty {
            return dom.slides.map { slide in
                let fullText = ([slide.title, slide.body, slide.notes] + slide.textItems)
                    .joined(separator: " ")
                return ContextSlide(
                    index: slide.index,
                    slideKey: slide.slideKey,
                    title: slide.title,
                    slug: normalizeSlideToken(slide.title),
                    text: fullText,
                    textSlug: normalizeSlideToken(fullText),
                    anchors: slide.anchors
                )
            }
        }
        return parseContextSlides(from: fallbackContext)
    }

    private func parseContextSlides(from context: String) -> [ContextSlide] {
        guard !context.isEmpty else { return [] }
        let pattern = #"^slide\s+(\d+):\s+title=(.*?)\s+\|"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        return context
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> ContextSlide? in
                let text = String(line)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                guard let match = regex.firstMatch(in: text, options: [], range: range),
                      match.numberOfRanges >= 3,
                      let indexRange = Range(match.range(at: 1), in: text),
                      let titleRange = Range(match.range(at: 2), in: text),
                      let index = Int(text[indexRange]) else {
                    return nil
                }

                let title = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let textField = contextField("textItems", line: text) ?? contextField("text", line: text) ?? ""
                return ContextSlide(
                    index: index,
                    slideKey: "slide_\(index)",
                    title: title,
                    slug: normalizeSlideToken(title),
                    text: textField,
                    textSlug: normalizeSlideToken(textField),
                    anchors: []
                )
            }
    }

    private func contextField(_ name: String, line: String) -> String? {
        let marker = "\(name)="
        guard let startRange = line.range(of: marker) else { return nil }
        let afterStart = startRange.upperBound
        let tail = line[afterStart...]
        if let separator = tail.range(of: " | ") {
            return String(tail[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchContextSlide(for slideKey: String, slides: [ContextSlide]) -> ContextSlide? {
        let keySlug = normalizeSlideToken(slideKey)
        guard !keySlug.isEmpty else { return nil }

        if let direct = slides.first(where: { $0.slideKey == slideKey }) {
            return direct
        }

        if let exact = slides.first(where: { !$0.slug.isEmpty && $0.slug == keySlug }) {
            return exact
        }

        if let contains = slides.first(where: { !$0.slug.isEmpty && ($0.slug.contains(keySlug) || keySlug.contains($0.slug)) && max($0.slug.count, keySlug.count) >= 8 }) {
            return contains
        }

        return nil
    }

    private func matchContextSlide(forSelectorText selectorText: String, slides: [ContextSlide]) -> ContextSlide? {
        let token = normalizeSlideToken(selectorText)
        guard !token.isEmpty else { return nil }

        var best: (slide: ContextSlide, score: Int)?
        for slide in slides {
            let score = matchScore(token: token, slide: slide)
            guard score > 0 else { continue }

            if let currentBest = best {
                if score > currentBest.score || (score == currentBest.score && slide.index < currentBest.slide.index) {
                    best = (slide: slide, score: score)
                }
            } else {
                best = (slide: slide, score: score)
            }
        }

        return best?.slide
    }

    private func matchScore(token: String, slide: ContextSlide) -> Int {
        var score = 0
        let slideKeyToken = normalizeSlideToken(slide.slideKey)
        if !slideKeyToken.isEmpty {
            if slideKeyToken == token {
                score = max(score, 130)
            } else if slideKeyToken.contains(token) || token.contains(slideKeyToken) {
                score = max(score, 95)
            }
        }

        if !slide.slug.isEmpty {
            if slide.slug == token {
                score = max(score, 120)
            } else if slide.slug.hasPrefix(token) || token.hasPrefix(slide.slug) {
                score = max(score, 90)
            } else if slide.slug.contains(token) || token.contains(slide.slug) {
                score = max(score, 75)
            }
        }

        if !slide.textSlug.isEmpty {
            if slide.textSlug.hasPrefix(token) {
                score = max(score, 60)
            } else if slide.textSlug.contains(token) {
                score = max(score, 45)
            }
        }

        if slide.anchors.contains(where: { normalizeSlideToken($0) == token }) {
            score = max(score, 100)
        }

        return score
    }

    private func normalizeSlideToken(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: #"^s\d+_"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^slide_"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"_+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func userRequestedSave(_ input: String) -> Bool {
        let lowered = input.lowercased()
        return lowered.contains(" save") ||
            lowered.hasPrefix("save") ||
            lowered.contains("export") ||
            lowered.contains("persist")
    }

    private func droppedDestructiveOps(from diagnostics: [String]) -> Set<String> {
        var dropped = Set<String>()
        for diagnostic in diagnostics {
            guard diagnostic.contains("destructive action requires explicit confirmation") else {
                continue
            }
            if let range = diagnostic.range(of: #"compiler dropped ([A-Za-z0-9_]+):"#, options: .regularExpression) {
                let snippet = String(diagnostic[range])
                let op = snippet
                    .replacingOccurrences(of: "compiler dropped ", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !op.isEmpty {
                    dropped.insert(op)
                }
            }
        }
        return dropped
    }

    private func objectiveRequestsDestructiveChange(_ input: String) -> Bool {
        let lowered = input.lowercased()
        let destructiveVerbs = [
            "delete",
            "remove",
            "reset",
            "clear",
            "wipe"
        ]
        let destructiveTargets = [
            "slide",
            "slides",
            "deck",
            "presentation",
            "object",
            "element"
        ]
        let hasVerb = destructiveVerbs.contains { lowered.contains($0) }
        let hasTarget = destructiveTargets.contains { lowered.contains($0) }
        return hasVerb && hasTarget
    }

    private func normalizeDeicticSlideKey(_ raw: String) -> String {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        switch token {
        case "slide_after_this", "after_this", "after_this_slide", "next_slide", "slide_after_current":
            return "slide_after_current"
        case "this", "thisslide", "this_slide", "current", "currentslide", "current_slide", "active", "activeslide", "active_slide":
            return "current_slide"
        default:
            return raw
        }
    }

    private func resolveSlideKeyAlias(_ rawAlias: String, knownBindings: [String: Int]) -> String? {
        let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return nil }

        if let directIndex = knownBindings[alias] {
            return preferredSlideKey(for: directIndex, knownBindings: knownBindings)
        }

        let normalized = normalizeDeicticSlideKey(alias)
        if let normalizedIndex = knownBindings[normalized] {
            return preferredSlideKey(for: normalizedIndex, knownBindings: knownBindings)
        }

        if let hinted = slideIndexHint(from: alias) {
            return preferredSlideKey(for: hinted, knownBindings: knownBindings)
        }

        if let hinted = slideIndexHint(from: normalized) {
            return preferredSlideKey(for: hinted, knownBindings: knownBindings)
        }

        return normalized
    }

    private func rewriteDeicticSlideKey(
        opName: String,
        slideKey: String,
        args: [String: Any],
        aliasScopedSlideKeys: inout [String: String],
        activeSlideAliasTargets: inout [String: String]
    ) -> String {
        guard isPlanAliasSlideKey(slideKey) else {
            return slideKey
        }

        if opName == "ensureSlide",
           slideKey == "slide_after_current",
           let index = positiveInt(from: args["index"]) {
            let scoped = "\(slideKey)__index_\(index)"
            aliasScopedSlideKeys["\(slideKey)#\(index)"] = scoped
            activeSlideAliasTargets[slideKey] = scoped
            return scoped
        }

        if let index = positiveInt(from: args["index"]),
           let scoped = aliasScopedSlideKeys["\(slideKey)#\(index)"] {
            return scoped
        }

        if let active = activeSlideAliasTargets[slideKey] {
            return active
        }

        return slideKey
    }

    private func isPlanAliasSlideKey(_ value: String) -> Bool {
        switch value {
        case "current_slide", "slide_after_current":
            return true
        default:
            return false
        }
    }

    private func canonicalSlideKeyForExecution(
        opName: String,
        slideKey: String,
        knownBindings: [String: Int]
    ) -> String {
        let key = slideKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return slideKey }

        // For creation flows we keep the deictic alias so scoped alias rewriting can work.
        if opName == "ensureSlide", key == "slide_after_current" {
            return key
        }

        let normalized = normalizeDeicticSlideKey(key)
        if isPlanAliasSlideKey(normalized),
           let index = knownBindings[normalized] ?? knownBindings[key] {
            return preferredSlideKey(for: index, knownBindings: knownBindings)
        }

        if let keyIndex = knownBindings[key] {
            if isConcreteSlideAlias(key) {
                return preferredSlideKey(for: keyIndex, knownBindings: knownBindings)
            }
            return key
        }

        if let index = knownBindings[normalized] {
            return preferredSlideKey(for: index, knownBindings: knownBindings)
        }

        return key
    }

    private func preferredSlideKey(for index: Int, knownBindings: [String: Int]) -> String {
        guard index > 0 else { return "slide_1" }
        let candidates = knownBindings
            .filter { key, value in
                value == index && !isReservedPlannerAlias(key)
            }
            .map(\.key)
            .sorted()

        if let stable = candidates.first(where: { isStableSlideAlias($0) }) {
            return stable
        }
        if let nonConcrete = candidates.first(where: { !isConcreteSlideAlias($0) }) {
            return nonConcrete
        }
        return "slide_\(index)"
    }

    private func hasEquivalentAssert(alreadyIn operations: [[String: Any]], candidate: [String: Any]) -> Bool {
        guard (candidate["op"] as? String) == "assertState",
              let candidateTarget = candidate["target"] as? [String: Any] else {
            return false
        }

        let candidateSlideKey = candidateTarget["slideKey"] as? String
        let candidateElementName = candidateTarget["elementName"] as? String
        let candidateVerify = candidate["verify"] as? [String: Any] ?? [:]
        let candidateSlideExists = candidateVerify["slideExists"] as? Bool
        let candidateElementExists = candidateVerify["elementExists"] as? Bool

        return operations.contains { existing in
            guard (existing["op"] as? String) == "assertState",
                  let existingTarget = existing["target"] as? [String: Any] else {
                return false
            }

            let existingSlideKey = existingTarget["slideKey"] as? String
            let existingElementName = existingTarget["elementName"] as? String
            guard existingSlideKey == candidateSlideKey,
                  existingElementName == candidateElementName else {
                return false
            }

            let existingVerify = existing["verify"] as? [String: Any] ?? [:]
            if existingVerify.isEmpty || candidateVerify.isEmpty {
                return true
            }
            let existingSlideExists = existingVerify["slideExists"] as? Bool
            let existingElementExists = existingVerify["elementExists"] as? Bool
            return existingSlideExists == candidateSlideExists &&
                existingElementExists == candidateElementExists
        }
    }

    private func positiveInt(from raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let value = raw as? Int, value > 0 {
            return value
        }
        if let value = raw as? NSNumber {
            let intValue = value.intValue
            return intValue > 0 ? intValue : nil
        }
        if let text = raw as? String,
           let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 0 {
            return value
        }
        return nil
    }

    private func isSelectionAlias(_ raw: String) -> Bool {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        switch token {
        case "this", "selected", "selection", "current_selection", "active_selection", "this_element", "this_object":
            return true
        default:
            let patterns = [
                #"^selected_\d+$"#,
                #"^selected\d+$"#,
                #"^__ksk_selected__(?:_)?\d+$"#
            ]
            return patterns.contains { pattern in
                token.range(of: pattern, options: .regularExpression) != nil
            }
        }
    }

    private func selectedElementSentinel(from raw: String) -> String? {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if token == "selected" || token == "selection" || token == "this" || token == "this_element" || token == "this_object" {
            return "__ksk_selected__1"
        }

        let patterns = [
            #"^selected_(\d+)$"#,
            #"^selected(\d+)$"#,
            #"^__ksk_selected__(?:_)?(\d+)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: token, options: [], range: NSRange(token.startIndex..<token.endIndex, in: token)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: token),
                  let index = Int(token[range]),
                  index > 0 else {
                continue
            }
            return "__ksk_selected__\(index)"
        }

        return nil
    }

    private func normalizeTargetShape(_ target: [String: Any]) -> [String: Any] {
        var normalized = target
        if let nestedSlide = normalized["slide"] as? [String: Any] {
            let slideMergeKeys = [
                "slideKey",
                "fromSlideKey",
                "toSlideKey",
                "slideKeyAlias",
                "slideIndex",
                "fromSlideIndex",
                "toSlideIndex",
                "index",
                "title"
            ]
            for key in slideMergeKeys where normalized[key] == nil {
                if let value = nestedSlide[key] {
                    normalized[key] = value
                }
            }
            if normalized["slideKey"] == nil {
                if let key = nestedSlide["key"] {
                    normalized["slideKey"] = key
                } else if let key = nestedSlide["id"] {
                    normalized["slideKey"] = key
                }
            }
            normalized.removeValue(forKey: "slide")
        }

        if let nestedElement = normalized["element"] as? [String: Any] {
            let elementMergeKeys = [
                "elementName",
                "name",
                "useSelection",
                "isSelected",
                "elementType",
                "type",
                "role",
                "textContains",
                "textPrefix",
                "matchText",
                "boundsNear",
                "index"
            ]

            for key in elementMergeKeys where normalized[key] == nil {
                if let value = nestedElement[key] {
                    normalized[key] = value
                }
            }

            if normalized["elementName"] == nil, let name = nestedElement["name"] {
                normalized["elementName"] = name
            }

            normalized.removeValue(forKey: "element")
        }

        return normalized
    }

    private func normalizeArgsShape(_ args: [String: Any]) -> [String: Any] {
        var normalized = args

        if let nestedSlide = normalized["slide"] as? [String: Any] {
            let slideMergeKeys = [
                "slideKey",
                "fromSlideKey",
                "toSlideKey",
                "slideIndex",
                "fromSlideIndex",
                "toSlideIndex",
                "index"
            ]
            for key in slideMergeKeys where normalized[key] == nil {
                if let value = nestedSlide[key] {
                    normalized[key] = value
                }
            }
            normalized.removeValue(forKey: "slide")
        }

        if let nestedElement = normalized["element"] as? [String: Any] {
            let elementMergeKeys = [
                "elementName",
                "name",
                "useSelection",
                "isSelected",
                "elementType",
                "type",
                "role",
                "textContains",
                "textPrefix",
                "matchText",
                "boundsNear",
                "index"
            ]
            for key in elementMergeKeys where normalized[key] == nil {
                if let value = nestedElement[key] {
                    normalized[key] = value
                }
            }
            if normalized["elementName"] == nil, let name = nestedElement["name"] {
                normalized["elementName"] = name
            }
            normalized.removeValue(forKey: "element")
        }

        return normalized
    }

    private func userRequestedFrameControl(_ input: String) -> Bool {
        let lowered = input.lowercased()
        let cues = [
            "move",
            "position",
            "x:",
            "y:",
            "left",
            "right",
            "top",
            "bottom",
            "center",
            "resize",
            "size",
            "width",
            "height",
            "frame"
        ]
        return cues.contains { lowered.contains($0) }
    }

    private func needsSlideKey(_ op: String) -> Bool {
        PlanOperationContract.needsSlideKey(op)
    }

    private func needsElementName(_ op: String) -> Bool {
        PlanOperationContract.needsElementName(op)
    }

    private func shouldAutoInjectEnsureSlide(for op: String) -> Bool {
        // Never auto-create slides for unknown aliases.
        // Unknown targets should fail fast and go back through planner repair,
        // otherwise we risk destructive "phantom slide" creation.
        _ = op
        return false
    }

    private func slideIndexHint(from slideKey: String) -> Int? {
        let lowered = slideKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?:slide[_\-]?|s)(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: lowered, options: [], range: NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)),
              let range = Range(match.range(at: 1), in: lowered),
              let index = Int(lowered[range]),
              index > 0 else {
            return nil
        }
        return index
    }

    private func updateWorkingState(from operations: [[String: Any]]) {
        for op in operations.reversed() {
            if let target = op["target"] as? [String: Any], let slideKey = target["slideKey"] as? String {
                currentSlideKey = slideKey
                return
            }
        }
    }

    private func execute(operations: [[String: Any]]) throws -> ExecutionReport {
        guard !operations.isEmpty else {
            throw ValidationError(message: "No operations to execute")
        }

        let payload: [String: Any] = [
            "meta": [
                "irVersion": irVersion,
                "safeMode": true,
                "confirmedOpIds": [] as [String]
            ],
            "operations": operations
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let parsed = try JSONDecoder().decode(IRPlan.self, from: data)
        let validated = try validate(plan: parsed)

        let executor = PlanExecutor(adapter: adapter, axFallback: fallback)
        return try executor.execute(validated)
    }

    private func op(
        name: String,
        target: [String: Any],
        args: [String: Any],
        verify: [String: Any]
    ) -> [String: Any] {
        defer { opSequence += 1 }
        return [
            "op": name,
            "target": target,
            "args": args,
            "verify": verify,
            "meta": [
                "opId": String(format: "chat-%03d", opSequence)
            ]
        ]
    }

    private func progressLines(from report: ExecutionReport) -> [String] {
        var lines = report.entries.map {
            "\($0.op) -> \($0.status) (attempt \($0.attempt), driver \($0.driverUsed.rawValue))"
        }

        lines.append("summary: ok=\(report.summary.ok), failed=\(report.summary.failed), retries=\(report.summary.retried)")
        return lines
    }

    private func buildPlannerFeedback(
        objective: String,
        cycle: Int,
        operations: [[String: Any]],
        report: ExecutionReport,
        knownSlideBindings: [String: Int]
    ) -> String {
        let summary = "ok=\(report.summary.ok), failed=\(report.summary.failed), retries=\(report.summary.retried), fallback=\(report.summary.fallbackCount)"
        let opNames = operations.compactMap { $0["op"] as? String }.joined(separator: ", ")
        let slideKeys = extractSlideKeys(from: operations).sorted().joined(separator: ", ")
        let knownBindingsText = knownSlideBindings
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }
            .map { "\($0.key)->slide \($0.value)" }
            .joined(separator: ", ")
        return """
        Objective: \(objective)
        Cycle: \(cycle)
        Result: success
        Ops attempted: \(opNames)
        Slide keys touched: \(slideKeys.isEmpty ? "none" : slideKeys)
        Execution summary: \(summary)
        Known slide bindings: \(knownBindingsText.isEmpty ? "none" : knownBindingsText)
        Continue only if objective is still not fully satisfied in current context.
        """
    }

    private func buildPlannerFeedback(
        objective: String,
        cycle: Int,
        operations: [[String: Any]],
        errorMessage: String,
        repeatedFingerprintCount: Int = 0,
        knownSlideBindings: [String: Int] = [:]
    ) -> String {
        let opNames = operations.compactMap { $0["op"] as? String }.joined(separator: ", ")
        let slideKeys = extractSlideKeys(from: operations).sorted().joined(separator: ", ")
        let knownBindingsText = knownSlideBindings
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }
            .map { "\($0.key)->slide \($0.value)" }
            .joined(separator: ", ")
        let loopHint = repeatedFingerprintCount >= 2
            ? "Loop detected: plan kept repeating. You must target additional slideKeys and avoid reapplying the same operations to one slide."
            : "No loop pattern detected."
        return """
        Objective: \(objective)
        Cycle: \(cycle)
        Result: failure
        Ops attempted before failure: \(opNames)
        Slide keys touched: \(slideKeys.isEmpty ? "none" : slideKeys)
        Known slide bindings: \(knownBindingsText.isEmpty ? "none" : knownBindingsText)
        Error: \(errorMessage)
        \(loopHint)
        Repair the plan to avoid this failure and continue toward objective completion.
        """
    }

    private func buildProtocolGateFeedback(
        objective: String,
        cycle: Int,
        operations: [[String: Any]],
        violations: [PlanProtocolViolation],
        knownSlideBindings: [String: Int]
    ) -> String {
        let opNames = operations.compactMap { $0["op"] as? String }.joined(separator: ", ")
        let slideKeys = extractSlideKeys(from: operations).sorted().joined(separator: ", ")
        let knownBindingsText = knownSlideBindings
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }
            .map { "\($0.key)->slide \($0.value)" }
            .joined(separator: ", ")
        let violationText = PlanProtocolGate.summarize(violations, maxCount: 10)
        return """
        Objective: \(objective)
        Cycle: \(cycle)
        Result: protocol_rejected
        Ops proposed: \(opNames)
        Slide keys proposed: \(slideKeys.isEmpty ? "none" : slideKeys)
        Known slide bindings: \(knownBindingsText.isEmpty ? "none" : knownBindingsText)
        Contract violations: \(violationText)
        Return a corrected plan using only canonical fields:
        - put slideKey/elementName in target (never in args)
        - selector keys: role/type/textEquals/textContains/textPrefix/index/isSelected/boundsNear
        - resolveTarget with selector.type='slide' may omit target.elementName
        - do not use kind/textType/existingSlideKey/slideTitleEquals
        """
    }

    private func buildScopeDriftFeedback(
        objective: String,
        cycle: Int,
        operations: [[String: Any]],
        unexpectedSlideKeys: [String],
        knownSlideBindings: [String: Int],
        objectiveSlideBudget: Int?
    ) -> String {
        let opNames = operations.compactMap { $0["op"] as? String }.joined(separator: ", ")
        let slideKeys = extractSlideKeys(from: operations).sorted().joined(separator: ", ")
        let knownBindingsText = knownSlideBindings
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value }
            .map { "\($0.key)->slide \($0.value)" }
            .joined(separator: ", ")
        let budgetText = objectiveSlideBudget.map(String.init) ?? "unspecified"
        let unexpected = unexpectedSlideKeys.joined(separator: ", ")
        return """
        Objective: \(objective)
        Cycle: \(cycle)
        Result: scope_rejected
        Ops proposed: \(opNames)
        Slide keys proposed: \(slideKeys.isEmpty ? "none" : slideKeys)
        Known slide bindings: \(knownBindingsText.isEmpty ? "none" : knownBindingsText)
        Objective slide budget: \(budgetText)
        Unexpected/over-budget slide keys: \(unexpected.isEmpty ? "none" : unexpected)
        Return a corrected plan that stays within objective scope:
        - do not introduce new slide aliases beyond objective intent
        - reuse known target slide aliases when retitling/updating
        - return status=\"complete\" when objective is already satisfied
        """
    }

    private func extractSlideKeys(from operations: [[String: Any]]) -> Set<String> {
        Set(
            operations.compactMap { raw -> String? in
                guard let target = raw["target"] as? [String: Any] else { return nil }
                return target["slideKey"] as? String
            }
        )
    }

    private func fingerprint(operations: [[String: Any]]) -> String {
        let normalized = operations.map { raw -> String in
            let op = (raw["op"] as? String) ?? "?"
            let target = raw["target"] as? [String: Any] ?? [:]
            let slideKey = (target["slideKey"] as? String) ?? "-"
            let elementName = (target["elementName"] as? String) ?? "-"
            return "\(op)|\(slideKey)|\(elementName)"
        }
        return normalized.joined(separator: "||")
    }

    private func normalizeFailureSignature(_ message: String) -> String {
        var signature = message.lowercased()
        signature = signature.replacingOccurrences(of: #"chat-\d+"#, with: "chat-#", options: .regularExpression)
        signature = signature.replacingOccurrences(of: #"slide[_\-]?\d+"#, with: "slide_#", options: .regularExpression)
        signature = signature.replacingOccurrences(of: #"s\d+_[a-z0-9_]+"#, with: "s#_key", options: .regularExpression)
        signature = signature.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        signature = signature.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return signature.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func failureId(cycle: Int, sequence: Int) -> String {
        String(format: "ERR-c%02d-%03d", max(cycle, 0), max(sequence, 0))
    }

    private func classifyFailure(_ error: Error, stage: FailureStage) -> FailureClassification {
        if let codexError = error as? CodexCLIError {
            return FailureClassification(
                source: .codex,
                stage: stage,
                code: codexCode(codexError),
                message: codexError.localizedDescription,
                retryWithCodex: true
            )
        }
        if let plannerError = error as? LLMPlannerError {
            return FailureClassification(
                source: .codex,
                stage: stage,
                code: plannerCode(plannerError),
                message: plannerError.localizedDescription,
                retryWithCodex: true
            )
        }
        if let contextError = error as? ContextCollectorError {
            return FailureClassification(
                source: .keynote_script,
                stage: stage,
                code: "CONTEXT_SCRIPT_FAILED",
                message: contextError.localizedDescription,
                retryWithCodex: true
            )
        }
        if let adapterError = error as? AdapterError {
            let lowered = "\(adapterError.code) \(adapterError.message)".lowercased()
            if isKeynoteScriptFailureMessage(lowered) {
                return FailureClassification(
                    source: .keynote_script,
                    stage: stage,
                    code: adapterError.code,
                    message: adapterError.localizedDescription,
                    retryWithCodex: true
                )
            }
            if isSidekickFailureCode(adapterError.code) || isSidekickFailureMessage(lowered) {
                return FailureClassification(
                    source: .keynotesidekick,
                    stage: stage,
                    code: adapterError.code,
                    message: adapterError.localizedDescription,
                    retryWithCodex: false
                )
            }
            return FailureClassification(
                source: .unknown,
                stage: stage,
                code: adapterError.code,
                message: adapterError.localizedDescription,
                retryWithCodex: true
            )
        }
        if error is ValidationError || error is SafeModeViolationError || error is ConfirmationRequiredError {
            return FailureClassification(
                source: .keynotesidekick,
                stage: stage,
                code: "VALIDATION",
                message: error.localizedDescription,
                retryWithCodex: false
            )
        }
        if error is VerificationError {
            return FailureClassification(
                source: .unknown,
                stage: stage,
                code: "VERIFICATION",
                message: error.localizedDescription,
                retryWithCodex: true
            )
        }
        return FailureClassification(
            source: .unknown,
            stage: stage,
            code: "UNKNOWN",
            message: error.localizedDescription,
            retryWithCodex: true
        )
    }

    private func logFailure(note: (String) -> Void, id: String, classification: FailureClassification) {
        let action = classification.retryWithCodex ? "retry_with_codex" : "stop_and_report"
        note("FAILURE \(id): type=\(classification.source.rawValue) stage=\(classification.stage.rawValue) code=\(classification.code) action=\(action)")
        let json: [String: Any] = [
            "id": id,
            "type": classification.source.rawValue,
            "stage": classification.stage.rawValue,
            "code": classification.code,
            "action": action,
            "message": classification.message
        ]
        note("FAILURE_JSON \(compactJSON(from: json))")
    }

    private func codexCode(_ error: CodexCLIError) -> String {
        switch error {
        case .commandNotFound:
            return "CODEX_COMMAND_NOT_FOUND"
        case .timedOut:
            return "CODEX_TIMEOUT"
        case .cancelled:
            return "CODEX_CANCELLED"
        case .executionFailed:
            return "CODEX_EXECUTION_FAILED"
        }
    }

    private func plannerCode(_ error: LLMPlannerError) -> String {
        switch error {
        case .requestFailed:
            return "LLM_REQUEST_FAILED"
        case .missingOutputText:
            return "LLM_MISSING_OUTPUT"
        case .invalidJSONPayload:
            return "LLM_INVALID_JSON"
        }
    }

    private func isKeynoteScriptFailureMessage(_ lowered: String) -> Bool {
        lowered.contains("keynote got an error") ||
            lowered.contains("appleevent handler failed") ||
            lowered.contains("[process_failed]") ||
            lowered.contains("execution error:") ||
            lowered.contains("can't make slide before slide") ||
            lowered.contains("into type type")
    }

    private func isSidekickFailureCode(_ code: String) -> Bool {
        let blocked: Set<String> = [
            "MISSING_SLIDE",
            "PARSE_ERROR",
            "ALIGNMENT_INPUT",
            "ALIGNMENT_MODE",
            "UNSUPPORTED_STYLE",
            "UNSUPPORTED_ALIGNMENT",
            "UNSUPPORTED_DISTRIBUTION",
            "UNSUPPORTED_SELECTOR",
            "ROLLBACK_UNSUPPORTED",
            "VALIDATION_ERROR",
            "TARGET_NOT_FOUND"
        ]
        return blocked.contains(code)
    }

    private func isSidekickFailureMessage(_ lowered: String) -> Bool {
        lowered.contains("must be a non-empty string") ||
            lowered.contains("must be a string array") ||
            lowered.contains("unsupported") ||
            lowered.contains("run ensureslide first") ||
            lowered.contains("no operations to execute")
    }

    private func failureContextSignature(context: String, focus: PresentationFocusContext) -> String {
        let selectedSummary = focus.selectedItems
            .map { "\($0.type)|\($0.name)|\($0.textSnippet.prefix(64))" }
            .joined(separator: "||")
        return "slide=\(focus.currentSlideIndex ?? -1)|title=\(focus.currentSlideTitle)|selected=\(selectedSummary)|context=\(context)"
    }

    private func updateStagnation(
        contextSignature: String,
        lastSignature: inout String?,
        count: inout Int
    ) {
        if lastSignature == contextSignature {
            count += 1
        } else {
            lastSignature = contextSignature
            count = 1
        }
    }

    private func chooseContextLevel(
        objective: String,
        cycle: Int,
        lastFailure: String?,
        repeatedFingerprintCount: Int
    ) -> ContextDetailLevel {
        let lowered = objective.lowercased()
        let fullDeckCues = [
            "all slides",
            "several slides",
            "multiple slides",
            "across slides",
            "entire deck",
            "whole deck",
            "every slide",
            "outline",
            "revise slides",
            "following slides",
            "preface",
            "before the",
            "precede"
        ]

        if fullDeckCues.contains(where: { lowered.contains($0) }) {
            return .full
        }
        if repeatedFingerprintCount >= 2 {
            return .full
        }
        if cycle > 1, let lastFailure, !lastFailure.isEmpty {
            return .full
        }
        return .summary
    }

    private func nextSlideKey(fromTitle title: String) -> String {
        let cleaned = title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let slug = cleaned.isEmpty ? "slide" : cleaned
        defer { slideSequence += 1 }
        return String(format: "s%03d_%@", slideSequence, slug)
    }

    private func nextElementName(slideKey: String, role: String, slug: String) -> String {
        defer { elementSequence += 1 }
        let suffix = String(format: "%04x", elementSequence)
        return "\(slideKey)__\(role)__\(slug)__\(suffix)"
    }

    private func completionTargetsSatisfied(
        _ completionCheck: PlanCompletionCheck?,
        knownBindings: [String: Int]
    ) -> Bool {
        guard let completionCheck else { return false }
        let targets = completionCheck.targetSlideKeys
        guard !targets.isEmpty else { return false }

        let maxKnownIndex = knownBindings.values.max() ?? 0
        for targetKey in targets {
            if let index = knownBindings[targetKey], index > 0 {
                continue
            }

            let normalized = normalizeDeicticSlideKey(targetKey)
            if let index = knownBindings[normalized], index > 0 {
                continue
            }

            if let hintedIndex = slideIndexHint(from: targetKey),
               hintedIndex > 0,
               hintedIndex <= maxKnownIndex {
                continue
            }

            return false
        }

        return true
    }

    private func prettyJSON(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }

    private func compactJSON(from object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }
}
