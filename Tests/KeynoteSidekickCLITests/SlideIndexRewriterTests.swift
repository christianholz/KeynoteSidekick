import Testing
@testable import KeynoteSidekickCLI

@Suite("Slide Index Rewriter")
struct SlideIndexRewriterTests {
    @Test("No insertions leaves index unchanged")
    func noInsertions() {
        let adjusted = SlideIndexRewriter.adjustedIndex(original: 12, insertionIndices: [])
        #expect(adjusted == 12)
    }

    @Test("Insertions before target rebase index")
    func insertionBeforeTarget() {
        let adjusted = SlideIndexRewriter.adjustedIndex(original: 20, insertionIndices: [14, 15])
        #expect(adjusted == 22)
    }

    @Test("Repeated insertion at same index rebases cumulatively")
    func repeatedInsertionAtSameIndex() {
        let adjusted = SlideIndexRewriter.adjustedIndex(original: 14, insertionIndices: [14, 14])
        #expect(adjusted == 16)
    }

    @Test("Insertion after target does not rebase")
    func insertionAfterTarget() {
        let adjusted = SlideIndexRewriter.adjustedIndex(original: 8, insertionIndices: [20])
        #expect(adjusted == 8)
    }
}
