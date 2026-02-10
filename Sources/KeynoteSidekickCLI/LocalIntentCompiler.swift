import Foundation

struct LocalIntentPlan {
    let reason: String
    let assistantReply: String
    let operations: [[String: Any]]
}

final class LocalIntentCompiler: @unchecked Sendable {
    func isObjectiveSatisfied(objective: String, dom: PresentationDOMSnapshot) -> Bool {
        if let intent = parseSectionPrefaceIntent(objective: objective) {
            return isSectionPrefaceSatisfied(intent: intent, dom: dom)
        }
        if isInsertTitleSlideAtBeginningObjective(objective) {
            return isInsertTitleSlideAtBeginningSatisfied(objective: objective, dom: dom)
        }
        return false
    }

    func compile(objective: String, dom: PresentationDOMSnapshot) -> LocalIntentPlan? {
        if let intent = parseSectionPrefaceIntent(objective: objective) {
            return compileSectionPreface(intent: intent, dom: dom)
        }
        if isInsertTitleSlideAtBeginningObjective(objective) {
            return compileInsertTitleSlideAtBeginning(objective: objective, dom: dom)
        }
        return nil
    }

    private enum PrefaceState {
        case complete
        case prefaceOnly
        case outlineOnly
        case missing
    }

    private struct SectionPrefaceIntent {
        let topicRaw: String
        let topicSingular: String
        let prefaceTitle: String
        let outlineTitle: String
        let renameTemplate: String
    }

    private func parseSectionPrefaceIntent(objective: String) -> SectionPrefaceIntent? {
        let lowered = objective.lowercased()
        guard containsAny(lowered, ["title slide", "intro slide", "section slide"]) else {
            return nil
        }
        guard hasRenameCue(lowered) else {
            return nil
        }
        guard hasOutlineCue(lowered) else {
            return nil
        }
        guard hasPrefaceCue(lowered) else {
            return nil
        }

        let topic = extractTopic(from: objective) ?? extractPrefaceTitle(from: objective) ?? "Topic"
        let topicSingular = singularized(topic)
        let prefaceTitle = extractPrefaceTitle(from: objective) ?? titleCased(topic)
        let outlineTitle = extractOutlineTitle(from: objective, singularTopic: topicSingular)
        let renameTemplate = extractRenameTemplate(from: objective) ?? "Example x"

        return SectionPrefaceIntent(
            topicRaw: topic,
            topicSingular: topicSingular,
            prefaceTitle: prefaceTitle,
            outlineTitle: outlineTitle,
            renameTemplate: renameTemplate
        )
    }

