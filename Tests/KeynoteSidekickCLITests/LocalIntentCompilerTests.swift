import Testing
@testable import KeynoteSidekickCLI

@Suite("Local Intent Compiler")
struct LocalIntentCompilerTests {
    @Test("Compiles section-preface intent despite minor typo in prompt")
    func compilesSectionPrefaceWithTypo() {
        let compiler = LocalIntentCompiler()
        let dom = sampleDOM(topic: "Case Study")
        let objective = "preface the case studies with a title slide \"Case Studies\", then add a slide outlining what a case study is, then rename the titles of the folowing slides \"Example x\""

        let plan = compiler.compile(objective: objective, dom: dom)

        #expect(plan != nil)
        #expect(plan?.reason == "dom_section_preface")
        let ops = plan?.operations ?? []
        #expect(ops.contains { ($0["op"] as? String) == "ensureSlide" })
        #expect(ops.contains { ($0["op"] as? String) == "ensureBullets" })
        #expect(ops.contains { op in
            guard (op["op"] as? String) == "ensureTextBox",
                  let target = op["target"] as? [String: Any],
                  let elementName = target["elementName"] as? String else {
                return false
            }
            return elementName == "__ksk_role_title__"
        })
    }

    @Test("Compiles generic topic without topic-specific hardcoding")
    func compilesGenericTopic() {
        let compiler = LocalIntentCompiler()
        let dom = sampleDOM(topic: "Tutorial")
        let objective = "before the tutorials, add a title slide \"Tutorials\", add a slide with an overview of what a tutorial is, then retitle those slides as \"Example x\""

        let plan = compiler.compile(objective: objective, dom: dom)
        let ops = plan?.operations ?? []

        #expect(plan != nil)
        #expect(ops.filter { ($0["op"] as? String) == "ensureSlide" }.count >= 2)
    }

    @Test("Compiles when source section uses single-line body text")
    func compilesSingleLineBodySection() {
        let compiler = LocalIntentCompiler()
        let dom = PresentationDOMSnapshot(
            slides: [
                PresentationDOMSlide(
                    index: 1,
                    slideKey: "slide_1",
                    stableSlideId: "s1",
                    layoutName: "Title & Bullets",
                    masterName: "Title & Bullets",
                    title: "Overview",
                    body: "",
                    notes: "",
                    titleHash: "t1",
                    bodyHash: "b1",
                    notesHash: "n1",
                    textItems: [],
                    textItemHashes: [],
                    anchors: [],
                    elements: [],
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
                    title: "Limerick",
                    body: "When deadlines were coming in hot",
                    notes: "",
                    titleHash: "t2",
                    bodyHash: "b2",
                    notesHash: "n2",
                    textItems: [],
                    textItemHashes: [],
                    anchors: [],
                    elements: [],
                    hasTitlePlaceholder: false,
                    hasBodyPlaceholder: false,
                    isSkipped: false
                ),
                PresentationDOMSlide(
                    index: 3,
                    slideKey: "slide_3",
                    stableSlideId: "s3",
                    layoutName: "Title & Bullets",
                    masterName: "Title & Bullets",
                    title: "Limerick",
                    body: "It gathered cues and delivered a rhyme",
                    notes: "",
                    titleHash: "t3",
                    bodyHash: "b3",
                    notesHash: "n3",
                    textItems: [],
                    textItemHashes: [],
                    anchors: [],
                    elements: [],
                    hasTitlePlaceholder: false,
                    hasBodyPlaceholder: false,
                    isSkipped: false
                )
            ]
        )
        let objective = "preface the limericks with a title slide \"Limericks\", then add a slide outlining what a limerick is, then rename the titles of the folowing slides \"Example x\""

        let plan = compiler.compile(objective: objective, dom: dom)

        #expect(plan != nil)
        #expect(plan?.reason == "dom_section_preface")
    }

    @Test("Does not repurpose existing preface; inserts outline before examples and renames only examples")
    func preservesPrefaceAndRenamesOnlyExampleRun() {
        let compiler = LocalIntentCompiler()
        let objective = "preface the limericks with a title slide \"Limericks\", then add a slide outlining what a limerick is, then rename the titles of the folowing slides \"Example x\""
        let dom = PresentationDOMSnapshot(
            slides: [
                slide(index: 1, title: "Limericks", body: ""),
                slide(index: 2, title: "Limerick 1", body: poemLine("one")),
                slide(index: 3, title: "Limerick 2", body: poemLine("two"))
            ]
        )

        let plan = compiler.compile(objective: objective, dom: dom)
        #expect(plan != nil)
        let ops = plan?.operations ?? []

        let renameTargets = ops.compactMap { op -> String? in
            guard (op["op"] as? String) == "ensureTextBox",
                  let args = op["args"] as? [String: Any],
                  let text = args["text"] as? String,
                  text.hasPrefix("Example"),
                  let target = op["target"] as? [String: Any],
                  let slideKey = target["slideKey"] as? String else {
                return nil
            }
            return slideKey
        }
        #expect(renameTargets.count == 2)
        #expect(renameTargets.contains("slide_3"))
        #expect(renameTargets.contains("slide_4"))
    }

    @Test("Topic-title example slide is not mistaken for preface")
    func topicTitledExampleStillGetsRenamed() {
        let compiler = LocalIntentCompiler()
        let objective = "preface the limericks with a title slide \"Limericks\", then add a slide outlining what a limerick is, then rename the titles of the folowing slides \"Example x\""
        let dom = PresentationDOMSnapshot(
            slides: [
                slide(index: 1, title: "Intro", body: ""),
                slide(index: 2, title: "Limericks", body: poemLine("one")),
                slide(index: 3, title: "Limerick 2", body: poemLine("two"))
            ]
        )

        let plan = compiler.compile(objective: objective, dom: dom)
        #expect(plan != nil)
        let ops = plan?.operations ?? []

        let prefaceInsert = ops.first { op in
            guard (op["op"] as? String) == "ensureSlide",
                  let target = op["target"] as? [String: Any],
                  let slideKey = target["slideKey"] as? String,
                  slideKey == "local_preface_insert",
                  let args = op["args"] as? [String: Any],
                  let index = args["index"] as? Int else {
                return false
            }
            return index == 2
        }
        #expect(prefaceInsert != nil)

        let renameTargets = ops.compactMap { op -> String? in
            guard (op["op"] as? String) == "ensureTextBox",
                  let args = op["args"] as? [String: Any],
                  let text = args["text"] as? String,
                  text.hasPrefix("Example"),
                  let target = op["target"] as? [String: Any],
                  let slideKey = target["slideKey"] as? String else {
                return nil
            }
            return slideKey
        }
        #expect(renameTargets.count == 2)
        #expect(renameTargets.contains("slide_4"))
        #expect(renameTargets.contains("slide_5"))
    }

    @Test("Misplaced outline at end does not prevent preface insertion before examples")
    func misplacedOutlineIsNotTreatedAsCompletedPreface() {
        let compiler = LocalIntentCompiler()
        let objective = "preface the limericks with a title slide \"Limericks\", then add a slide outlining what a limerick is, then rename the titles of the folowing slides \"Example x\""
        let dom = PresentationDOMSnapshot(
            slides: [
                slide(index: 1, title: "Intro", body: ""),
                slide(index: 14, title: "Limerick 1", body: poemLine("one")),
                slide(index: 15, title: "Limerick 2", body: poemLine("two")),
                slide(index: 16, title: "Limerick 3", body: poemLine("three")),
                slide(index: 17, title: "Limericks", body: poemLine("four")),
                slide(
                    index: 18,
                    title: "What Is a Limerick?",
                    body: """
                    Five-line poem with an AABBA rhyme scheme
                    Lines 1, 2 and 5 are longer
                    """
                )
            ]
        )

        let plan = compiler.compile(objective: objective, dom: dom)
        #expect(plan != nil)
        let ops = plan?.operations ?? []

        let destructiveOps = ops.compactMap { $0["op"] as? String }
            .filter { ["deleteSlide", "deleteElement", "hideSlide", "moveSlide"].contains($0) }
        #expect(destructiveOps.isEmpty)

        let prefaceEnsure = ops.first { op in
            guard (op["op"] as? String) == "ensureSlide",
                  let target = op["target"] as? [String: Any],
                  let slideKey = target["slideKey"] as? String,
                  slideKey == "local_preface_insert",
                  let args = op["args"] as? [String: Any],
                  let index = args["index"] as? Int else {
                return false
            }
            return index == 14
        }
        #expect(prefaceEnsure != nil)

        let renameTargets = ops.compactMap { op -> String? in
            guard (op["op"] as? String) == "ensureTextBox",
                  let args = op["args"] as? [String: Any],
                  let text = args["text"] as? String,
                  text.hasPrefix("Example"),
                  let target = op["target"] as? [String: Any],
                  let slideKey = target["slideKey"] as? String else {
                return nil
            }
            return slideKey
        }
        #expect(renameTargets.count == 4)
        #expect(renameTargets.contains("slide_16"))
        #expect(renameTargets.contains("slide_17"))
        #expect(renameTargets.contains("slide_18"))
        #expect(renameTargets.contains("slide_19"))
    }

    private func sampleDOM(topic: String) -> PresentationDOMSnapshot {
        let body1 = String(repeating: "This is rich topic content. ", count: 6)
        let body2 = String(repeating: "Second detailed topic slide. ", count: 6)
        let title1 = "\(topic) 1"
        let title2 = "\(topic) 2"
        return PresentationDOMSnapshot(
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
                    titleHash: "t1",
                    bodyHash: "b1",
                    notesHash: "n1",
                    textItems: ["Overview"],
                    textItemHashes: ["ti1"],
                    anchors: ["title:intro"],
                    elements: [],
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
                    title: title1,
                    body: body1,
                    notes: "",
                    titleHash: "t2",
                    bodyHash: "b2",
                    notesHash: "n2",
                    textItems: [body1],
                    textItemHashes: ["ti2"],
                    anchors: ["title:topic_1"],
                    elements: [],
                    hasTitlePlaceholder: true,
                    hasBodyPlaceholder: true,
                    isSkipped: false
                ),
                PresentationDOMSlide(
                    index: 3,
                    slideKey: "slide_3",
                    stableSlideId: "s3",
                    layoutName: "Title & Bullets",
                    masterName: "Title & Bullets",
                    title: title2,
                    body: body2,
                    notes: "",
                    titleHash: "t3",
                    bodyHash: "b3",
                    notesHash: "n3",
                    textItems: [body2],
                    textItemHashes: ["ti3"],
                    anchors: ["title:topic_2"],
                    elements: [],
                    hasTitlePlaceholder: true,
                    hasBodyPlaceholder: true,
                    isSkipped: false
                )
            ]
        )
    }

    private func slide(index: Int, title: String, body: String) -> PresentationDOMSlide {
        PresentationDOMSlide(
            index: index,
            slideKey: "slide_\(index)",
            stableSlideId: "s\(index)",
            layoutName: "Title & Bullets",
            masterName: "Title & Bullets",
            title: title,
            body: body,
            notes: "",
            titleHash: "t\(index)",
            bodyHash: "b\(index)",
            notesHash: "n\(index)",
            textItems: body.isEmpty ? [] : [body],
            textItemHashes: body.isEmpty ? [] : ["ti\(index)"],
            anchors: [],
            elements: [],
            hasTitlePlaceholder: true,
            hasBodyPlaceholder: true,
            isSkipped: false
        )
    }

    private func poemLine(_ suffix: String) -> String {
        "There once was a coder \(suffix) who shipped a whimsical keynote with rhythm and rhyme."
    }
}
