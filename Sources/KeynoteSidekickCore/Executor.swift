import Foundation

public final class PlanExecutor {
    private let adapter: KeynoteAutomationAdapter
    private let axFallback: AXFallbackAdapter?
    private let logger: ExecutionLogger

    public init(adapter: KeynoteAutomationAdapter, axFallback: AXFallbackAdapter? = nil, logger: ExecutionLogger = ExecutionLogger()) {
        self.adapter = adapter
        self.axFallback = axFallback
        self.logger = logger
    }

    public func execute(_ plan: ValidatedPlan) throws -> ExecutionReport {
        for operation in plan.operations {
            try run(operation: operation, planMeta: plan.meta)
        }
        return logger.report()
    }

    private func enforceSafety(operation: PlanOperation, planMeta: PlanMeta) throws {
        guard operation.meta.requiresConfirm else { return }

        if planMeta.safeMode {
            throw SafeModeViolationError(
                opId: operation.meta.opId,
                message: "safeMode rejected destructive op \(operation.name.rawValue)"
            )
        }

        if !planMeta.confirmedOpIds.contains(operation.meta.opId) {
            throw ConfirmationRequiredError(
                opId: operation.meta.opId,
                message: operation.meta.confirmationText ?? "Operation \(operation.name.rawValue) requires explicit confirmation"
            )
        }
    }

    private func run(operation: PlanOperation, planMeta: PlanMeta) throws {
        try enforceSafety(operation: operation, planMeta: planMeta)

        if case .transaction(let operations, let rollbackOnFailure) = operation.payload {
            try runTransaction(
                operation: operation,
                operations: operations,
                rollbackOnFailure: rollbackOnFailure,
                planMeta: planMeta
            )
            return
        }

        var attempt = 0
        var finalError: Error?
        let maxAttempts = max(operation.meta.maxRetries + 1, 1)

        while attempt < maxAttempts {
            attempt += 1
            do {
                let driver = try executeOperation(operation)
                let verification = try verify(operation)
                guard verification.passed else {
                    throw VerificationError(message: verification.messages.joined(separator: " | "))
                }

                logger.append(OperationLogEntry(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    opId: operation.meta.opId,
                    op: operation.name.rawValue,
                    status: "ok",
                    attempt: attempt,
                    driverUsed: driver,
                    driftDetected: false,
                    resyncPerformed: false,
                    resyncAmbiguous: false,
                    verification: verification,
                    error: nil
                ))
                refreshBindingsAfterEveryOperation()
                return
            } catch {
                finalError = error
                logger.append(OperationLogEntry(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    opId: operation.meta.opId,
                    op: operation.name.rawValue,
                    status: "failed",
                    attempt: attempt,
                    driverUsed: adapter.defaultDriver,
                    driftDetected: false,
                    resyncPerformed: false,
                    resyncAmbiguous: false,
                    verification: nil,
                    error: String(describing: error)
                ))
                if attempt < maxAttempts {
                    try? adapter.recoverAfterError()
                }
            }
        }

        let resyncOutcome = try tryResync(operation: operation)
        if resyncOutcome.performed {
            do {
                let driver = try executeOperation(operation)
                let verification = try verify(operation)
                guard verification.passed else {
                    throw VerificationError(message: verification.messages.joined(separator: " | "))
                }

                logger.append(OperationLogEntry(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    opId: operation.meta.opId,
                    op: operation.name.rawValue,
                    status: "ok",
                    attempt: maxAttempts + 1,
                    driverUsed: driver,
                    driftDetected: true,
                    resyncPerformed: true,
                    resyncAmbiguous: resyncOutcome.ambiguous,
                    verification: verification,
                    error: nil
                ))
                refreshBindingsAfterEveryOperation()
                return
            } catch {
                finalError = error
                logger.append(OperationLogEntry(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    opId: operation.meta.opId,
                    op: operation.name.rawValue,
                    status: "failed",
                    attempt: maxAttempts + 1,
                    driverUsed: adapter.defaultDriver,
                    driftDetected: true,
                    resyncPerformed: true,
                    resyncAmbiguous: resyncOutcome.ambiguous,
                    verification: nil,
                    error: String(describing: error)
                ))
            }
        }

        if let finalError {
            throw AdapterError(
                code: "OP_EXECUTION_FAILED",
                message: "\(operation.name.rawValue) (\(operation.meta.opId)) failed: \(finalError.localizedDescription)"
            )
        }
        throw AdapterError(code: "EXECUTION_FAILED", message: "Unknown execution failure for \(operation.meta.opId)")
    }