    private func compileSectionPreface(intent: SectionPrefaceIntent, dom: PresentationDOMSnapshot) -> LocalIntentPlan? {
        guard !dom.slides.isEmpty else { return nil }
        if isSectionPrefaceSatisfied(intent: intent, dom: dom) {
            return nil
        }

        let slidesByIndex = Dictionary(uniqueKeysWithValues: dom.slides.map { ($0.index, $0) })
        guard let sectionStartIndex = sectionStartIndex(
            dom: dom,
            topic: intent.topicRaw,
            prefaceTitle: intent.prefaceTitle,
            outlineTitle: intent.outlineTitle
        ) else { return nil }

        let runIndices = contiguousSectionRun(startAt: sectionStartIndex, slidesByIndex: slidesByIndex, topic: intent.topicRaw)
        guard !runIndices.isEmpty else { return nil }

        let state = prefaceState(
            beforeSectionStart: sectionStartIndex,
            slidesByIndex: slidesByIndex,
            prefaceTitle: intent.prefaceTitle,
            outlineTitle: intent.outlineTitle
        )

        var insertedBeforeRun = 0
        var prefaceSlideIndex = sectionStartIndex
        var outlineSlideIndex = sectionStartIndex + 1
        var prefaceSlideKey = "local_preface_insert"
        var outlineSlideKey = "local_outline_insert"

        switch state {
        case .complete:
            prefaceSlideIndex = sectionStartIndex - 2
            outlineSlideIndex = sectionStartIndex - 1
            prefaceSlideKey = "slide_\(prefaceSlideIndex)"
            outlineSlideKey = "slide_\(outlineSlideIndex)"
            insertedBeforeRun = 0
        case .prefaceOnly:
            prefaceSlideIndex = sectionStartIndex - 1
            outlineSlideIndex = sectionStartIndex
            prefaceSlideKey = "slide_\(prefaceSlideIndex)"
            outlineSlideKey = "local_outline_insert"
            insertedBeforeRun = 1
        case .outlineOnly:
            prefaceSlideIndex = max(1, sectionStartIndex - 1)
            outlineSlideIndex = sectionStartIndex
            prefaceSlideKey = "local_preface_insert"
            outlineSlideKey = "slide_\(outlineSlideIndex)"
            insertedBeforeRun = 1
        case .missing:
            prefaceSlideIndex = sectionStartIndex
            outlineSlideIndex = sectionStartIndex + 1
            prefaceSlideKey = "local_preface_insert"
            outlineSlideKey = "local_outline_insert"
            insertedBeforeRun = 2
        }

        var operations: [[String: Any]] = []
        operations.append(
            op(
                "ensureSlide",
                target: ["slideKey": prefaceSlideKey],
                args: [
                    "index": prefaceSlideIndex,
                    "layout": "Title",
                    "title": intent.prefaceTitle
                ],
                verify: ["slideExists": true]
            )
        )
        operations.append(
            op(
                "ensureSlide",
                target: ["slideKey": outlineSlideKey],
                args: [
                    "index": outlineSlideIndex,
                    "layout": "Title & Bullets",
                    "title": intent.outlineTitle
                ],
                verify: ["slideExists": true]
            )
        )
        operations.append(
            op(
                "ensureTextBox",
                target: [
                    "slideKey": prefaceSlideKey,
                    "elementName": "__ksk_role_title__"
                ],
                args: [
                    "text": intent.prefaceTitle,
                    "style": ["role": "title"]
                ],
                verify: ["textPrefix": intent.prefaceTitle]
            )
        )
        operations.append(
            op(
                "ensureTextBox",
                target: [
                    "slideKey": outlineSlideKey,
                    "elementName": "__ksk_role_title__"
                ],
                args: [
                    "text": intent.outlineTitle,
                    "style": ["role": "title"]
                ],
                verify: ["textPrefix": String(intent.outlineTitle.prefix(12))]
            )
        )
        operations.append(
            op(
                "ensureBullets",
                target: [
                    "slideKey": outlineSlideKey,
                    "elementName": "__ksk_role_body__"
                ],
                args: [
                    "items": genericOutlineBullets(topic: intent.topicSingular)
                ],
                verify: ["bulletCount": 3]
            )
        )

        for (offset, originalIndex) in runIndices.enumerated() {
            let desiredTitle = renderRenameTemplate(intent.renameTemplate, index: offset + 1)
            let targetIndex = originalIndex + insertedBeforeRun
            let targetSlideKey = "slide_\(targetIndex)"

            if insertedBeforeRun == 0,
               let originalSlide = slidesByIndex[originalIndex],
               normalize(originalSlide.title) == normalize(desiredTitle) {
                continue
            }

            operations.append(
                op(
                    "ensureTextBox",
                    target: [
                        "slideKey": targetSlideKey,
                        "elementName": "__ksk_role_title__"
                    ],
                    args: [
                        "text": desiredTitle,
                        "style": ["role": "title"]
                    ],
                    verify: ["textPrefix": desiredTitle]
                )
            )
        }

        return LocalIntentPlan(
            reason: "dom_section_preface",
            assistantReply: "Inserted the section preface slides and retitled the following examples.",
            operations: operations
        )
    }

