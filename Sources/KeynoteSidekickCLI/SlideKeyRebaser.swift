import Foundation

enum SlideKeyRebaser {
    static func rebaseIfNeeded(
        opName: String,
        slideKey: String,
        args: [String: Any],
        insertionIndices: [Int],
        allowRebase: Bool = true
    ) -> String {
        guard allowRebase else { return slideKey }
        guard !insertionIndices.isEmpty else { return slideKey }
        guard let originalIndex = slideIndexHint(from: slideKey) else { return slideKey }

        if opName == "ensureSlide",
           hasStructuralCreationIntent(args: args) {
            return slideKey
        }

        let rebased = SlideIndexRewriter.adjustedIndex(
            original: originalIndex,
            insertionIndices: insertionIndices
        )
        guard rebased != originalIndex else { return slideKey }
        return "slide_\(rebased)"
    }

    private static func hasStructuralCreationIntent(args: [String: Any]) -> Bool {
        args["layout"] != nil || args["layoutName"] != nil || args["master"] != nil || args["masterName"] != nil
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
}
