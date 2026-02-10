import Foundation
import CryptoKit
import KeynoteSidekickCore

private struct MockElement {
    var name: String
    var type: SlideElementType
    var frame: Frame?
    var text: String?
    var bulletCount: Int?
    var imagePath: String?
    var opacity: Double
    var zIndex: Int
    var textStyle: [String: JSONValue]
    var paragraphStyle: [String: JSONValue]
    var fillStyle: [String: JSONValue]
    var strokeStyle: [String: JSONValue]
}

private struct MockSlide {
    var key: String
    var title: String?
    var notes: String
    var hidden: Bool
    var elements: [String: MockElement]
}

public final class MockKeynoteAdapter: KeynoteAutomationAdapter {
    public let adapterName = "mock"
    public let defaultDriver: DriverUsed = .mock

    private var isOpen = false
    private var presentationPath: String?
    private var slides: [MockSlide] = []
    private var aliases: [String: [String: String]] = [:]
    private var slideAliases: [String: String] = [:]
    public private(set) var refreshSlideBindingsCallCount = 0

    public init() {}

    public func openPresentation(path: String) throws {
        self.presentationPath = path
        self.isOpen = true
    }

    public func attachToFrontPresentation() throws {
        self.isOpen = true
    }

    public func savePresentation() throws {
        guard isOpen else {
            throw AdapterError(code: "NO_PRESENTATION", message: "No presentation is open")
        }
    }

    public func ensureSlide(slideKey: String, layout: String?, index: Int?, title: String?) throws {
        let normalizedLayout = (layout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOpen else { throw AdapterError(code: "NO_PRESENTATION", message: "No presentation is open") }

        if let existing = slideIndex(slideKey: slideKey) {
            if let title {
                slides[existing].title = title
            }
            return
        }

        if normalizedLayout.isEmpty,
           let index,
           index > 0,
           index <= slides.count {
            let canonical = slides[index - 1].key
            slideAliases[slideKey] = canonical
            if let title {
                slides[index - 1].title = title
            }
            return
        }

        let slide = MockSlide(key: slideKey, title: title, notes: "", hidden: false, elements: [:])
        if let index, index > 0, index <= slides.count {
            slides.insert(slide, at: index - 1)
        } else {
            slides.append(slide)
        }
    }

    public func duplicateSlide(fromSlideKey: String, slideKey: String, index: Int?, title: String?) throws {
        guard let sourceIndex = slideIndex(slideKey: fromSlideKey) else {
            throw AdapterError(code: "MISSING_SLIDE", message: "Unknown fromSlideKey \(fromSlideKey)")
        }

        var duplicated = slides[sourceIndex]
        duplicated.key = slideKey
        if let title {
            duplicated.title = title
        }

        if let index, index > 0, index <= slides.count {
            slides.insert(duplicated, at: index - 1)
        } else {
            slides.append(duplicated)
        }
    }

    public func deleteSlide(slideKey: String) throws {
        let index = try requireSlide(slideKey)
        let canonical = canonicalSlideKey(for: slideKey)
        slides.remove(at: index)
        aliases.removeValue(forKey: canonical)
        slideAliases = slideAliases.filter { key, value in
            key != canonical && value != canonical
        }
    }

    public func hideSlide(slideKey: String, hidden: Bool) throws {
        let index = try requireSlide(slideKey)
        slides[index].hidden = hidden
    }

    public func moveSlide(slideKey: String, index: Int) throws {
        let sourceIndex = try requireSlide(slideKey)
        var targetIndex = max(index, 1)
        let slide = slides.remove(at: sourceIndex)
        let insertionUpperBound = slides.count + 1
        if targetIndex > insertionUpperBound {
            targetIndex = insertionUpperBound
        }
        slides.insert(slide, at: targetIndex - 1)
    }

    public func ensureTextBox(slideKey: String, elementName: String, text: String, frame: Frame?, role: String?) throws {
        _ = role
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]

        if var element = slide.elements[key] {
            element.text = text
            element.frame = frame ?? element.frame
            element.type = .text
            element.bulletCount = lineCount(in: text)
            slide.elements[key] = element
        } else {
            let element = MockElement(
                name: key,
                type: .text,
                frame: frame,
                text: text,
                bulletCount: lineCount(in: text),
                imagePath: nil,
                opacity: 100,
                zIndex: nextZ(in: slide),
                textStyle: [:],
                paragraphStyle: [:],
                fillStyle: [:],
                strokeStyle: [:]
            )
            slide.elements[key] = element
        }

        slides[index] = slide
    }

