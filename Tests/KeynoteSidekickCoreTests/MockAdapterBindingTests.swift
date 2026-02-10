import Testing
import KeynoteSidekickAdapters

@Suite("Mock Adapter Slide Binding")
struct MockAdapterSlideBindingTests {
    @Test("ensureSlide without layout binds to an existing indexed slide")
    func ensureSlideBindsAliasToExistingSlide() throws {
        let adapter = MockKeynoteAdapter()
        try adapter.attachToFrontPresentation()
        try adapter.ensureSlide(slideKey: "canonical", layout: "Title & Bullets", index: nil, title: "Ischemia Overview")

        try adapter.ensureSlide(slideKey: "alias", layout: nil, index: 1, title: nil)
        try adapter.setPresenterNotes(slideKey: "alias", text: "Updated notes")

        let bindings = try adapter.knownSlideBindings()
        #expect(bindings["canonical"] == 1)
        #expect(bindings["alias"] == 1)
        #expect(try adapter.presenterNotes(slideKey: "canonical") == "Updated notes")
    }

    @Test("ensureSlide with layout still creates a new slide")
    func ensureSlideWithLayoutCreatesNewSlide() throws {
        let adapter = MockKeynoteAdapter()
        try adapter.attachToFrontPresentation()
        try adapter.ensureSlide(slideKey: "existing", layout: "Title & Bullets", index: nil, title: "Original")

        try adapter.ensureSlide(slideKey: "new-slide", layout: "Title & Bullets", index: 1, title: "Inserted")

        let bindings = try adapter.knownSlideBindings()
        #expect(bindings["new-slide"] == 1)
        #expect(bindings["existing"] == 2)
    }
}
