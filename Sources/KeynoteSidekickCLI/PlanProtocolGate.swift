import Foundation

struct PlanProtocolViolation: Sendable {
    let path: String
    let message: String
}

struct PlanProtocolGate {
    static func validate(operations: [[String: Any]]) -> [PlanProtocolViolation] {
        var violations: [PlanProtocolViolation] = []
        validateOperations(operations, path: "operations", violations: &violations)
        return violations
    }

    static func summarize(_ violations: [PlanProtocolViolation], maxCount: Int = 6) -> String {
        guard !violations.isEmpty else { return "none" }
        let lines = violations.prefix(maxCount).map { "\($0.path): \($0.message)" }
        let suffix = violations.count > maxCount ? " (+\(violations.count - maxCount) more)" : ""
        return lines.joined(separator: " | ") + suffix
    }

    private static func validateOperations(
        _ operations: [[String: Any]],
        path: String,
        violations: inout [PlanProtocolViolation]
    ) {
        for (index, raw) in operations.enumerated() {
            let opPath = "\(path)[\(index)]"
            guard let opNameRaw = raw["op"] as? String else {
                violations.append(.init(path: opPath, message: "missing op"))
                continue
            }
            let opName = opNameRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if opName.isEmpty {
                violations.append(.init(path: opPath, message: "empty op"))
                continue
            }

            let target = raw["target"] as? [String: Any] ?? [:]
            let args = raw["args"] as? [String: Any] ?? [:]
            let verify = raw["verify"] as? [String: Any]
            if raw["target"] != nil, raw["target"] as? [String: Any] == nil {
                violations.append(.init(path: "\(opPath).target", message: "must be object"))
            }
            if raw["args"] != nil, raw["args"] as? [String: Any] == nil {
                violations.append(.init(path: "\(opPath).args", message: "must be object"))
            }
            if raw["verify"] != nil, verify == nil {
                violations.append(.init(path: "\(opPath).verify", message: "must be object"))
            }

            // Canonical contract forbids these legacy/misplaced keys in args.
            let forbiddenArgsKeys = [
                "slideKey",
                "slideKeyAlias",
                "elementName",
                "textType",
                "kind",
                "existingSlideKey",
                "slideTitleEquals"
            ]
            for key in forbiddenArgsKeys where args[key] != nil {
                violations.append(.init(path: "\(opPath).args.\(key)", message: "non-canonical key; move to canonical target/selector fields"))
            }

            // Canonical contract forbids these legacy keys in target.
            let forbiddenTargetKeys = [
                "textType",
                "kind",
                "slideTitleEquals",
                "existingSlideKey"
            ]
            for key in forbiddenTargetKeys where target[key] != nil {
                violations.append(.init(path: "\(opPath).target.\(key)", message: "non-canonical key"))
            }

            if opName == "resolveTarget" {
                if let selector = args["selector"] as? [String: Any] {
                    if selector["slideTitleEquals"] != nil {
                        violations.append(.init(path: "\(opPath).args.selector.slideTitleEquals", message: "non-canonical selector key; use textEquals/textContains/textPrefix"))
                    }
                } else {
                    violations.append(.init(path: "\(opPath).args.selector", message: "required object"))
                }
            }

            if opName == "transaction" {
                guard let nestedAny = args["operations"] as? [Any] else {
                    violations.append(.init(path: "\(opPath).args.operations", message: "required array"))
                    continue
                }
                let nested = nestedAny.compactMap { $0 as? [String: Any] }
                if nested.count != nestedAny.count {
                    violations.append(.init(path: "\(opPath).args.operations", message: "every item must be object"))
                }
                validateOperations(nested, path: "\(opPath).args.operations", violations: &violations)
            }
        }
    }

}
