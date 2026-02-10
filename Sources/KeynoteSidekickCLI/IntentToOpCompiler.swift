import Foundation

struct IntentCompileResult {
    let operations: [[String: Any]]
    let diagnostics: [String]
}

final class IntentToOpCompiler: @unchecked Sendable {
    private let localPlanner = LocalIntentCompiler()

    func isObjectiveSatisfied(
        objective: String,
        dom: PresentationDOMSnapshot
    ) -> Bool {
        localPlanner.isObjectiveSatisfied(objective: objective, dom: dom)
    }

    func compileDirectIntent(
        objective: String,
        dom: PresentationDOMSnapshot
    ) -> LocalIntentPlan? {
        localPlanner.compile(objective: objective, dom: dom)
    }

    func compile(
        operations: [[String: Any]],
        objective: String,
        dom: PresentationDOMSnapshot,
        knownBindings: [String: Int],
        focus: PresentationFocusContext,
        workingSlideKey: String?
    ) -> IntentCompileResult {
        var output: [[String: Any]] = []
        var diagnostics: [String] = []
        let destructiveAllowed = destructiveConfirmed(objective)

        for raw in operations {
            guard let opNameRaw = raw["op"] as? String else { continue }
            let opName = opNameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if opName.isEmpty { continue }

            if isDestructive(opName), !destructiveAllowed {
                diagnostics.append("compiler dropped \(opName): destructive action requires explicit confirmation")
                continue
            }

            var next = raw
            var target = raw["target"] as? [String: Any] ?? [:]
            var args = raw["args"] as? [String: Any] ?? [:]

            if let resolvedSlideKey = resolveSlideKey(
                target: target,
                args: args,
                opName: opName,
                dom: dom,
                knownBindings: knownBindings,
                focus: focus,
                workingSlideKey: workingSlideKey
            ) {
                target["slideKey"] = resolvedSlideKey
            }

            if needsElementName(opName), target["elementName"] == nil {
                if let element = resolveElementName(target: target, args: args, dom: dom) {
                    target["elementName"] = element
                }
            }

            if opName == "resolveTarget" {
                var selector = (args["selector"] as? [String: Any]) ?? [:]
                if let slideKey = target["slideKey"] as? String,
                   let index = knownBindings[slideKey] ?? slideIndexHint(from: slideKey) {
                    selector["index"] = index
                    args["selector"] = selector
                    diagnostics.append("compiler resolved resolveTarget selector.index for \(slideKey) -> \(index)")
                }
            }

            next["target"] = target
            next["args"] = args
            output.append(next)
        }

        return IntentCompileResult(operations: output, diagnostics: diagnostics)
    }

    private func destructiveConfirmed(_ objective: String) -> Bool {
        let lowered = objective.lowercased()
        return lowered.contains("confirm") ||
            lowered.contains("yes delete") ||
            lowered.contains("approved delete") ||
            lowered.contains("go ahead and delete")
    }

    private func isDestructive(_ opName: String) -> Bool {
        opName == "deleteSlide" || opName == "deleteElement"
    }

    private func needsElementName(_ opName: String) -> Bool {
        switch opName {
        case "ensureTextBox", "ensureBullets", "ensureImage", "ensureShape", "deleteElement", "setFrame", "setOpacity", "setZOrder", "setTextStyle", "setParagraphStyle", "setFillStyle", "setStrokeStyle":
            return true
        default:
            return false
        }
    }

    private func resolveSlideKey(
        target: [String: Any],
        args: [String: Any],
        opName: String,
        dom: PresentationDOMSnapshot,
        knownBindings: [String: Int],
        focus: PresentationFocusContext,
        workingSlideKey: String?
    ) -> String? {
        if let explicit = target["slideKey"] as? String,
           let resolved = normalizeSlideKey(explicit, knownBindings: knownBindings) {
            return resolved
        }

        if let index = positiveInt(target["slideIndex"]), let byIndex = dom.slide(at: index)?.slideKey {
            return byIndex
        }

        if opName == "ensureSlide", let index = positiveInt(args["index"]), let byIndex = dom.slide(at: index)?.slideKey {
            return byIndex
        }

        if let selector = args["selector"] as? [String: Any],
           let resolved = resolveFromSelector(selector, dom: dom, knownBindings: knownBindings) {
            return resolved
        }

        if let title = textValue(target["titleEquals"]) ?? textValue(args["title"]) {
            let titleToken = normalizeToken(title)
            if !titleToken.isEmpty {
                let matches = dom.slides.filter { normalizeToken($0.title) == titleToken }
                if matches.count == 1 {
                    return matches[0].slideKey
                }
            }
        }

        if let current = focus.currentSlideIndex, let byIndex = dom.slide(at: current)?.slideKey {
            return byIndex
        }

        return workingSlideKey
    }

