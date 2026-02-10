import Foundation

enum SlideIndexRewriter {
    static func adjustedIndex(original: Int, insertionIndices: [Int]) -> Int {
        guard original > 0, !insertionIndices.isEmpty else { return original }

        var adjusted = original
        for insertion in insertionIndices.sorted() where insertion > 0 {
            if insertion <= adjusted {
                adjusted += 1
            }
        }
        return adjusted
    }
}
