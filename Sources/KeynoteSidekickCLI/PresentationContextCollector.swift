import Foundation

enum ContextCollectorError: LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return "Could not collect Keynote context: \(message)"
        }
    }
}

enum ContextDetailLevel: String {
    case summary
    case full
}

struct PresentationSelectionItem: Sendable {
    let name: String
    let type: String
    let textSnippet: String
}

struct PresentationFocusContext: Sendable {
    let currentSlideIndex: Int?
    let currentSlideTitle: String
    let selectedItems: [PresentationSelectionItem]

    static let empty = PresentationFocusContext(currentSlideIndex: nil, currentSlideTitle: "", selectedItems: [])
}

struct PresentationDOMSlide: Sendable {
    let index: Int
    let slideKey: String
  let stableSlideId: String
    let layoutName: String
  let masterName: String
    let title: String
    let body: String
    let notes: String
  let titleHash: String
  let bodyHash: String
  let notesHash: String
    let textItems: [String]
  let textItemHashes: [String]
  let anchors: [String]
  let elements: [PresentationDOMElement]
    let hasTitlePlaceholder: Bool
    let hasBodyPlaceholder: Bool
    let isSkipped: Bool

    var bodyLineCount: Int {
        body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }
}

struct PresentationDOMElement: Sendable {
  let elementId: String
  let name: String
  let role: String
  let kind: String
  let textSnippet: String
  let textHash: String
  let canonicalHandle: String
}

struct PresentationDOMSnapshot: Sendable {
    let slides: [PresentationDOMSlide]

    static let empty = PresentationDOMSnapshot(slides: [])

    var slideCount: Int {
        slides.count
    }

    func slide(at index: Int) -> PresentationDOMSlide? {
        slides.first(where: { $0.index == index })
    }

    func plannerPayload() -> [String: Any] {
      [
        "slideCount": slides.count,
        "slides": slides.map { slide in
          return [
            "index": slide.index,
            "slideKey": slide.slideKey,
            "stableSlideId": slide.stableSlideId,
            "layoutName": slide.layoutName,
            "masterName": slide.masterName,
            "title": [
              "text": slide.title,
              "hash": slide.titleHash
            ],
            "body": [
              "text": slide.body,
              "hash": slide.bodyHash,
              "lineCount": slide.bodyLineCount
            ],
            "notes": [
              "text": slide.notes,
              "hash": slide.notesHash
            ],
            "textItems": zip(slide.textItems, slide.textItemHashes).map { pair in
              return ["text": pair.0, "hash": pair.1]
            },
            "anchors": slide.anchors,
            "placeholders": [
              "hasTitle": slide.hasTitlePlaceholder,
              "hasBody": slide.hasBodyPlaceholder
            ],
            "isSkipped": slide.isSkipped,
            "elements": slide.elements.map { element in
              return [
                "elementId": element.elementId,
                "name": element.name,
                "role": element.role,
                "kind": element.kind,
                "textSnippet": element.textSnippet,
                "textHash": element.textHash,
                "canonicalHandle": element.canonicalHandle
              ]
            },
            "canonicalHandles": [
              "slide": "slideKey:\(slide.slideKey)",
              "title": "slideKey:\(slide.slideKey)#title",
              "body": "slideKey:\(slide.slideKey)#body"
            ]
          ]
        }
      ]
    }
}

struct PresentationContextSnapshot: Sendable {
    let context: String
    let focus: PresentationFocusContext
    let focusWarning: String?
    let dom: PresentationDOMSnapshot
}

final class PresentationContextCollector: @unchecked Sendable {
    func collectSummary(maxSlides: Int = 12) throws -> String {
        try collectContext(level: .summary, maxSlides: maxSlides)
    }

    func collectContext(level: ContextDetailLevel, maxSlides: Int = 12) throws -> String {
        try collectSnapshot(level: level, maxSlides: maxSlides).context
    }

