import Testing
@testable import KeynoteSidekickCLI

@Suite("Plan Protocol Gate")
struct PlanProtocolGateTests {
    @Test("Canonical plan passes gate")
    func canonicalPlanPassesGate() {
        let operations: [[String: Any]] = [
            [
                "op": "ensureSlide",
                "target": ["slideKey": "slide_intro"],
                "args": ["layout": "Title & Bullets"],
                "verify": ["slideExists": true]
            ],
            [
                "op": "ensureTextBox",
                "target": ["slideKey": "slide_intro", "elementName": "slide_intro__title__main__0001"],
                "args": ["text": "Limericks", "role": "title"],
                "verify": ["textPrefix": "Limericks"]
            ]
        ]

        let violations = PlanProtocolGate.validate(operations: operations)
        #expect(violations.isEmpty, "Expected no protocol violations, got: \(PlanProtocolGate.summarize(violations, maxCount: 20))")
    }

    @Test("Legacy fields are rejected")
    func legacyFieldsAreRejected() {
        let operations: [[String: Any]] = [
            [
                "op": "ensureSlide",
                "target": [:],
                "args": ["slideKey": "legacy_slide", "existingSlideKey": 3],
                "verify": [:]
            ],
            [
                "op": "ensureTextBox",
                "target": ["slideKey": "legacy_slide", "textType": "title"],
                "args": ["kind": "title", "text": "Limericks"],
                "verify": [:]
            ]
        ]

        let violations = PlanProtocolGate.validate(operations: operations)
        let summary = PlanProtocolGate.summarize(violations, maxCount: 20)

        #expect(!violations.isEmpty)
        #expect(summary.contains("args.slideKey"))
        #expect(summary.contains("args.existingSlideKey"))
        #expect(summary.contains("target.textType"))
        #expect(summary.contains("args.kind"))
    }

    @Test("resolveTarget requires selector object")
    func resolveTargetRequiresSelectorObject() {
        let operations: [[String: Any]] = [
            [
                "op": "resolveTarget",
                "target": ["slideKey": "slide_4", "elementName": "candidate_title"],
                "args": [:],
                "verify": [:]
            ]
        ]

        let violations = PlanProtocolGate.validate(operations: operations)
        let summary = PlanProtocolGate.summarize(violations, maxCount: 10)
        #expect(summary.contains("args.selector"))
    }

    @Test("Transaction nested violations are reported")
    func transactionNestedViolationsAreReported() {
        let operations: [[String: Any]] = [
            [
                "op": "transaction",
                "target": [:],
                "args": [
                    "operations": [
                        [
                            "op": "ensureTextBox",
                            "target": ["slideKey": "slide_9"],
                            "args": ["textType": "body", "text": "Hello"],
                            "verify": [:]
                        ]
                    ]
                ],
                "verify": [:]
            ]
        ]

        let violations = PlanProtocolGate.validate(operations: operations)
        let summary = PlanProtocolGate.summarize(violations, maxCount: 20)
        #expect(summary.contains("args.operations[0].args.textType"))
    }

    @Test("Missing identifiers are allowed for sanitizer synthesis")
    func missingIdentifiersAreAllowedForSanitizerSynthesis() {
        let operations: [[String: Any]] = [
            [
                "op": "ensureTextBox",
                "target": ["slideKey": "example_slide"],
                "args": ["role": "title", "text": "Example 1"],
                "verify": [:]
            ],
            [
                "op": "resolveTarget",
                "target": ["slideKey": "example_slide_1"],
                "args": ["selector": ["type": "slide", "textEquals": "Limerick 1"]],
                "verify": [:]
            ]
        ]

        let violations = PlanProtocolGate.validate(operations: operations)
        #expect(violations.isEmpty, "Expected sanitizer-repairable plan to pass gate, got: \(PlanProtocolGate.summarize(violations, maxCount: 20))")
    }
}