    private func isSectionPrefaceSatisfied(intent: SectionPrefaceIntent, dom: PresentationDOMSnapshot) -> Bool {
        guard !dom.slides.isEmpty else { return false }
        let slidesByIndex = Dictionary(uniqueKeysWithValues: dom.slides.map { ($0.index, $0) })
        guard let sectionStart = sectionStartIndex(
            dom: dom,
            topic: intent.topicRaw,
            prefaceTitle: intent.prefaceTitle,
            outlineTitle: intent.outlineTitle
        ) else { return false }

        guard prefaceState(
            beforeSectionStart: sectionStart,
            slidesByIndex: slidesByIndex,
            prefaceTitle: intent.prefaceTitle,
            outlineTitle: intent.outlineTitle
        ) == .complete else {
            return false
        }

        let runIndices = contiguousSectionRun(startAt: sectionStart, slidesByIndex: slidesByIndex, topic: intent.topicRaw)
        guard !runIndices.isEmpty else { return false }

        for (offset, index) in runIndices.enumerated() {
            guard let slide = slidesByIndex[index] else { return false }
            let expected = renderRenameTemplate(intent.renameTemplate, index: offset + 1)
            if normalize(slide.title) != normalize(expected) {
                return false
            }
        }
        return true
    }

    private func prefaceState(
        beforeSectionStart index: Int,
        slidesByIndex: [Int: PresentationDOMSlide],
        prefaceTitle: String,
        outlineTitle: String
    ) -> PrefaceState {
        let beforeOne = slidesByIndex[index - 1]
        let beforeTwo = slidesByIndex[index - 2]

        let beforeOneIsPreface = isPrefaceSlide(beforeOne, prefaceTitle: prefaceTitle)
        let beforeTwoIsPreface = isPrefaceSlide(beforeTwo, prefaceTitle: prefaceTitle)
        let beforeOneIsOutline = isOutlineSlide(beforeOne, outlineTitle: outlineTitle)

        if beforeTwoIsPreface && beforeOneIsOutline {
            return .complete
        }
        if beforeOneIsPreface {
            return .prefaceOnly
        }
        if beforeOneIsOutline {
            return .outlineOnly
        }
        return .missing
    }

    private func isPrefaceSlide(_ slide: PresentationDOMSlide?, prefaceTitle: String) -> Bool {
        guard let slide else { return false }
        guard normalize(slide.title) == normalize(prefaceTitle) else { return false }
        return !isContentHeavy(slide)
    }

    private func isOutlineSlide(_ slide: PresentationDOMSlide?, outlineTitle: String) -> Bool {
        guard let slide else { return false }
        let titleToken = normalize(slide.title)
        if titleToken == normalize(outlineTitle) {
            return true
        }
        if titleToken.contains("what is") {
            return true
        }
        let bodyToken = normalize(slide.body)
        let hasDefinitionCue =
            bodyToken.contains("definition") ||
            bodyToken.contains("characteristic") ||
            bodyToken.contains("structure") ||
            bodyToken.contains("rhyme scheme") ||
            bodyToken.contains("overview")
        if hasDefinitionCue && slide.bodyLineCount >= 2 {
            return true
        }
        return false
    }

    private func sectionStartIndex(
        dom: PresentationDOMSnapshot,
        topic: String,
        prefaceTitle: String,
        outlineTitle: String
    ) -> Int? {
        let tokens = topicTokens(topic)
        let sorted = dom.slides.sorted { $0.index < $1.index }
        let prefaceToken = normalize(prefaceTitle)
        let outlineToken = normalize(outlineTitle)

        func isKnownPrefaceOrOutline(_ slide: PresentationDOMSlide) -> Bool {
            let title = normalize(slide.title)
            if !prefaceToken.isEmpty, title == prefaceToken, !isContentHeavy(slide) {
                return true
            }
            if !outlineToken.isEmpty, title == outlineToken {
                return true
            }
            if title.contains("what is") {
                return true
            }
            return false
        }

        let preferred = sorted.filter { slide in
            isContentHeavy(slide) &&
                matchesTopic(slide: slide, topicTokens: tokens) &&
                !isKnownPrefaceOrOutline(slide)
        }
        if let first = preferred.first {
            return first.index
        }

        let numbered = sorted.filter { slide in
            isContentHeavy(slide) &&
                isNumberedTitle(slide.title) &&
                !isKnownPrefaceOrOutline(slide)
        }
        if let first = numbered.first {
            return first.index
        }

        return sorted.first(where: { isContentHeavy($0) && !isKnownPrefaceOrOutline($0) })?.index
    }