    private func runTransaction(
        operation: PlanOperation,
        operations: [PlanOperation],
        rollbackOnFailure: Bool,
        planMeta: PlanMeta
    ) throws {
        var completed = 0
        do {
            for nested in operations {
                try run(operation: nested, planMeta: planMeta)
                completed += 1
            }

            let verification = try verify(operation)
            guard verification.passed else {
                throw VerificationError(message: verification.messages.joined(separator: " | "))
            }

            logger.append(OperationLogEntry(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                opId: operation.meta.opId,
                op: operation.name.rawValue,
                status: "ok",
                attempt: 1,
                driverUsed: adapter.defaultDriver,
                driftDetected: false,
                resyncPerformed: false,
                resyncAmbiguous: false,
                verification: verification,
                error: nil
            ))
            refreshBindingsAfterEveryOperation()
        } catch {
            var rollbackMessage = "rollback disabled"
            if rollbackOnFailure && completed > 0 {
                do {
                    try adapter.rollback(steps: completed)
                    rollbackMessage = "rollback applied (\(completed) undo step(s))"
                } catch {
                    rollbackMessage = "rollback failed: \(error.localizedDescription)"
                }
            }

            logger.append(OperationLogEntry(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                opId: operation.meta.opId,
                op: operation.name.rawValue,
                status: "failed",
                attempt: 1,
                driverUsed: adapter.defaultDriver,
                driftDetected: false,
                resyncPerformed: false,
                resyncAmbiguous: false,
                verification: nil,
                error: "\(error.localizedDescription) | \(rollbackMessage)"
            ))

            throw AdapterError(
                code: "TRANSACTION_FAILED",
                message: "\(operation.name.rawValue) (\(operation.meta.opId)) failed after \(completed) completed nested op(s): \(error.localizedDescription) | \(rollbackMessage)"
            )
        }
    }

