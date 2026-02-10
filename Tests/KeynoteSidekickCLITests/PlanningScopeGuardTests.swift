import Testing
@testable import KeynoteSidekickCLI

@Suite("Planning Scope Guard")
struct PlanningScopeGuardTests {
    @Test("Infers explicit slide budget from singular and numeric requests")
    func infersBudget() {
        let promptA = "preface the limericks with a title slide and then add a slide outlining what a limerick is"
        #expect(PlanningScopeGuard.explicitSlideBudget(objective: promptA) == 2)

        let promptB = "add 5 slides, each with a limerick"
        #expect(PlanningScopeGuard.explicitSlideBudget(objective: promptB) == 5)
    }

    @Test("Infers touched-slide budget and disables it for explicit mass scope")
    func infersTouchedBudget() {
        let promptA = "preface the limericks with a title slide and then add a slide outlining what a limerick is"
        #expect(PlanningScopeGuard.touchedSlideBudget(objective: promptA) == 12)

        let promptB = "add 5 slides, each with a limerick"
        #expect(PlanningScopeGuard.touchedSlideBudget(objective: promptB) == 9)

        let promptC = "retitle all slides to include the quarter"
        #expect(PlanningScopeGuard.touchedSlideBudget(objective: promptC) == nil)
    }

    @Test("Counts only true new slide creations")
    func countsNewSlideCreations() {
        let known: [String: Int] = [
            "example_1_slide": 15,
            "example_2_slide": 16
        ]
        let operations: [[String: Any]] = [
            [
                "op": "ensureSlide",
                "target": ["slideKey": "example_1_slide"],
                "args": ["index": 15]
            ],
            [
                "op": "ensureSlide",
                "target": ["slideKey": "limericks_title_slide"],
                "args": ["index": 14, "layout": "Title"]
            ],
            [
                "op": "ensureSlide",
                "target": ["slideKey": "example_3_slide"],
                "args": ["index": 20]
            ]
        ]

        let newTargets = PlanningScopeGuard.newSlideCreateTargets(
            operations: operations,
            knownBindings: known
        )

        #expect(newTargets.contains("limericks_title_slide"))
        #expect(newTargets.contains("example_3_slide"))
        #expect(!newTargets.contains("example_1_slide"))
    }

    @Test("Flags unexpected scope expansion targets")
    func flagsUnexpectedTargets() {
        let known: [String: Int] = [
            "example_1_slide": 15,
            "example_2_slide": 16,
            "limericks_title_slide": 14
        ]
        let allowed = Set(["example_1_slide", "example_2_slide", "limericks_title_slide"])
        let operations: [[String: Any]] = [
            [
                "op": "ensureTextBox",
                "target": ["slideKey": "example_1_slide"],
                "args": ["text": "Example 1"]
            ],
            [
                "op": "ensureSlide",
                "target": ["slideKey": "example_7_slide"],
                "args": ["index": 22]
            ]
        ]

        let unexpected = PlanningScopeGuard.unexpectedSlideTargets(
            operations: operations,
            allowedScope: allowed,
            knownBindings: known
        )

        #expect(unexpected.contains("example_7_slide"))
        #expect(!unexpected.contains("example_1_slide"))
    }

    @Test("Does not count bind-only ensureSlide after one insertion")
    func doesNotCountBindAfterInsertion() {
        let known: [String: Int] = [
            "slide_1": 1,
            "slide_2": 2,
            "slide_3": 3
        ]
        let operations: [[String: Any]] = [
            [
                "op": "ensureSlide",
                "target": ["slideKey": "outline_slide"],
                "args": ["index": 2, "layout": "Title & Bullets"]
            ],
            [
                "op": "ensureSlide",
                "target": ["slideKey": "example_slide_1"],
                "args": ["index": 4]
            ]
        ]

        let newTargets = PlanningScopeGuard.newSlideCreateTargets(
            operations: operations,
            knownBindings: known
        )

        #expect(newTargets.contains("outline_slide"))
        #expect(!newTargets.contains("example_slide_1"))
    }

    @Test("Title-only update with existing index is not counted as create")
    func titleOnlyUpdateNotCreate() {
        let known: [String: Int] = [
            "slide_1": 1,
            "slide_2": 2
        ]
        let operations: [[String: Any]] = [
            [
                "op": "ensureSlide",
                "target": ["slideKey": "intro_alias"],
                "args": ["index": 1, "title": "Limericks"]
            ]
        ]

        let newTargets = PlanningScopeGuard.newSlideCreateTargets(
            operations: operations,
            knownBindings: known
        )

        #expect(!newTargets.contains("intro_alias"))
    }
}