    private func contiguousSectionRun(
        startAt startIndex: Int,
        slidesByIndex: [Int: PresentationDOMSlide],
        topic: String
    ) -> [Int] {
        let tokens = topicTokens(topic)
        var run: [Int] = []
        var cursor = startIndex

        while let slide = slidesByIndex[cursor] {
            if isOutlineSlide(slide, outlineTitle: "") {
                break
            }
            let shouldInclude = isContentHeavy(slide) &&
                (matchesTopic(slide: slide, topicTokens: tokens) || isNumberedTitle(slide.title))
            if !shouldInclude {
                break
            }
            run.append(cursor)
            cursor += 1
        }

        return run
    }

    private func matchesTopic(slide: PresentationDOMSlide, topicTokens: Set<String>) -> Bool {
        guard !topicTokens.isEmpty else { return false }
        let title = normalize(slide.title)
        let body = normalize(slide.body)
        let textItems = normalize(slide.textItems.joined(separator: " "))

        for token in topicTokens where token.count >= 3 {
            if title.contains(token) || body.contains(token) || textItems.contains(token) {
                return true
            }
        }
        return false
    }

    private func topicTokens(_ topic: String) -> Set<String> {
        var base = normalize(topic)
        if base.hasPrefix("the ") {
            base.removeFirst(4)
        }
        let singular = singularized(base)
        let plural = singular.hasSuffix("s") ? singular : singular + "s"
        return Set([base, singular, plural].flatMap { token in
            token.split(separator: " ").map(String.init)
        })
    }

    private func isContentHeavy(_ slide: PresentationDOMSlide) -> Bool {
        if slide.bodyLineCount >= 2 {
            return true
        }
        let bodyCount = slide.body.trimmingCharacters(in: .whitespacesAndNewlines).count
        if bodyCount >= 80 {
            return true
        }
        if bodyCount >= 20 && !slide.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return slide.textItems.joined(separator: " ").count >= 40
    }