    func collectSnapshot(level: ContextDetailLevel, maxSlides: Int = 12) throws -> PresentationContextSnapshot {
        var warnings: [String] = []
        let context: String
        switch level {
        case .summary:
            context = try runAppleScript(summaryScript(maxSlides: maxSlides))
        case .full:
            context = try runAppleScript(fullDeckScript())
        }
        var dom = PresentationDOMSnapshot.empty
        do {
            dom = try collectDOM(level: .full, maxSlides: maxSlides)
        } catch {
            warnings.append("DOM context unavailable: \(error.localizedDescription)")
        }
        do {
            let focus = try collectFocusContext()
            let warningText = warnings.isEmpty ? nil : warnings.joined(separator: " | ")
            return PresentationContextSnapshot(context: context, focus: focus, focusWarning: warningText, dom: dom)
        } catch {
            warnings.append(error.localizedDescription)
            return PresentationContextSnapshot(
                context: context,
                focus: .empty,
                focusWarning: warnings.joined(separator: " | "),
                dom: dom
            )
        }
    }

    func collectDOM(level: ContextDetailLevel = .full, maxSlides: Int = 12) throws -> PresentationDOMSnapshot {
        let raw = try runAppleScript(domScript(level: level, maxSlides: maxSlides))
        return parseDOM(raw)
    }

    func collectFocusContext() throws -> PresentationFocusContext {
        let raw = try runAppleScript(focusScript())
        return parseFocusContext(raw)
    }

    private func parseDOM(_ raw: String) -> PresentationDOMSnapshot {
        guard !raw.isEmpty else { return .empty }

        let fieldSeparator = Character(UnicodeScalar(30))
        let itemSeparator = Character(UnicodeScalar(31))
        var slideRows: [[String: String]] = []
        var elementsBySlideIndex: [Int: [PresentationDOMElement]] = [:]

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            let parts = text.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
          guard let rowType = parts.first else { continue }

            var fields: [String: String] = [:]
            for part in parts.dropFirst() {
                guard let equals = part.firstIndex(of: "=") else { continue }
                let key = String(part[..<equals])
                let value = String(part[part.index(after: equals)...])
                fields[key] = value
            }

          guard let indexText = fields["index"],
              let index = Int(indexText),
              index > 0 else {
            continue
          }

          if rowType == "slide" {
            slideRows.append(fields)
            continue
          }

          if rowType == "element" {
            let elementName = unescapeDOMText(fields["name"] ?? "")
            let elementRole = unescapeDOMText(fields["role"] ?? "")
            let elementKind = unescapeDOMText(fields["kind"] ?? "")
            let elementText = unescapeDOMText(fields["text"] ?? "")
            let stableSlideId = "s\(index)"
            let explicitId = unescapeDOMText(fields["id"] ?? "")
            let elementId = explicitId.isEmpty
              ? "\(stableSlideId)_e\((elementsBySlideIndex[index]?.count ?? 0) + 1)"
              : explicitId
            let canonicalHandle: String
            if !elementRole.isEmpty {
              canonicalHandle = "slide:\(stableSlideId)#\(normalizeAnchorToken(elementRole))"
            } else {
              canonicalHandle = "slide:\(stableSlideId)#\(normalizeAnchorToken(elementName))"
            }
            let element = PresentationDOMElement(
              elementId: elementId,
              name: elementName,
              role: elementRole,
              kind: elementKind,
              textSnippet: elementText,
              textHash: stableTextHash(elementText),
              canonicalHandle: canonicalHandle
            )
            elementsBySlideIndex[index, default: []].append(element)
          }
        }

