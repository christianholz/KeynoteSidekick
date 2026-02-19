import Testing
@testable import KeynoteSidekickCLI

@Suite("Slide Key Rebaser")
struct SlideKeyRebaserTests {
    @Test("Rebases concrete slide key after prior insertion")
    func rebasesConcreteKey() {
        let rebased = SlideKeyRebaser.rebaseIfNeeded(
            opName: "ensureTextBox",
            slideKey: "slide_2",
            args: [:],
            insertionIndices: [2]
        )
        #expect(rebased == "slide_3")
    }

    @Test("Does not rebase structural ensureSlide create")
    func noRebaseForStructuralEnsureSlide() {
        let rebased = SlideKeyRebaser.rebaseIfNeeded(
            opName: "ensureSlide",
            slideKey: "slide_2",
            args: ["layout": "Title & Bullets"],
            insertionIndices: [2]
        )
        #expect(rebased == "slide_2")
    }

    @Test("Does not rebase structural ensureSlide create when layoutName is used")
    func noRebaseForLayoutNameEnsureSlide() {
        let rebased = SlideKeyRebaser.rebaseIfNeeded(
            opName: "ensureSlide",
            slideKey: "slide_2",
            args: ["layoutName": "Title & Bullets"],
            insertionIndices: [2]
        )
        #expect(rebased == "slide_2")
    }

    @Test("Does not rebase when caller disallows rebasing")
    func noRebaseWhenDisabled() {
        let rebased = SlideKeyRebaser.rebaseIfNeeded(
            opName: "ensureBullets",
            slideKey: "slide_2",
            args: [:],
            insertionIndices: [2],
            allowRebase: false
        )
        #expect(rebased == "slide_2")
    }
}
