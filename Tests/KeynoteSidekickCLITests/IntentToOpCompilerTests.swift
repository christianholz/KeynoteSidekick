import Testing
@testable import KeynoteSidekickCLI

@Suite("Intent To Op Compiler")
struct IntentToOpCompilerTests {
    @Test("Resolves deictic slide key using known bindings")
    func resolvesCurrentSlideAlias() {
        let compiler = IntentToOpCompiler()
        let dom = sampleDOM()
        let result = compiler.compile(
            operations: [
                [
                    "op": "ensureTextBox",
                    "target": ["slideKey": "current_slide"],
                    "args": ["text": "Hello"]
                ]
            ],
            objective: "Add text to this slide",
            dom: dom,
            knownBindings: ["current_slide": 2],
            focus: PresentationFocusContext(currentSlideIndex: 2, currentSlideTitle: "Examples", selectedItems: []),
            workingSlideKey: nil
        )

        let firstTarget = result.operations.first?["target"] as? [String: Any]
        #expect(firstTarget?["slideKey"] as? String == "slide_2")
    }

    @Test("Resolves title/body element names from DOM placeholders")
    func resolvesElementByRole() {
        let compiler = IntentToOpCompiler()
        let dom = sampleDOM()
        let result = compiler.compile(
            operations: [
                [
                    "op": "setTextStyle",
                    "target": ["slideKey": "slide_1"],
                    "args": ["role": "title", "style": ["bold": true]]
                ]
            ],
            objective: "Make the title bold",
            dom: dom,
            knownBindings: [:],
            focus: .empty,
            workingSlideKey: nil
        )

        let firstTarget = result.operations.first?["target"] as? [String: Any]
        #expect(firstTarget?["elementName"] as? String == "Title")
    }

    @Test("Drops destructive operations without explicit confirmation")
    func dropsDestructiveWithoutConfirmation() {
        let compiler = IntentToOpCompiler()
        let result = compiler.compile(
            operations: [
                [
                    "op": "deleteSlide",
                    "target": ["slideKey": "slide_2"],
                    "args": [:]
                ]
            ],
            objective: "Delete the second slide",
            dom: sampleDOM(),
            knownBindings: [:],
            focus: .empty,
            workingSlideKey: nil
        )

        #expect(result.operations.isEmpty)
        #expect(result.diagnostics.contains(where: { $0.contains("destructive action requires explicit confirmation") }))
    }

    @Test("Preserves explicit symbolic slide alias instead of coercing to current slide")
    func preservesExplicitSymbolicSlideAlias() {
        let compiler = IntentToOpCompiler()
        let result = compiler.compile(
            operations: [
                [
                    "op": "ensureSlide",
                    "target": ["slideKey": "conclusion_slide"],
                    "args": ["index": 5, "layout": "Title & Bullets", "title": "Conclusion"]
                ]
            ],
            objective: "Add a conclusion slide at the end",
            dom: sampleDOM(),
            knownBindings: ["current_slide": 2],
            focus: PresentationFocusContext(currentSlideIndex: 2, currentSlideTitle: "Examples", selectedItems: []),
            workingSlideKey: nil
        )

        let firstTarget = result.operations.first?["target"] as? [String: Any]
        #expect(firstTarget?["slideKey"] as? String == "conclusion_slide")
    }

    private func sampleDOM() -> PresentationDOMSnapshot {
        PresentationDOMSnapshot(
            slides: [
                PresentationDOMSlide(
                    index: 1,
                    slideKey: "slide_1",
                    stableSlideId: "s1",
                    layoutName: "Title & Bullets",
                    masterName: "Title & Bullets",
                    title: "Intro",
                    body: "Overview",
                    notes: "",
                    titleHash: "a",
                    bodyHash: "b",
                    notesHash: "c",
                    textItems: ["Overview"],
                    textItemHashes: ["d"],
                    anchors: ["title:intro"],
                    elements: [
                        PresentationDOMElement(
                            elementId: "s1_title_placeholder",
                            name: "Title",
                            role: "title",
                            kind: "placeholder",
                            textSnippet: "Intro",
                            textHash: "a",
                            canonicalHandle: "slide:s1#title"
                        ),
                        PresentationDOMElement(
                            elementId: "s1_body_placeholder",
                            name: "Body",
                            role: "body",
                            kind: "placeholder",
                            textSnippet: "Overview",
                            textHash: "b",
                            canonicalHandle: "slide:s1#body"
                        )
                    ],
                    hasTitlePlaceholder: true,
                    hasBodyPlaceholder: true,
                    isSkipped: false
                ),
                PresentationDOMSlide(
                    index: 2,
                    slideKey: "slide_2",
                    stableSlideId: "s2",
                    layoutName: "Title & Bullets",
                    masterName: "Title & Bullets",
                    title: "Examples",
                    body: "Example set",
                    notes: "",
                    titleHash: "e",
                    bodyHash: "f",
                    notesHash: "g",
                    textItems: ["Example one"],
                    textItemHashes: ["h"],
                    anchors: ["title:examples"],
                    elements: [],
                    hasTitlePlaceholder: true,
                    hasBodyPlaceholder: true,
                    isSkipped: false
                )
            ]
        )
    }
}