        var slides: [PresentationDOMSlide] = []
        for fields in slideRows {
          guard let indexText = fields["index"],
              let index = Int(indexText),
              index > 0 else {
            continue
          }

            let textItemsBlob = fields["textItems"] ?? ""
            let textItems: [String]
            if textItemsBlob.isEmpty {
                textItems = []
            } else {
                textItems = textItemsBlob
                    .split(separator: itemSeparator, omittingEmptySubsequences: false)
                    .map { unescapeDOMText(String($0)) }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }

                let titleText = unescapeDOMText(fields["title"] ?? "")
                let bodyText = unescapeDOMText(fields["body"] ?? "")
                let notesText = unescapeDOMText(fields["notes"] ?? "")
                let layoutName = unescapeDOMText(fields["layout"] ?? "")
                let masterName = unescapeDOMText(fields["master"] ?? layoutName)
                let stableSlideId = "s\(index)"
                let anchors = inferAnchors(
                  slideKey: fields["key"] ?? "slide_\(index)",
                  title: titleText,
                  body: bodyText,
                  textItems: textItems
                )
                let defaultElements = defaultElementsForSlide(
                  stableSlideId: stableSlideId,
                  title: titleText,
                  body: bodyText,
                  hasTitlePlaceholder: boolValue(from: fields["hasTitle"]),
                  hasBodyPlaceholder: boolValue(from: fields["hasBody"]),
                  textItems: textItems
                )
                let explicitElements = elementsBySlideIndex[index] ?? []
                let mergedElements = mergeElements(defaultElements: defaultElements, explicitElements: explicitElements)
                let textItemHashes = textItems.map(stableTextHash)

            slides.append(
                PresentationDOMSlide(
                    index: index,
                    slideKey: fields["key"] ?? "slide_\(index)",
                    stableSlideId: stableSlideId,
                    layoutName: layoutName,
                    masterName: masterName,
                    title: titleText,
                    body: bodyText,
                    notes: notesText,
                    titleHash: stableTextHash(titleText),
                    bodyHash: stableTextHash(bodyText),
                    notesHash: stableTextHash(notesText),
                    textItems: textItems,
                    textItemHashes: textItemHashes,
                    anchors: anchors,
                    elements: mergedElements,
                    hasTitlePlaceholder: boolValue(from: fields["hasTitle"]),
                    hasBodyPlaceholder: boolValue(from: fields["hasBody"]),
                    isSkipped: boolValue(from: fields["skipped"])
                )
            )
        }

