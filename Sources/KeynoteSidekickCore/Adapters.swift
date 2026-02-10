import Foundation

public enum SlideElementType: String, Codable, Sendable {
    case text
    case image
    case shape
    case unknown
}

public struct SlideElementSnapshot: Codable {
    public let name: String
    public let type: SlideElementType
    public let frame: Frame?
    public let text: String?
    public let bulletCount: Int?

    public init(name: String, type: SlideElementType, frame: Frame?, text: String?, bulletCount: Int?) {
        self.name = name
        self.type = type
        self.frame = frame
        self.text = text
        self.bulletCount = bulletCount
    }
}

public struct SlideElementDescriptor: Codable {
    public let name: String?
    public let type: SlideElementType
    public let frame: Frame?
    public let textSnippet: String?

    public init(name: String?, type: SlideElementType, frame: Frame?, textSnippet: String?) {
        self.name = name
        self.type = type
        self.frame = frame
        self.textSnippet = textSnippet
    }
}

public struct ResyncTarget {
    public let elementName: String
    public let type: SlideElementType?
    public let frame: Frame?
    public let text: String?
}

public enum ResyncMode: String {
    case exact
    case fallback
}

public struct ResyncMatch {
    public let target: ResyncTarget
    public let element: SlideElementDescriptor
    public let mode: ResyncMode
}

public struct ResyncResult {
    public let ok: Bool
    public let ambiguous: Bool
    public let count: Int
    public let matches: [ResyncMatch]
}

public struct TargetSelector: Codable, Sendable {
    public let role: String?
    public let type: SlideElementType?
    public let textContains: String?
    public let textPrefix: String?
    public let index: Int?
    public let isSelected: Bool?
    public let boundsNear: Frame?

    public init(
        role: String?,
        type: SlideElementType?,
        textContains: String?,
        textPrefix: String?,
        index: Int?,
        isSelected: Bool?,
        boundsNear: Frame?
    ) {
        self.role = role
        self.type = type
        self.textContains = textContains
        self.textPrefix = textPrefix
        self.index = index
        self.isSelected = isSelected
        self.boundsNear = boundsNear
    }
}

public protocol KeynoteAutomationAdapter {
    var adapterName: String { get }
    var defaultDriver: DriverUsed { get }

    func openPresentation(path: String) throws
    func attachToFrontPresentation() throws
    func savePresentation() throws

    func ensureSlide(slideKey: String, layout: String?, index: Int?, title: String?) throws
    func duplicateSlide(fromSlideKey: String, slideKey: String, index: Int?, title: String?) throws
    func deleteSlide(slideKey: String) throws
    func hideSlide(slideKey: String, hidden: Bool) throws
    func moveSlide(slideKey: String, index: Int) throws

    func ensureTextBox(slideKey: String, elementName: String, text: String, frame: Frame?, role: String?) throws
    func ensureBullets(slideKey: String, elementName: String, items: [String], frame: Frame?) throws
    func ensureImage(slideKey: String, elementName: String, path: String, frame: Frame?) throws
    func ensureShape(slideKey: String, elementName: String, shapeType: String?, text: String?, frame: Frame?) throws
    func deleteElement(slideKey: String, elementName: String) throws

    func setFrame(slideKey: String, elementName: String, frame: Frame) throws
    func setOpacity(slideKey: String, elementName: String, opacity: Double) throws
    func setZOrder(slideKey: String, elementName: String, mode: ZOrderMode) throws
    func setPresenterNotes(slideKey: String, text: String) throws
    func setTextStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws
    func setParagraphStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws
    func setFillStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws
    func setStrokeStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws
    func alignElements(slideKey: String, elementNames: [String], alignment: String, useSelection: Bool) throws
    func distributeElements(slideKey: String, elementNames: [String], axis: String, spacing: Double?, useSelection: Bool) throws

    func isPresentationOpen() throws -> Bool
    func slideExists(slideKey: String) throws -> Bool
    func element(slideKey: String, elementName: String) throws -> SlideElementSnapshot?
    func presenterNotes(slideKey: String) throws -> String?
    func knownSlideBindings() throws -> [String: Int]
    func refreshSlideBindings() throws -> [String: Int]