    private func resolveFromSelector(
        _ selector: [String: Any],
        dom: PresentationDOMSnapshot,
        knownBindings: [String: Int]
    ) -> String? {
        if let index = positiveInt(selector["index"]), let byIndex = dom.slide(at: index)?.slideKey {
            return byIndex
        }

        let orderedKeys = ["textEquals", "slideTitleEquals", "textPrefix", "textContains", "matchText"]
        for key in orderedKeys {
            guard let text = selector[key] as? String else { continue }
            let token = normalizeToken(text)
            guard !token.isEmpty else { continue }

            let exact = dom.slides.filter { normalizeToken($0.title) == token }
            if exact.count == 1 {
                return exact[0].slideKey
            }

            let fuzzy = dom.slides.filter { slide in
                let title = normalizeToken(slide.title)
                if title.contains(token) || token.contains(title) {
                    return true
                }
                return slide.anchors.contains(where: { normalizeToken($0).contains(token) })
            }
            if fuzzy.count == 1 {
                return fuzzy[0].slideKey
            }
        }

        if let key = selector["slideKey"] as? String,
           let bound = normalizeSlideKey(key, knownBindings: knownBindings) {
            return bound
        }

        return nil
    }

    private func resolveElementName(target: [String: Any], args: [String: Any], dom: PresentationDOMSnapshot) -> String? {
        guard let slideKey = target["slideKey"] as? String,
              let slide = dom.slides.first(where: { $0.slideKey == slideKey }) else {
            return nil
        }

        if let handle = textValue(target["elementHandle"]) ?? textValue(args["elementHandle"]) {
            let token = normalizeToken(handle)
            if let matched = slide.elements.first(where: { normalizeToken($0.canonicalHandle) == token || normalizeToken($0.elementId) == token }) {
                return matched.name.isEmpty ? matched.elementId : matched.name
            }
        }

        if let role = textValue(args["role"]) {
            let normalizedRole = normalizeToken(role)
            if normalizedRole == "title",
               let title = slide.elements.first(where: { $0.role == "title" }) {
                return title.name.isEmpty ? title.elementId : title.name
            }
            if normalizedRole == "body",
               let body = slide.elements.first(where: { $0.role == "body" }) {
                return body.name.isEmpty ? body.elementId : body.name
            }
        }

        return nil
    }

    private func normalizeSlideKey(_ raw: String, knownBindings: [String: Int]) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let index = knownBindings[trimmed] {
            return "slide_\(index)"
        }

        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if normalized == "current_slide" || normalized == "this_slide" || normalized == "active_slide",
           let index = knownBindings["current_slide"] {
            return "slide_\(index)"
        }
        if normalized == "slide_after_current" || normalized == "slide_after_this",
           let index = knownBindings["slide_after_current"] {
            return "slide_\(index)"
        }

        if let hinted = slideIndexHint(from: trimmed) {
            return "slide_\(hinted)"
        }

        if trimmed.hasPrefix("slide_") {
            return trimmed
        }

        // Preserve planner-provided symbolic aliases (for example "conclusion_slide")
        // so downstream sanitization/execution can bind them deterministically.
        return trimmed
    }

    private func slideIndexHint(from key: String) -> Int? {
        let pattern = #"slide_(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: key,
                options: [],
                range: NSRange(key.startIndex..<key.endIndex, in: key)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: key) else {
            return nil
        }
        return Int(key[range])
    }

    private func positiveInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int, value > 0 { return value }
        if let value = raw as? NSNumber {
            let intValue = value.intValue
            return intValue > 0 ? intValue : nil
        }
        if let value = raw as? String, let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), intValue > 0 {
            return intValue
        }
        return nil
    }

    private func textValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func normalizeToken(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
