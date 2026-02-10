import Foundation

enum PlanningScopeGuard {
    private static let deicticAliases: Set<String> = [
        "active_slide",
        "current_slide",
        "this_slide",
        "slide_after_current",
        "slide_after_this"
    ]

    static func explicitSlideBudget(objective: String) -> Int? {
        let lowered = objective.lowercased()
        if lowered.isEmpty {
            return nil
        }

        if let explicitCount = parseExplicitSlideCount(from: lowered) {
            return explicitCount
        }

        var singularBudget = 0
        if lowered.contains("title slide") {
            singularBudget += 1
        }

        singularBudget += countRegexMatches(
            pattern: #"\b(add|insert|create)\s+(a|an|one)\s+(new\s+)?slide\b"#,
            in: lowered
        )

        return singularBudget > 0 ? singularBudget : nil
    }

    static func touchedSlideBudget(objective: String) -> Int? {
        let lowered = objective.lowercased()
        if lowered.isEmpty {
            return nil
        }
        if isMassScopeObjective(lowered) {
            return nil
        }
        if let explicitCount = parseExplicitSlideCount(from: lowered) {
            return max(explicitCount + 4, explicitCount)
        }
        return 12
    }

    static func newSlideCreateTargets(
        operations: [[String: Any]],
        knownBindings: [String: Int]
    ) -> Set<String> {
        var expectedSlideCount = knownBindings.values.max() ?? 0
        var output = Set<String>()

        for raw in operations {
            guard let opName = raw["op"] as? String, opName == "ensureSlide",
                  let target = raw["target"] as? [String: Any],
                  let slideKeyRaw = target["slideKey"] as? String else {
                continue
            }

            let slideKey = slideKeyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !slideKey.isEmpty else { continue }

            let normalized = normalizeDeictic(slideKey)
            if knownBindings[slideKey] != nil || knownBindings[normalized] != nil {
                continue
            }

            let args = raw["args"] as? [String: Any] ?? [:]
            if shouldCountAsEnsureSlideCreation(args: args, expectedSlideCount: expectedSlideCount) {
                output.insert(slideKey)
                expectedSlideCount += 1
            }
        }

        return output
    }

    static func baseAllowedScope(
        knownBindings: [String: Int],
        currentSlideKey: String?
    ) -> Set<String> {
        var allowed = Set(knownBindings.keys)
        allowed.formUnion(deicticAliases)
        if let currentSlideKey {
            allowed.insert(currentSlideKey)
        }
        return allowed
    }

    static func seedScope(
        existing: Set<String>,
        operations: [[String: Any]],
        completionCheck: PlanCompletionCheck?,
        knownBindings: [String: Int],
        currentSlideKey: String?
    ) -> Set<String> {
        var scope = existing
        scope.formUnion(baseAllowedScope(knownBindings: knownBindings, currentSlideKey: currentSlideKey))
        scope.formUnion(collectSlideTargets(from: operations))
        if let completionCheck {
            scope.formUnion(completionCheck.targetSlideKeys)
        }
        return scope
    }

    static func unexpectedSlideTargets(
        operations: [[String: Any]],
        allowedScope: Set<String>,
        knownBindings: [String: Int]
    ) -> Set<String> {
        let knownMaxIndex = knownBindings.values.max() ?? 0
        let targets = collectSlideTargets(from: operations)
        var unexpected = Set<String>()

        for raw in targets {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            if allowedScope.contains(key) {
                continue
            }
            let normalized = normalizeDeictic(key)
            if allowedScope.contains(normalized) {
                continue
            }
            if knownBindings[key] != nil || knownBindings[normalized] != nil {
                continue
            }
            if let index = slideIndexHint(from: key), index > 0, index <= knownMaxIndex {
                continue
            }
            if key.hasPrefix("slide_after_current__index_") {
                continue
            }

            unexpected.insert(key)
        }

        return unexpected
    }

    private static func collectSlideTargets(from operations: [[String: Any]]) -> Set<String> {
        Set(
            operations.compactMap { raw -> String? in
                guard let target = raw["target"] as? [String: Any],
                      let slideKey = target["slideKey"] as? String else {
                    return nil
                }
                let trimmed = slideKey.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private static func shouldCountAsEnsureSlideCreation(args: [String: Any], expectedSlideCount: Int) -> Bool {
        let hasLayoutSignal = args["layout"] != nil || args["master"] != nil || args["masterName"] != nil
        if hasLayoutSignal {
            return true
        }

        if positiveInt(from: args["index"]) == nil {
            // Unknown slide key without a concrete index cannot be a pure bind.
            return true
        }

        if let index = positiveInt(from: args["index"]) {
            return index > expectedSlideCount
        }
        return false
    }

    private static func parseExplicitSlideCount(from loweredObjective: String) -> Int? {
        let pattern = #"\b(add|insert|create|make)\s+(\d+)\s+slides?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                in: loweredObjective,
                options: [],
                range: NSRange(loweredObjective.startIndex..<loweredObjective.endIndex, in: loweredObjective)
              ),
              let range = Range(match.range(at: 2), in: loweredObjective),
              let count = Int(loweredObjective[range]),
              count > 0 else {
            return nil
        }
        return count
    }

    private static func isMassScopeObjective(_ loweredObjective: String) -> Bool {
        let phrases = [
            "all slides",
            "every slide",
            "entire deck",
            "whole deck",
            "across the deck",
            "across deck"
        ]
        return phrases.contains { loweredObjective.contains($0) }
    }

    private static func countRegexMatches(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    private static func normalizeDeictic(_ raw: String) -> String {
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

    private static func slideIndexHint(from slideKey: String) -> Int? {
        let lowered = slideKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?:slide[_\-]?|s)(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                in: lowered,
                options: [],
                range: NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
              ),
              let range = Range(match.range(at: 1), in: lowered),
              let index = Int(lowered[range]),
              index > 0 else {
            return nil
        }
        return index
    }

    private static func positiveInt(from raw: Any?) -> Int? {
        guard let raw else { return nil }
        if let value = raw as? Int, value > 0 {
            return value
        }
        if let value = raw as? NSNumber {
            let intValue = value.intValue
            return intValue > 0 ? intValue : nil
        }
        if let value = raw as? String, let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
            return parsed
        }
        return nil
    }
}
