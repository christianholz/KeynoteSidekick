import Foundation

private func distance(_ lhs: Frame?, _ rhs: Frame?) -> Double {
    guard let lhs, let rhs else { return Double.greatestFiniteMagnitude }
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    let dw = lhs.width - rhs.width
    let dh = lhs.height - rhs.height
    return (dx * dx + dy * dy + dw * dw + dh * dh).squareRoot()
}

private func textPenalty(target: String?, candidate: String?) -> Double {
    guard let target, !target.isEmpty else { return 0 }
    guard let candidate, !candidate.isEmpty else { return 80 }

    let t = normalizeWhitespace(target.prefix(40))
    let c = normalizeWhitespace(candidate.prefix(40))
    if t == c { return 0 }
    if c.contains(t) || t.contains(c) { return 20 }
    return 80
}

private func normalizeWhitespace<S: StringProtocol>(_ value: S) -> String {
    value
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

public func resyncSlide(
    adapter: KeynoteAutomationAdapter,
    slideKey: String,
    targets: [ResyncTarget]
) throws -> ResyncResult {
    let elements = try adapter.enumerateSlideElements(slideKey: slideKey)
    let namedElements: [(String, SlideElementDescriptor)] = elements.compactMap { element in
        guard let name = element.name else { return nil }
        return (name, element)
    }
    let byName = Dictionary(uniqueKeysWithValues: namedElements)

    var matches: [ResyncMatch] = []

    for target in targets {
        if let exact = byName[target.elementName] {
            matches.append(ResyncMatch(target: target, element: exact, mode: .exact))
            continue
        }

        let scored = elements
            .filter { target.type == nil || $0.type == target.type }
            .map { element -> (SlideElementDescriptor, Double) in
                let score = distance(target.frame, element.frame) + textPenalty(target: target.text, candidate: element.textSnippet)
                return (element, score)
            }
            .sorted { $0.1 < $1.1 }

        guard let best = scored.first else { continue }

        if scored.count > 1, abs(best.1 - scored[1].1) < 1.0 {
            return ResyncResult(ok: false, ambiguous: true, count: elements.count, matches: matches)
        }

        matches.append(ResyncMatch(target: target, element: best.0, mode: .fallback))
    }

    try adapter.applyResyncBindings(slideKey: slideKey, matches: matches)
    return ResyncResult(ok: true, ambiguous: false, count: elements.count, matches: matches)
}