    private func executeOperation(_ operation: PlanOperation) throws -> DriverUsed {
        switch operation.payload {
        case .openPresentation(let path):
            try adapter.openPresentation(path: path)
            return adapter.defaultDriver
        case .attachToFrontPresentation:
            try adapter.attachToFrontPresentation()
            return adapter.defaultDriver
        case .savePresentation:
            try adapter.savePresentation()
            return adapter.defaultDriver
        case .transaction:
            return adapter.defaultDriver
        case .assertState:
            return adapter.defaultDriver
        case .resolveTarget(let slideKey, let elementName, let selector):
            guard let resolved = try adapter.resolveElement(slideKey: slideKey, selector: selector),
                  let resolvedName = resolved.name,
                  !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AdapterError(
                    code: "TARGET_NOT_FOUND",
                    message: "Unable to resolve target '\(elementName)' on \(slideKey)"
                )
            }

            let match = ResyncMatch(
                target: ResyncTarget(
                    elementName: elementName,
                    type: selector.type,
                    frame: selector.boundsNear,
                    text: selector.textPrefix ?? selector.textContains
                ),
                element: SlideElementDescriptor(
                    name: resolvedName,
                    type: resolved.type,
                    frame: resolved.frame,
                    textSnippet: resolved.textSnippet
                ),
                mode: .fallback
            )
            try adapter.applyResyncBindings(slideKey: slideKey, matches: [match])
            return adapter.defaultDriver
        case .ensureSlide(let slideKey, let layout, let index, let title):
            try adapter.ensureSlide(slideKey: slideKey, layout: layout, index: index, title: title)
            refreshBindingsAfterStructuralSlideMutation()
            return adapter.defaultDriver
        case .duplicateSlide(let fromSlideKey, let slideKey, let index, let title):
            try adapter.duplicateSlide(fromSlideKey: fromSlideKey, slideKey: slideKey, index: index, title: title)
            refreshBindingsAfterStructuralSlideMutation()
            return adapter.defaultDriver
        case .deleteSlide(let slideKey):
            try adapter.deleteSlide(slideKey: slideKey)
            refreshBindingsAfterStructuralSlideMutation()
            return adapter.defaultDriver
        case .hideSlide(let slideKey, let hidden):
            try adapter.hideSlide(slideKey: slideKey, hidden: hidden)
            refreshBindingsAfterStructuralSlideMutation()
            return adapter.defaultDriver
        case .moveSlide(let slideKey, let index):
            try adapter.moveSlide(slideKey: slideKey, index: index)
            refreshBindingsAfterStructuralSlideMutation()
            return adapter.defaultDriver
        case .ensureTextBox(let slideKey, let elementName, let text, let frame, let role):
            try adapter.ensureTextBox(slideKey: slideKey, elementName: elementName, text: text, frame: frame, role: role)
            return adapter.defaultDriver
        case .ensureBullets(let slideKey, let elementName, let items, let frame):
            try adapter.ensureBullets(slideKey: slideKey, elementName: elementName, items: items, frame: frame)
            return adapter.defaultDriver
        case .ensureImage(let slideKey, let elementName, let path, let frame):
            try adapter.ensureImage(slideKey: slideKey, elementName: elementName, path: path, frame: frame)
            return adapter.defaultDriver
        case .ensureShape(let slideKey, let elementName, let shapeType, let text, let frame):
            try adapter.ensureShape(slideKey: slideKey, elementName: elementName, shapeType: shapeType, text: text, frame: frame)
            return adapter.defaultDriver
        case .deleteElement(let slideKey, let elementName):
            try adapter.deleteElement(slideKey: slideKey, elementName: elementName)
            return adapter.defaultDriver
        case .setFrame(let slideKey, let elementName, let frame):
            try adapter.setFrame(slideKey: slideKey, elementName: elementName, frame: frame)
            return adapter.defaultDriver
        case .setOpacity(let slideKey, let elementName, let opacity):
            try adapter.setOpacity(slideKey: slideKey, elementName: elementName, opacity: opacity)
            return adapter.defaultDriver
        case .setZOrder(let slideKey, let elementName, let mode):
            do {
                try adapter.setZOrder(slideKey: slideKey, elementName: elementName, mode: mode)
                return adapter.defaultDriver
            } catch {
                guard let fallback = axFallback else { throw error }
                try fallback.setZOrder(slideKey: slideKey, elementName: elementName, mode: mode)
                return .ax
            }
        case .setPresenterNotes(let slideKey, let text):
            do {
                try adapter.setPresenterNotes(slideKey: slideKey, text: text)
                return adapter.defaultDriver
            } catch {
                guard let fallback = axFallback else { throw error }
                try fallback.setPresenterNotes(slideKey: slideKey, text: text)
                return .ax
            }
        case .setTextStyle(let slideKey, let elementName, let style):
            try adapter.setTextStyle(slideKey: slideKey, elementName: elementName, style: style)
            return adapter.defaultDriver
        case .setParagraphStyle(let slideKey, let elementName, let style):
            try adapter.setParagraphStyle(slideKey: slideKey, elementName: elementName, style: style)
            return adapter.defaultDriver
        case .setFillStyle(let slideKey, let elementName, let style):
            try adapter.setFillStyle(slideKey: slideKey, elementName: elementName, style: style)
            return adapter.defaultDriver
        case .setStrokeStyle(let slideKey, let elementName, let style):
            try adapter.setStrokeStyle(slideKey: slideKey, elementName: elementName, style: style)
            return adapter.defaultDriver
        case .alignElements(let slideKey, let elementNames, let alignment, let useSelection):
            try adapter.alignElements(
                slideKey: slideKey,
                elementNames: elementNames,
                alignment: alignment,
                useSelection: useSelection
            )
            return adapter.defaultDriver
        case .distributeElements(let slideKey, let elementNames, let axis, let spacing, let useSelection):
            try adapter.distributeElements(
                slideKey: slideKey,
                elementNames: elementNames,
                axis: axis,
                spacing: spacing,
                useSelection: useSelection
            )
            return adapter.defaultDriver
        }
    }

    private func refreshBindingsAfterStructuralSlideMutation() {
        // Rebind symbolic slide keys after structural mutations so subsequent ops
        // in the same plan resolve against current deck indices.
        _ = try? adapter.refreshSlideBindings()
    }

    private func refreshBindingsAfterEveryOperation() {
        // Keep slide-key bindings synchronized with the live deck after each op.
        _ = try? adapter.refreshSlideBindings()
    }

    private struct ResyncOutcome {
        let performed: Bool
        let ambiguous: Bool
    }

    private func tryResync(operation: PlanOperation) throws -> ResyncOutcome {
        guard let slideKey = operation.slideKey, let elementName = operation.elementName else {
            return ResyncOutcome(performed: false, ambiguous: false)
        }

        let target = ResyncTarget(
            elementName: elementName,
            type: operation.payload.elementTypeHint,
            frame: operation.payload.frameHint,
            text: operation.payload.textHint
        )

        let result = try resyncSlide(adapter: adapter, slideKey: slideKey, targets: [target])
        return ResyncOutcome(performed: true, ambiguous: result.ambiguous)
    }

    private func verify(_ operation: PlanOperation) throws -> VerificationDetails {
        let expected = mergedVerify(operation)
        var checks: [String: Bool] = [:]
        var deltas: [String: Double] = [:]
        var messages: [String] = []

        if let expectPresentationOpen = expected.presentationOpen {
            let open = try adapter.isPresentationOpen()
            let pass = open == expectPresentationOpen
            checks["presentationOpen"] = pass
            if !pass { messages.append("presentationOpen expected \(expectPresentationOpen), got \(open)") }
        }

        if let slideKey = operation.slideKey, let expectSlideExists = expected.slideExists {
            let exists = try adapter.slideExists(slideKey: slideKey)
            let pass = exists == expectSlideExists
            checks["slideExists"] = pass
            if !pass { messages.append("slide \(slideKey) existence expected \(expectSlideExists), got \(exists)") }
        }

        if let slideKey = operation.slideKey, let elementName = operation.elementName {
            let snapshot = try adapter.element(slideKey: slideKey, elementName: elementName)

            if let expectElementExists = expected.elementExists {
                let exists = snapshot != nil
                let pass = exists == expectElementExists
                checks["elementExists"] = pass
                if !pass { messages.append("element \(elementName) existence expected \(expectElementExists), got \(exists)") }
            }

            if let prefix = expected.textPrefix {
                let actual = normalize(snapshot?.text ?? "")
                let normalizedPrefix = normalize(prefix)
                let pass = actual.hasPrefix(normalizedPrefix) ||
                    actual.hasPrefix("• \(normalizedPrefix)") ||
                    actual.contains(normalizedPrefix)
                checks["textPrefix"] = pass
                if !pass { messages.append("textPrefix mismatch for \(elementName)") }
            }

            if let contains = expected.textContains {
                let actual = normalize(snapshot?.text ?? "")
                let normalizedContains = normalize(contains)
                let pass = !normalizedContains.isEmpty && actual.localizedCaseInsensitiveContains(normalizedContains)
                checks["textContains"] = pass
                if !pass { messages.append("textContains mismatch for \(elementName)") }
            }

            if let expectedFrame = expected.frameApprox {
                if let actualFrame = snapshot?.frame {
                    let pass = actualFrame.approxEquals(expectedFrame, tolerance: 2)
                    checks["frameApprox"] = pass
                    if !pass {
                        messages.append("frame mismatch for \(elementName)")
                        deltas.merge(actualFrame.delta(from: expectedFrame)) { _, new in new }
                    }
                } else {
                    checks["frameApprox"] = false
                    messages.append("frame missing for \(elementName)")
                }
            }

            if let expectedBulletCount = expected.bulletCount {
                let actualBulletCount = snapshot?.bulletCount ?? -1
                let pass = actualBulletCount == expectedBulletCount
                checks["bulletCount"] = pass
                if !pass { messages.append("bulletCount expected \(expectedBulletCount), got \(actualBulletCount)") }
            }
        }

        if let notesContains = expected.notesContains, let slideKey = operation.slideKey {
            let notes = normalize(try adapter.presenterNotes(slideKey: slideKey) ?? "").lowercased()
            let pass = notes.contains(normalize(notesContains).lowercased())
            checks["notesContains"] = pass
            if !pass { messages.append("notes snippet not found on \(slideKey)") }
        }

        let passed = checks.values.allSatisfy { $0 }
        return VerificationDetails(passed: passed, checks: checks, deltas: deltas, messages: messages)
    }

    private func mergedVerify(_ operation: PlanOperation) -> VerifySpec {
        var verify = operation.verify
        switch operation.payload {
        case .openPresentation, .attachToFrontPresentation:
            if verify.presentationOpen == nil { verify.presentationOpen = true }
        case .resolveTarget:
            if verify.elementExists == nil { verify.elementExists = true }
        case .assertState(let slideKey, let elementName):
            if slideKey != nil, verify.slideExists == nil { verify.slideExists = true }
            if elementName != nil, verify.elementExists == nil { verify.elementExists = true }
        case .transaction:
            break
        case .ensureSlide:
            if verify.slideExists == nil { verify.slideExists = true }
        case .deleteSlide:
            break
        case .hideSlide, .moveSlide:
            if verify.slideExists == nil { verify.slideExists = true }
        case .ensureTextBox(_, _, let text, let frame, _):
            if verify.elementExists == nil { verify.elementExists = true }
            if verify.textPrefix == nil { verify.textPrefix = String(text.prefix(60)) }
            if verify.frameApprox == nil { verify.frameApprox = frame }
        case .ensureBullets(_, _, let items, let frame):
            if verify.elementExists == nil { verify.elementExists = true }
            if verify.textPrefix == nil { verify.textPrefix = items.first }
            if verify.bulletCount == nil { verify.bulletCount = items.count }
            if verify.frameApprox == nil { verify.frameApprox = frame }
        case .ensureImage(_, _, _, let frame):
            if verify.elementExists == nil { verify.elementExists = true }
            if verify.frameApprox == nil { verify.frameApprox = frame }
        case .ensureShape(_, _, _, let text, let frame):
            if verify.elementExists == nil { verify.elementExists = true }
            if let text, !text.isEmpty, verify.textPrefix == nil { verify.textPrefix = String(text.prefix(60)) }
            if verify.frameApprox == nil { verify.frameApprox = frame }
        case .deleteElement:
            if verify.elementExists == nil { verify.elementExists = false }
        case .setFrame(_, _, let frame):
            if verify.frameApprox == nil { verify.frameApprox = frame }
        case .setOpacity:
            if verify.elementExists == nil { verify.elementExists = true }
        case .setZOrder:
            if verify.elementExists == nil { verify.elementExists = true }
        case .setPresenterNotes(_, let text):
            if verify.notesContains == nil { verify.notesContains = String(text.prefix(80)) }
        case .setTextStyle, .setParagraphStyle, .setFillStyle, .setStrokeStyle:
            if verify.elementExists == nil { verify.elementExists = true }
        case .alignElements, .distributeElements:
            if verify.slideExists == nil { verify.slideExists = true }
        case .savePresentation, .duplicateSlide:
            break
        }
        return verify
    }

    private func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