    private func isNumberedTitle(_ title: String) -> Bool {
        let value = normalize(title)
        return value.range(of: #"^(example|sample|case|item|section|chapter)\s+\d+"#, options: .regularExpression) != nil
    }

    private func compileInsertTitleSlideAtBeginning(objective: String, dom: PresentationDOMSnapshot) -> LocalIntentPlan? {
        guard isInsertTitleSlideAtBeginningObjective(objective) else { return nil }
        if isInsertTitleSlideAtBeginningSatisfied(objective: objective, dom: dom) {
            return nil
        }

        let title = extractPrefaceTitle(from: objective)
            ?? extractNamedTitle(from: objective)
            ?? "Title"

        let operations: [[String: Any]] = [
            op(
                "ensureSlide",
                target: ["slideKey": "local_inserted_title_slide"],
                args: [
                    "index": 1,
                    "layout": "Title",
                    "title": title
                ],
                verify: ["slideExists": true]
            ),
            op(
                "ensureTextBox",
                target: [
                    "slideKey": "local_inserted_title_slide",
                    "elementName": "__ksk_role_title__"
                ],
                args: [
                    "text": title,
                    "style": ["role": "title"]
                ],
                verify: ["textPrefix": title]
            )
        ]

        return LocalIntentPlan(
            reason: "dom_insert_title_slide",
            assistantReply: "Inserted the title slide at the beginning.",
            operations: operations
        )
    }

    private func isInsertTitleSlideAtBeginningSatisfied(objective: String, dom: PresentationDOMSnapshot) -> Bool {
        guard isInsertTitleSlideAtBeginningObjective(objective),
              let firstSlide = dom.slide(at: 1) else {
            return false
        }

        let title = extractPrefaceTitle(from: objective)
            ?? extractNamedTitle(from: objective)
            ?? "Title"

        let layout = normalize(firstSlide.layoutName)
        let isTitleLayout = layout.contains("title") && !layout.contains("bullet") && !layout.contains("body")
        return isTitleLayout && normalize(firstSlide.title) == normalize(title)
    }

    private func isInsertTitleSlideAtBeginningObjective(_ objective: String) -> Bool {
        let lowered = objective.lowercased()
        guard lowered.contains("title slide") else { return false }
        return lowered.contains("beginning") || lowered.contains("start") || lowered.contains("front")
    }

    private func extractTopic(from objective: String) -> String? {
        let patterns = [
            #"preface\s+the\s+(.+?)\s+with"#,
            #"before\s+the\s+(.+?)(?:,| then| and| with)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(objective.startIndex..<objective.endIndex, in: objective)
            guard let match = regex.firstMatch(in: objective, options: [], range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: objective) else {
                continue
            }
            let value = objective[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return String(value)
            }
        }
        return nil
    }

    private func extractPrefaceTitle(from objective: String) -> String? {
        let pattern = #"title slide\s*[\"“](.+?)[\"”]"#
        return firstRegexCapture(pattern: pattern, in: objective)
    }

    private func extractNamedTitle(from objective: String) -> String? {
        let pattern = #"named\s+[\"“](.+?)[\"”]"#
        return firstRegexCapture(pattern: pattern, in: objective)
    }

    private func extractOutlineTitle(from objective: String, singularTopic: String) -> String {
        let quoted = firstRegexCapture(pattern: #"slide outlining\s*[\"“](.+?)[\"”]"#, in: objective)
        if let quoted, !quoted.isEmpty {
            return quoted
        }
        if objective.lowercased().contains("what is") || objective.lowercased().contains("what a") {
            return "What Is a \(titleCased(singularTopic))?"
        }
        return "Overview: \(titleCased(singularTopic))"
    }

    private func extractRenameTemplate(from objective: String) -> String? {
        let patterns = [
            #"rename.*?[\"“](.+?)[\"”]"#,
            #"titles?\s+of\s+the\s+following\s+slides?\s+[\"“](.+?)[\"”]"#
        ]
        for pattern in patterns {
            if let value = firstRegexCapture(pattern: pattern, in: objective), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func renderRenameTemplate(_ template: String, index: Int) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Example \(index)" }

        let hasPlaceholder = trimmed.range(of: #"\bx\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        if hasPlaceholder {
            return trimmed.replacingOccurrences(
                of: #"\bx\b"#,
                with: "\(index)",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        if trimmed.range(of: #"\d+"#, options: .regularExpression) != nil {
            return trimmed.replacingOccurrences(of: #"\d+"#, with: "\(index)", options: .regularExpression)
        }

        return "\(trimmed) \(index)"
    }

    private func genericOutlineBullets(topic: String) -> [String] {
        let token = titleCased(topic)
        return [
            "Definition and key characteristics of \(token)",
            "Typical structure and components",
            "How to recognize a strong \(token) example"
        ]
    }

    private func singularized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3 else { return trimmed }
        if trimmed.lowercased().hasSuffix("s") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }

    private func titleCased(_ raw: String) -> String {
        raw
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                let lower = token.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }

    private func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstRegexCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let captured = text[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return captured.isEmpty ? nil : String(captured)
    }

    private func op(
        _ name: String,
        target: [String: Any],
        args: [String: Any],
        verify: [String: Any]
    ) -> [String: Any] {
        [
            "op": name,
            "target": target,
            "args": args,
            "verify": verify
        ]
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func hasRenameCue(_ lowered: String) -> Bool {
        containsAny(lowered, [
            "rename",
            "retitle",
            "change the title",
            "change titles",
            "update titles",
            "rename the titles",
            "titles of the"
        ])
    }

    private func hasOutlineCue(_ lowered: String) -> Bool {
        containsAny(lowered, [
            "outline",
            "what is",
            "what a",
            "overview",
            "definition"
        ])
    }

    private func hasPrefaceCue(_ lowered: String) -> Bool {
        containsAny(lowered, [
            "preface",
            "before",
            "precede",
            "intro",
            "lead with"
        ])
    }
}