    public func ensureBullets(slideKey: String, elementName: String, items: [String], frame: Frame?) throws {
        let text = items.joined(separator: "\n")
        try ensureTextBox(slideKey: slideKey, elementName: elementName, text: text, frame: frame, role: "body")
    }

    public func ensureImage(slideKey: String, elementName: String, path: String, frame: Frame?) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]

        if var element = slide.elements[key] {
            element.type = .image
            element.frame = frame ?? element.frame
            element.imagePath = path
            slide.elements[key] = element
        } else {
            let element = MockElement(
                name: key,
                type: .image,
                frame: frame,
                text: nil,
                bulletCount: nil,
                imagePath: path,
                opacity: 100,
                zIndex: nextZ(in: slide),
                textStyle: [:],
                paragraphStyle: [:],
                fillStyle: [:],
                strokeStyle: [:]
            )
            slide.elements[key] = element
        }

        slides[index] = slide
    }

    public func ensureShape(slideKey: String, elementName: String, shapeType: String?, text: String?, frame: Frame?) throws {
        _ = shapeType
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]

        if var element = slide.elements[key] {
            element.type = .shape
            element.frame = frame ?? element.frame
            element.text = text ?? element.text
            element.bulletCount = lineCount(in: element.text ?? "")
            slide.elements[key] = element
        } else {
            let textValue = text ?? ""
            let element = MockElement(
                name: key,
                type: .shape,
                frame: frame,
                text: textValue,
                bulletCount: lineCount(in: textValue),
                imagePath: nil,
                opacity: 100,
                zIndex: nextZ(in: slide),
                textStyle: [:],
                paragraphStyle: [:],
                fillStyle: [:],
                strokeStyle: [:]
            )
            slide.elements[key] = element
        }

        slides[index] = slide
    }

    public func deleteElement(slideKey: String, elementName: String) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard slide.elements.removeValue(forKey: key) != nil else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }
        slides[index] = slide
    }

    public func setFrame(slideKey: String, elementName: String, frame: Frame) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard var element = slide.elements[key] else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }

        element.frame = frame
        slide.elements[key] = element
        slides[index] = slide
    }

    public func setOpacity(slideKey: String, elementName: String, opacity: Double) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard var element = slide.elements[key] else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }

        element.opacity = max(0, min(100, opacity))
        slide.elements[key] = element
        slides[index] = slide
    }

    public func setZOrder(slideKey: String, elementName: String, mode: ZOrderMode) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard let target = slide.elements[key] else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }

        var ordered = slide.elements.values.sorted { $0.zIndex < $1.zIndex }
        guard let currentIndex = ordered.firstIndex(where: { $0.name == target.name }) else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }

        let moved = ordered.remove(at: currentIndex)
        switch mode {
        case .bringToFront:
            ordered.append(moved)
        case .sendToBack:
            ordered.insert(moved, at: 0)
        case .bringForward:
            let destination = min(currentIndex + 1, ordered.count)
            ordered.insert(moved, at: destination)
        case .sendBackward:
            let destination = max(0, currentIndex - 1)
            ordered.insert(moved, at: destination)
        }

        for (offset, value) in ordered.enumerated() {
            var updated = value
            updated.zIndex = offset + 1
            slide.elements[updated.name] = updated
        }

        slides[index] = slide
    }

    public func setPresenterNotes(slideKey: String, text: String) throws {
        guard let index = slideIndex(slideKey: slideKey) else {
            throw AdapterError(code: "MISSING_SLIDE", message: "Slide \(slideKey) not found")
        }
        slides[index].notes = text
    }

    public func setTextStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard var element = slide.elements[key] else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }
        element.textStyle.merge(style) { _, new in new }
        slide.elements[key] = element
        slides[index] = slide
    }

    public func setParagraphStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard var element = slide.elements[key] else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }
        element.paragraphStyle.merge(style) { _, new in new }
        slide.elements[key] = element
        slides[index] = slide
    }

    public func setFillStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard var element = slide.elements[key] else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }
        element.fillStyle.merge(style) { _, new in new }
        slide.elements[key] = element
        slides[index] = slide
    }

    public func setStrokeStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        var slide = slides[index]
        guard var element = slide.elements[key] else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(elementName) not found")
        }
        element.strokeStyle.merge(style) { _, new in new }
        slide.elements[key] = element
        slides[index] = slide
    }

    public func alignElements(slideKey: String, elementNames: [String], alignment: String, useSelection: Bool) throws {
        _ = useSelection
        let index = try requireSlide(slideKey)
        var slide = slides[index]
        let keys = try requireTargetKeys(slideKey: slideKey, requestedNames: elementNames)
        guard keys.count >= 2 else {
            throw AdapterError(code: "ALIGNMENT_INPUT", message: "alignElements requires at least two elements")
        }

        let frames = keys.compactMap { key -> (String, Frame)? in
            guard let frame = slide.elements[key]?.frame else { return nil }
            return (key, frame)
        }
        guard frames.count >= 2 else {
            throw AdapterError(code: "ALIGNMENT_INPUT", message: "alignElements requires at least two elements with frames")
        }

        let axis = alignment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minX = frames.map { $0.1.x }.min() ?? 0
        let maxX = frames.map { $0.1.x + $0.1.width }.max() ?? 0
        let minY = frames.map { $0.1.y }.min() ?? 0
        let maxY = frames.map { $0.1.y + $0.1.height }.max() ?? 0
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        for (key, frame) in frames {
            guard var element = slide.elements[key] else { continue }
            var updated = frame
            switch axis {
            case "left", "leading":
                updated.x = minX
            case "center", "centerx", "horizontalcenter":
                updated.x = centerX - (frame.width / 2)
            case "right", "trailing":
                updated.x = maxX - frame.width
            case "top":
                updated.y = minY
            case "middle", "centery", "verticalcenter":
                updated.y = centerY - (frame.height / 2)
            case "bottom":
                updated.y = maxY - frame.height
            default:
                throw AdapterError(code: "ALIGNMENT_MODE", message: "Unsupported alignment \(alignment)")
            }
            element.frame = updated
            slide.elements[key] = element
        }

        slides[index] = slide
    }

    public func distributeElements(slideKey: String, elementNames: [String], axis: String, spacing: Double?, useSelection: Bool) throws {
        _ = useSelection
        let index = try requireSlide(slideKey)
        var slide = slides[index]
        let keys = try requireTargetKeys(slideKey: slideKey, requestedNames: elementNames)
        guard keys.count >= 3 else {
            throw AdapterError(code: "DISTRIBUTE_INPUT", message: "distributeElements requires at least three elements")
        }

        var items: [(String, Frame)] = keys.compactMap { key in
            guard let frame = slide.elements[key]?.frame else { return nil }
            return (key, frame)
        }
        guard items.count >= 3 else {
            throw AdapterError(code: "DISTRIBUTE_INPUT", message: "distributeElements requires at least three elements with frames")
        }

        let normalizedAxis = axis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedAxis {
        case "horizontal", "x":
            items.sort { $0.1.x < $1.1.x }
            let start = items.first!.1.x
            let firstWidth = items.first!.1.width
            let end = items.last!.1.x + items.last!.1.width
            let middleWidths = items.dropFirst().dropLast().reduce(0.0) { $0 + $1.1.width }
            let gap = spacing ?? ((end - start - firstWidth - middleWidths - items.last!.1.width) / Double(items.count - 1))
            var cursor = start + firstWidth + gap
            for idx in 1..<(items.count - 1) {
                let key = items[idx].0
                var frame = items[idx].1
                frame.x = cursor
                cursor += frame.width + gap
                if var element = slide.elements[key] {
                    element.frame = frame
                    slide.elements[key] = element
                }
            }
        case "vertical", "y":
            items.sort { $0.1.y < $1.1.y }
            let start = items.first!.1.y
            let firstHeight = items.first!.1.height
            let end = items.last!.1.y + items.last!.1.height
            let middleHeights = items.dropFirst().dropLast().reduce(0.0) { $0 + $1.1.height }
            let gap = spacing ?? ((end - start - firstHeight - middleHeights - items.last!.1.height) / Double(items.count - 1))
            var cursor = start + firstHeight + gap
            for idx in 1..<(items.count - 1) {
                let key = items[idx].0
                var frame = items[idx].1
                frame.y = cursor
                cursor += frame.height + gap
                if var element = slide.elements[key] {
                    element.frame = frame
                    slide.elements[key] = element
                }
            }
        default:
            throw AdapterError(code: "DISTRIBUTE_AXIS", message: "Unsupported distribute axis \(axis)")
        }

        slides[index] = slide
    }

    public func isPresentationOpen() throws -> Bool {
        isOpen
    }

    public func slideExists(slideKey: String) throws -> Bool {
        slideIndex(slideKey: slideKey) != nil
    }

    public func element(slideKey: String, elementName: String) throws -> SlideElementSnapshot? {
        let index = try requireSlide(slideKey)
        let key = resolveElementName(slideKey: slideKey, elementName: elementName)
        guard let element = slides[index].elements[key] else {
            return nil
        }

        return SlideElementSnapshot(
            name: element.name,
            type: element.type,
            frame: element.frame,
            text: element.text,
            bulletCount: element.bulletCount
        )
    }

    public func presenterNotes(slideKey: String) throws -> String? {
        guard let index = slideIndex(slideKey: slideKey) else { return nil }
        return slides[index].notes
    }

    public func knownSlideBindings() throws -> [String: Int] {
        var bindings: [String: Int] = [:]
        for (offset, slide) in slides.enumerated() {
            bindings[slide.key] = offset + 1
        }
        for (alias, canonical) in slideAliases {
            if let index = slides.firstIndex(where: { $0.key == canonical }) {
                bindings[alias] = index + 1
            }
        }
        return bindings
    }

    public func refreshSlideBindings() throws -> [String: Int] {
        refreshSlideBindingsCallCount += 1
        return try knownSlideBindings()
    }

    public func enumerateSlideElements(slideKey: String) throws -> [SlideElementDescriptor] {
        guard let index = slideIndex(slideKey: slideKey) else { return [] }
        return slides[index].elements.values.map { element in
            SlideElementDescriptor(
                name: element.name,
                type: element.type,
                frame: element.frame,
                textSnippet: element.text.map { String($0.prefix(80)) }
            )
        }
    }

    public func applyResyncBindings(slideKey: String, matches: [ResyncMatch]) throws {
        let canonical = canonicalSlideKey(for: slideKey)
        var map = aliases[canonical] ?? [:]
        for match in matches {
            if let actualName = match.element.name {
                map[match.target.elementName] = actualName
            }
        }
        aliases[canonical] = map
    }

    public func recoverAfterError() throws {
        guard isOpen else {
            throw AdapterError(code: "NO_PRESENTATION", message: "No presentation is open")
        }
    }

    public func deckDigest() throws -> String {
        struct DigestSlide: Codable {
            let key: String
            let title: String?
            let notes: String
            let hidden: Bool
            let elements: [DigestElement]
        }

        struct DigestElement: Codable {
            let name: String
            let type: String
            let frame: [Double]?
            let text: String?
            let bulletCount: Int?
            let imagePath: String?
            let opacity: Double
            let zIndex: Int
        }

        let digestSlides = slides.map { slide in
            DigestSlide(
                key: slide.key,
                title: slide.title,
                notes: slide.notes,
                hidden: slide.hidden,
                elements: slide.elements.values
                    .map { element in
                        DigestElement(
                            name: element.name,
                            type: element.type.rawValue,
                            frame: element.frame?.array,
                            text: element.text,
                            bulletCount: element.bulletCount,
                            imagePath: element.imagePath,
                            opacity: element.opacity,
                            zIndex: element.zIndex
                        )
                    }
                    .sorted { $0.name < $1.name }
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(digestSlides)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func slideIndex(slideKey: String) -> Int? {
        let canonical = canonicalSlideKey(for: slideKey)
        if let index = slides.firstIndex(where: { $0.key == canonical }) {
            return index
        }
        if let hinted = hintedSlideIndex(from: slideKey), hinted <= slides.count {
            return hinted - 1
        }
        return nil
    }

    private func requireSlide(_ slideKey: String) throws -> Int {
        guard let index = slideIndex(slideKey: slideKey) else {
            throw AdapterError(code: "MISSING_SLIDE", message: "Slide \(slideKey) not found")
        }
        return index
    }

    private func resolveElementName(slideKey: String, elementName: String) -> String {
        let canonical = canonicalSlideKey(for: slideKey)
        return aliases[canonical]?[elementName] ?? elementName
    }

    private func canonicalSlideKey(for slideKey: String) -> String {
        slideAliases[slideKey] ?? slideKey
    }

    private func nextZ(in slide: MockSlide) -> Int {
        (slide.elements.values.map(\.zIndex).max() ?? 0) + 1
    }

    private func lineCount(in text: String) -> Int {
        if text.isEmpty { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func requireTargetKeys(slideKey: String, requestedNames: [String]) throws -> [String] {
        guard !requestedNames.isEmpty else {
            throw AdapterError(code: "MISSING_ELEMENT", message: "No target elements provided for \(slideKey)")
        }
        let resolved = requestedNames.map { resolveElementName(slideKey: slideKey, elementName: $0) }
        return Array(Set(resolved))
    }

    private func hintedSlideIndex(from slideKey: String) -> Int? {
        let lowered = slideKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?:slide[_\-]?|s)(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: lowered, options: [], range: NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)),
              let range = Range(match.range(at: 1), in: lowered),
              let index = Int(lowered[range]),
              index > 0 else {
            return nil
        }
        return index
    }
}