    func enumerateSlideElements(slideKey: String) throws -> [SlideElementDescriptor]
    func resolveElement(slideKey: String, selector: TargetSelector) throws -> SlideElementDescriptor?
    func applyResyncBindings(slideKey: String, matches: [ResyncMatch]) throws

    func recoverAfterError() throws
    func rollback(steps: Int) throws
    func deckDigest() throws -> String
}

public protocol AXFallbackAdapter {
    func setPresenterNotes(slideKey: String, text: String) throws
    func setZOrder(slideKey: String, elementName: String, mode: ZOrderMode) throws
}

public extension KeynoteAutomationAdapter {
    func resolveElement(slideKey: String, selector: TargetSelector) throws -> SlideElementDescriptor? {
        let all = try enumerateSlideElements(slideKey: slideKey)
        var candidates = all

        if let type = selector.type {
            candidates = candidates.filter { $0.type == type }
        }

        if let roleRaw = selector.role?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !roleRaw.isEmpty {
            candidates = candidates.filter { descriptor in
                let name = (descriptor.name ?? "").lowercased()
                switch roleRaw {
                case "title", "headline":
                    return name.contains("title") || name.contains("__ksk_role_title__")
                case "body", "content", "bullets", "bullet":
                    return name.contains("body") || name.contains("__ksk_role_body__")
                default:
                    return true
                }
            }
        }

        if let contains = selector.textContains?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !contains.isEmpty {
            candidates = candidates.filter { ($0.textSnippet ?? "").lowercased().contains(contains) }
        }

        if let prefix = selector.textPrefix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !prefix.isEmpty {
            candidates = candidates.filter { ($0.textSnippet ?? "").lowercased().hasPrefix(prefix) }
        }

        if candidates.isEmpty {
            return nil
        }

        let ranked = candidates.sorted { lhs, rhs in
            selectorScore(lhs, selector: selector) < selectorScore(rhs, selector: selector)
        }

        if let index = selector.index, index > 0 {
            let position = index - 1
            if position < ranked.count {
                return ranked[position]
            }
        }

        return ranked.first
    }

    func rollback(steps: Int) throws {
        _ = steps
        throw AdapterError(code: "ROLLBACK_UNSUPPORTED", message: "Adapter does not implement transactional rollback")
    }

    func refreshSlideBindings() throws -> [String: Int] {
        try knownSlideBindings()
    }

    func setTextStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        _ = slideKey
        _ = elementName
        _ = style
        throw AdapterError(code: "UNSUPPORTED_STYLE", message: "setTextStyle is not supported by this adapter")
    }

    func setParagraphStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        _ = slideKey
        _ = elementName
        _ = style
        throw AdapterError(code: "UNSUPPORTED_STYLE", message: "setParagraphStyle is not supported by this adapter")
    }

    func setFillStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        _ = slideKey
        _ = elementName
        _ = style
        throw AdapterError(code: "UNSUPPORTED_STYLE", message: "setFillStyle is not supported by this adapter")
    }

    func setStrokeStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        _ = slideKey
        _ = elementName
        _ = style
        throw AdapterError(code: "UNSUPPORTED_STYLE", message: "setStrokeStyle is not supported by this adapter")
    }

    func alignElements(slideKey: String, elementNames: [String], alignment: String, useSelection: Bool) throws {
        _ = slideKey
        _ = elementNames
        _ = alignment
        _ = useSelection
        throw AdapterError(code: "UNSUPPORTED_LAYOUT", message: "alignElements is not supported by this adapter")
    }

    func distributeElements(slideKey: String, elementNames: [String], axis: String, spacing: Double?, useSelection: Bool) throws {
        _ = slideKey
        _ = elementNames
        _ = axis
        _ = spacing
        _ = useSelection
        throw AdapterError(code: "UNSUPPORTED_LAYOUT", message: "distributeElements is not supported by this adapter")
    }

    private func selectorScore(_ descriptor: SlideElementDescriptor, selector: TargetSelector) -> Double {
        guard let near = selector.boundsNear else { return 0 }
        guard let frame = descriptor.frame else { return 10_000 }
        let dx = frame.x - near.x
        let dy = frame.y - near.y
        let dw = frame.width - near.width
        let dh = frame.height - near.height
        return (dx * dx + dy * dy + dw * dw + dh * dh).squareRoot()
    }
}