        slides.sort { $0.index < $1.index }
        return PresentationDOMSnapshot(slides: slides)
    }

    private func boolValue(from raw: String?) -> Bool {
        guard let raw else { return false }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token == "1" || token == "true" || token == "yes"
    }

    private func unescapeDOMText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
    }

    private func normalizeAnchorToken(_ raw: String) -> String {
      raw
        .lowercased()
        .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func inferAnchors(slideKey: String, title: String, body: String, textItems: [String]) -> [String] {
      var anchors = Set<String>()
      anchors.insert("slide_key:\(slideKey)")

      let titleToken = normalizeAnchorToken(title)
      if !titleToken.isEmpty {
        anchors.insert("title:\(titleToken)")
      }

      let bodyToken = normalizeAnchorToken(body)
      if !bodyToken.isEmpty {
        anchors.insert("body:\(String(bodyToken.prefix(48)))")
      }

      let joinedText = ([title, body] + textItems).joined(separator: " ").lowercased()
      if joinedText.contains("example") {
        anchors.insert("group:example")
      }
      if joinedText.contains("outline") {
        anchors.insert("group:outline")
      }

      return anchors.sorted()
    }

    private func stableTextHash(_ text: String) -> String {
      let bytes = [UInt8](text.utf8)
      var hash: UInt64 = 0xcbf29ce484222325
      let prime: UInt64 = 0x100000001b3
      for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* prime
      }
      return String(format: "%016llx", hash)
    }

    private func defaultElementsForSlide(
      stableSlideId: String,
      title: String,
      body: String,
      hasTitlePlaceholder: Bool,
      hasBodyPlaceholder: Bool,
      textItems: [String]
    ) -> [PresentationDOMElement] {
      var elements: [PresentationDOMElement] = []

      if hasTitlePlaceholder {
        elements.append(
          PresentationDOMElement(
            elementId: "\(stableSlideId)_title_placeholder",
            name: "Title",
            role: "title",
            kind: "placeholder",
            textSnippet: title,
            textHash: stableTextHash(title),
            canonicalHandle: "slide:\(stableSlideId)#title"
          )
        )
      }

      if hasBodyPlaceholder {
        elements.append(
          PresentationDOMElement(
            elementId: "\(stableSlideId)_body_placeholder",
            name: "Body",
            role: "body",
            kind: "placeholder",
            textSnippet: body,
            textHash: stableTextHash(body),
            canonicalHandle: "slide:\(stableSlideId)#body"
          )
        )
      }

      for (offset, text) in textItems.enumerated() {
        let ordinal = offset + 1
        elements.append(
          PresentationDOMElement(
            elementId: "\(stableSlideId)_text_\(ordinal)",
            name: "Text \(ordinal)",
            role: "text",
            kind: "text_item",
            textSnippet: text,
            textHash: stableTextHash(text),
            canonicalHandle: "slide:\(stableSlideId)#text_\(ordinal)"
          )
        )
      }

      return elements
    }

    private func mergeElements(
      defaultElements: [PresentationDOMElement],
      explicitElements: [PresentationDOMElement]
    ) -> [PresentationDOMElement] {
      guard !explicitElements.isEmpty else { return defaultElements }
      var seen = Set<String>()
      var merged: [PresentationDOMElement] = []

      for element in explicitElements + defaultElements {
        if seen.insert(element.elementId).inserted {
          merged.append(element)
        }
      }

      return merged
    }

    private func parseFocusContext(_ raw: String) -> PresentationFocusContext {
        if raw.isEmpty {
            return .empty
        }

        var currentSlideIndex: Int?
        var currentSlideTitle = ""
        var selectedItems: [PresentationSelectionItem] = []
        let fieldSeparator = Character(UnicodeScalar(31))

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            if text.hasPrefix("currentSlideIndex|") {
                let value = String(text.dropFirst("currentSlideIndex|".count))
                currentSlideIndex = Int(value)
                continue
            }
            if text.hasPrefix("currentSlideTitle|") {
                currentSlideTitle = String(text.dropFirst("currentSlideTitle|".count))
                continue
            }
            if text.hasPrefix("selected|") {
                let payload = String(text.dropFirst("selected|".count))
                let parts = payload.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
                var name = ""
                var type = ""
                var textSnippet = ""
                for part in parts {
                    if part.hasPrefix("name=") {
                        name = String(part.dropFirst("name=".count))
                    } else if part.hasPrefix("type=") {
                        type = String(part.dropFirst("type=".count))
                    } else if part.hasPrefix("text=") {
                        textSnippet = String(part.dropFirst("text=".count))
                    }
                }
                selectedItems.append(
                    PresentationSelectionItem(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        type: type.trimmingCharacters(in: .whitespacesAndNewlines),
                        textSnippet: textSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }

        return PresentationFocusContext(
            currentSlideIndex: currentSlideIndex,
            currentSlideTitle: currentSlideTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedItems: selectedItems
        )
    }

    private func focusScript() -> String {
        """
        on replaceOccurrences(theText, searchText, replacementText)
          set AppleScript's text item delimiters to searchText
          set chunks to every text item of (theText as text)
          set AppleScript's text item delimiters to replacementText
          set updatedText to chunks as text
          set AppleScript's text item delimiters to ""
          return updatedText
        end replaceOccurrences

        on sanitizeText(inputText)
          if inputText is missing value then return ""
          set outText to inputText as text
          set outText to my replaceOccurrences(outText, return, " ")
          set outText to my replaceOccurrences(outText, linefeed, " ")
          return outText
        end sanitizeText

        tell application "Keynote"
          if (count of documents) is 0 then error "No open Keynote presentation"
          set d to front document
          set outLines to {}
          set fieldSep to ASCII character 31

          set selectedItems to {}
          try
            set selectedItems to selection of d
          end try

          set currentSlideIndexText to ""
          set currentSlideTitle to ""
          try
            set cs to current slide of d
            set currentSlideIndexText to (slide number of cs) as text
            try
              set currentSlideTitle to (object text of default title item of cs as text)
            end try
          end try

          if currentSlideIndexText is "" then
            if (count of selectedItems) > 0 then
              set firstSelected to item 1 of selectedItems
              set hostSlide to missing value
              try
                set hostSlide to slide of firstSelected
              end try
              if hostSlide is missing value then
                try
                  set hostSlide to parent of firstSelected
                end try
              end if
              if hostSlide is not missing value then
                try
                  set currentSlideIndexText to (slide number of hostSlide) as text
                end try
                try
                  set currentSlideTitle to (object text of default title item of hostSlide as text)
                end try
              end if
            end if
          end if

          set currentSlideTitle to my sanitizeText(currentSlideTitle)

          set end of outLines to "currentSlideIndex|" & currentSlideIndexText
          set end of outLines to "currentSlideTitle|" & currentSlideTitle

          repeat with si in selectedItems
            set itemName to ""
            set itemType to ""
            set itemText to ""
            try
              set itemName to (name of si as text)
            end try
            try
              set itemType to (class of si as text)
            end try
            try
              set itemText to (object text of si as text)
            end try
            if (count of characters of itemText) > 180 then set itemText to text 1 thru 180 of itemText

            set itemName to my sanitizeText(itemName)
            set itemType to my sanitizeText(itemType)
            set itemText to my sanitizeText(itemText)

            set rowText to "name=" & itemName & fieldSep & "type=" & itemType & fieldSep & "text=" & itemText
            set end of outLines to "selected|" & rowText
          end repeat

          set AppleScript's text item delimiters to linefeed
          set payload to outLines as text
          set AppleScript's text item delimiters to ""
          return payload
        end tell
        """
    }

    func describeFocus(_ focus: PresentationFocusContext) -> String {
        var lines: [String] = []
        if let index = focus.currentSlideIndex {
            lines.append("current slide: \(index) (\(focus.currentSlideTitle))")
        } else {
            lines.append("current slide: unknown")
        }
        if focus.selectedItems.isEmpty {
            lines.append("selection: none")
        } else {
            let selected = focus.selectedItems.enumerated().map { offset, item in
                let name = item.name.isEmpty ? "(unnamed)" : item.name
                return "#\(offset + 1) name=\(name) type=\(item.type)"
            }
            lines.append("selection: \(selected.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    private func summaryScript(maxSlides: Int) -> String {
        """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open Keynote presentation"
          set d to front document
          set totalSlides to count of slides of d
          set limitSlides to \(maxSlides)
          if totalSlides < limitSlides then set limitSlides to totalSlides
          if limitSlides < 1 then set limitSlides to 1
          set currentIndex to totalSlides
          try
            set currentIndex to (slide number of current slide of d)
          end try
          if currentIndex < 1 then set currentIndex to 1
          if currentIndex > totalSlides then set currentIndex to totalSlides
          set startIndex to currentIndex - limitSlides + 1
          if startIndex < 1 then set startIndex to 1
          set endIndex to startIndex + limitSlides - 1
          if endIndex > totalSlides then
            set endIndex to totalSlides
            set startIndex to endIndex - limitSlides + 1
            if startIndex < 1 then set startIndex to 1
          end if
          set outLines to {}

          repeat with i from startIndex to endIndex
            set s to slide i of d
            set slideTitle to ""
            try
              set slideTitle to (object text of default title item of s as text)
            end try

            set notesText to ""
            try
              set notesText to (presenter notes of s as text)
            end try
            if (count of characters of notesText) > 160 then set notesText to text 1 thru 160 of notesText

            set snippets to {}
            set c to 0
            repeat with ti in every text item of s
              set tx to ""
              try
                set tx to (object text of ti as text)
              end try
              if (count of characters of tx) > 90 then set tx to text 1 thru 90 of tx
              if tx is not "" then
                set end of snippets to tx
                set c to c + 1
              end if
              if c >= 3 then exit repeat
            end repeat

            set AppleScript's text item delimiters to " || "
            set snippetText to snippets as text
            set AppleScript's text item delimiters to ""

            set lineText to "slide " & (i as text) & ": title=" & slideTitle & " | notes=" & notesText & " | text=" & snippetText
            set end of outLines to lineText
          end repeat

          set AppleScript's text item delimiters to linefeed
          set payload to outLines as text
          set AppleScript's text item delimiters to ""
          return payload
        end tell
        """
    }

    private func fullDeckScript() -> String {
        """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open Keynote presentation"
          set d to front document
          set totalSlides to count of slides of d
          set outLines to {}
          set sep to ASCII character 31

          repeat with i from 1 to totalSlides
            set s to slide i of d

            set slideTitle to ""
            try
              set slideTitle to (object text of default title item of s as text)
            end try

            set notesText to ""
            try
              set notesText to (presenter notes of s as text)
            end try

            set snippets to {}
            repeat with ti in every text item of s
              set tx to ""
              try
                set tx to (object text of ti as text)
              end try
              if tx is not "" then set end of snippets to tx
            end repeat

            set AppleScript's text item delimiters to sep
            set snippetText to snippets as text
            set AppleScript's text item delimiters to ""

            set lineText to "slide " & (i as text) & ": title=" & slideTitle & " | notes=" & notesText & " | textItems=" & snippetText
            set end of outLines to lineText
          end repeat

          set AppleScript's text item delimiters to linefeed
          set payload to outLines as text
          set AppleScript's text item delimiters to ""
          return payload
        end tell
        """
    }

    private func domScript(level: ContextDetailLevel, maxSlides: Int) -> String {
        let includeAll = (level == .full) ? "true" : "false"
        return """
        on replaceOccurrences(theText, searchText, replacementText)
          set AppleScript's text item delimiters to searchText
          set chunks to every text item of (theText as text)
          set AppleScript's text item delimiters to replacementText
          set updatedText to chunks as text
          set AppleScript's text item delimiters to ""
          return updatedText
        end replaceOccurrences

        on sanitizeText(inputText, fieldSep, itemSep)
          if inputText is missing value then return ""
          set outText to inputText as text
          set outText to my replaceOccurrences(outText, fieldSep, " ")
          set outText to my replaceOccurrences(outText, itemSep, " ")
          set outText to my replaceOccurrences(outText, return, "\\n")
          set outText to my replaceOccurrences(outText, linefeed, "\\n")
          return outText
        end sanitizeText

        tell application "Keynote"
          if (count of documents) is 0 then error "No open Keynote presentation"
          set d to front document
          set totalSlides to count of slides of d
          if totalSlides < 1 then return ""

          set includeAll to \(includeAll)
          set limitSlides to \(maxSlides)
          if limitSlides < 1 then set limitSlides to 1

          set startIndex to 1
          set endIndex to totalSlides
          if includeAll is false then
            if totalSlides < limitSlides then set limitSlides to totalSlides
            set currentIndex to totalSlides
            try
              set currentIndex to (slide number of current slide of d)
            end try
            if currentIndex < 1 then set currentIndex to 1
            if currentIndex > totalSlides then set currentIndex to totalSlides

            set startIndex to currentIndex - limitSlides + 1
            if startIndex < 1 then set startIndex to 1
            set endIndex to startIndex + limitSlides - 1
            if endIndex > totalSlides then
              set endIndex to totalSlides
              set startIndex to endIndex - limitSlides + 1
              if startIndex < 1 then set startIndex to 1
            end if
          end if

          set fieldSep to ASCII character 30
          set itemSep to ASCII character 31
          set outLines to {}

          repeat with i from startIndex to endIndex
            set s to slide i of d
            set layoutName to ""
            set masterName to ""
            set titleText to ""
            set bodyText to ""
            set notesText to ""
            set hasTitle to "0"
            set hasBody to "0"
            set skippedText to "0"

            try
              set layoutName to (name of base slide of s as text)
            end try

            try
              set masterName to (name of base slide of s as text)
            end try

            try
              set titleRef to default title item of s
              set hasTitle to "1"
              try
                set titleText to (object text of titleRef as text)
              end try
            end try

            try
              set bodyRef to default body item of s
              set hasBody to "1"
              try
                set bodyText to (object text of bodyRef as text)
              end try
            end try

            try
              set notesText to (presenter notes of s as text)
            end try

            try
              if (skipped of s) is true then set skippedText to "1"
            end try

            set textParts to {}
            repeat with ti in every text item of s
              set tx to ""
              try
                set tx to (object text of ti as text)
              end try
              set tx to my sanitizeText(tx, fieldSep, itemSep)
              if tx is not "" then set end of textParts to tx
            end repeat

            set AppleScript's text item delimiters to itemSep
            set textItemsBlob to textParts as text
            set AppleScript's text item delimiters to ""

            set rowText to "slide" & fieldSep & "index=" & (i as text) & fieldSep & "key=slide_" & (i as text) & fieldSep & "layout=" & (my sanitizeText(layoutName, fieldSep, itemSep)) & fieldSep & "master=" & (my sanitizeText(masterName, fieldSep, itemSep)) & fieldSep & "title=" & (my sanitizeText(titleText, fieldSep, itemSep)) & fieldSep & "body=" & (my sanitizeText(bodyText, fieldSep, itemSep)) & fieldSep & "notes=" & (my sanitizeText(notesText, fieldSep, itemSep)) & fieldSep & "textItems=" & textItemsBlob & fieldSep & "hasTitle=" & hasTitle & fieldSep & "hasBody=" & hasBody & fieldSep & "skipped=" & skippedText
            set end of outLines to rowText

            set elementOrdinal to 0
            repeat with ti in every text item of s
              set elementOrdinal to elementOrdinal + 1
              set elementName to ""
              set elementKind to "text item"
              set elementText to ""
              try
                set elementName to (name of ti as text)
              end try
              try
                set elementKind to (class of ti as text)
              end try
              try
                set elementText to (object text of ti as text)
              end try
              set elementRole to "text"
              if hasTitle is "1" then
                try
                  if (id of ti) is (id of default title item of s) then set elementRole to "title"
                end try
              end if
              if hasBody is "1" then
                try
                  if (id of ti) is (id of default body item of s) then set elementRole to "body"
                end try
              end if
              set elementId to "s" & (i as text) & "_text_" & (elementOrdinal as text)
              set elementRow to "element" & fieldSep & "index=" & (i as text) & fieldSep & "id=" & elementId & fieldSep & "name=" & (my sanitizeText(elementName, fieldSep, itemSep)) & fieldSep & "role=" & elementRole & fieldSep & "kind=" & (my sanitizeText(elementKind, fieldSep, itemSep)) & fieldSep & "text=" & (my sanitizeText(elementText, fieldSep, itemSep))
              set end of outLines to elementRow
            end repeat
          end repeat

          set AppleScript's text item delimiters to linefeed
          set payload to outLines as text
          set AppleScript's text item delimiters to ""
          return payload
        end tell
        """
    }

    private func runAppleScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw ContextCollectorError.scriptFailed(err.isEmpty ? "osascript failed" : err)
        }

        return out
    }
}
