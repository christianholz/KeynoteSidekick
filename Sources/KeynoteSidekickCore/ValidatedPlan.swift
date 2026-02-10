import Foundation

public struct ValidatedPlan {
    public let meta: PlanMeta
    public let operations: [PlanOperation]
}

public struct OperationMeta {
    public let opId: String
    public let requiresConfirm: Bool
    public let confirmationText: String?
    public let maxRetries: Int
}

public struct VerifySpec: Sendable {
    public var presentationOpen: Bool?
    public var slideExists: Bool?
    public var elementExists: Bool?
    public var textPrefix: String?
    public var textContains: String?
    public var frameApprox: Frame?
    public var bulletCount: Int?
    public var notesContains: String?

    public static let none = VerifySpec()
}

public enum OperationPayload {
    case openPresentation(path: String)
    case attachToFrontPresentation
    case savePresentation
    case transaction(operations: [PlanOperation], rollbackOnFailure: Bool)
    case assertState(slideKey: String?, elementName: String?)
    case resolveTarget(slideKey: String, elementName: String, selector: TargetSelector)
    case ensureSlide(slideKey: String, layout: String?, index: Int?, title: String?)
    case duplicateSlide(fromSlideKey: String, slideKey: String, index: Int?, title: String?)
    case deleteSlide(slideKey: String)
    case hideSlide(slideKey: String, hidden: Bool)
    case moveSlide(slideKey: String, index: Int)
    case ensureTextBox(slideKey: String, elementName: String, text: String, frame: Frame?, role: String?)
    case ensureBullets(slideKey: String, elementName: String, items: [String], frame: Frame?)
    case ensureImage(slideKey: String, elementName: String, path: String, frame: Frame?)
    case ensureShape(slideKey: String, elementName: String, shapeType: String?, text: String?, frame: Frame?)
    case deleteElement(slideKey: String, elementName: String)
    case setFrame(slideKey: String, elementName: String, frame: Frame)
    case setOpacity(slideKey: String, elementName: String, opacity: Double)
    case setZOrder(slideKey: String, elementName: String, mode: ZOrderMode)
    case setPresenterNotes(slideKey: String, text: String)
    case setTextStyle(slideKey: String, elementName: String, style: [String: JSONValue])
    case setParagraphStyle(slideKey: String, elementName: String, style: [String: JSONValue])
    case setFillStyle(slideKey: String, elementName: String, style: [String: JSONValue])
    case setStrokeStyle(slideKey: String, elementName: String, style: [String: JSONValue])
    case alignElements(slideKey: String, elementNames: [String], alignment: String, useSelection: Bool)
    case distributeElements(slideKey: String, elementNames: [String], axis: String, spacing: Double?, useSelection: Bool)

    var slideKey: String? {
        switch self {
        case .resolveTarget(let slideKey, _, _): return slideKey
        case .assertState(let slideKey, _): return slideKey
        case .ensureSlide(let slideKey, _, _, _): return slideKey
        case .duplicateSlide(_, let slideKey, _, _): return slideKey
        case .deleteSlide(let slideKey): return slideKey
        case .hideSlide(let slideKey, _): return slideKey
        case .moveSlide(let slideKey, _): return slideKey
        case .ensureTextBox(let slideKey, _, _, _, _): return slideKey
        case .ensureBullets(let slideKey, _, _, _): return slideKey
        case .ensureImage(let slideKey, _, _, _): return slideKey
        case .ensureShape(let slideKey, _, _, _, _): return slideKey
        case .deleteElement(let slideKey, _): return slideKey
        case .setFrame(let slideKey, _, _): return slideKey
        case .setOpacity(let slideKey, _, _): return slideKey
        case .setZOrder(let slideKey, _, _): return slideKey
        case .setPresenterNotes(let slideKey, _): return slideKey
        case .setTextStyle(let slideKey, _, _): return slideKey
        case .setParagraphStyle(let slideKey, _, _): return slideKey
        case .setFillStyle(let slideKey, _, _): return slideKey
        case .setStrokeStyle(let slideKey, _, _): return slideKey
        case .alignElements(let slideKey, _, _, _): return slideKey
        case .distributeElements(let slideKey, _, _, _, _): return slideKey
        default: return nil
        }
    }

    var elementName: String? {
        switch self {
        case .resolveTarget(_, let elementName, _): return elementName
        case .assertState(_, let elementName): return elementName
        case .ensureTextBox(_, let elementName, _, _, _): return elementName
        case .ensureBullets(_, let elementName, _, _): return elementName
        case .ensureImage(_, let elementName, _, _): return elementName
        case .ensureShape(_, let elementName, _, _, _): return elementName
        case .deleteElement(_, let elementName): return elementName
        case .setFrame(_, let elementName, _): return elementName
        case .setOpacity(_, let elementName, _): return elementName
        case .setZOrder(_, let elementName, _): return elementName
        case .setTextStyle(_, let elementName, _): return elementName
        case .setParagraphStyle(_, let elementName, _): return elementName
        case .setFillStyle(_, let elementName, _): return elementName
        case .setStrokeStyle(_, let elementName, _): return elementName
        default: return nil
        }
    }

    var elementTypeHint: SlideElementType? {
        switch self {
        case .resolveTarget(_, _, let selector):
            return selector.type
        case .ensureTextBox: return .text
        case .ensureBullets: return .text
        case .ensureImage: return .image
        case .ensureShape: return .shape
        case .setTextStyle, .setParagraphStyle: return .text
        case .setFillStyle, .setStrokeStyle: return .shape
        default: return nil
        }
    }

    var textHint: String? {
        switch self {
        case .resolveTarget(_, _, let selector):
            return selector.textPrefix ?? selector.textContains
        case .ensureTextBox(_, _, let text, _, _): return text
        case .ensureBullets(_, _, let items, _): return items.first
        case .ensureShape(_, _, _, let text, _): return text
        default: return nil
        }
    }

    var frameHint: Frame? {
        switch self {
        case .resolveTarget(_, _, let selector): return selector.boundsNear
        case .ensureTextBox(_, _, _, let frame, _): return frame
        case .ensureBullets(_, _, _, let frame): return frame
        case .ensureImage(_, _, _, let frame): return frame
        case .ensureShape(_, _, _, _, let frame): return frame
        case .setFrame(_, _, let frame): return frame
        default: return nil
        }
    }
}

public struct PlanOperation {
    public let name: OperationName
    public let payload: OperationPayload
    public let verify: VerifySpec
    public let meta: OperationMeta

    public var slideKey: String? { payload.slideKey }
    public var elementName: String? { payload.elementName }
}

public enum ZOrderMode: String {
    case bringToFront
    case sendToBack
    case bringForward
    case sendBackward
}

public func validate(plan: IRPlan) throws -> ValidatedPlan {
    guard plan.meta.irVersion == irVersion else {
        throw ValidationError(message: "Unsupported irVersion \(plan.meta.irVersion), expected \(irVersion)")
    }

    var operations: [PlanOperation] = []

    for (index, raw) in plan.operations.enumerated() {
        guard let name = OperationName(rawValue: raw.op) else {
            throw ValidationError(message: "Unsupported operation \(raw.op)")
        }

        let opId = raw.meta["opId"]?.stringValue ?? String(format: "op-%03d", index + 1)
        let maxRetries = raw.meta["maxRetries"]?.intValue ?? 1
        if maxRetries < 0 || maxRetries > 3 {
            throw ValidationError(message: "\(name.rawValue).meta.maxRetries must be between 0 and 3")
        }

        let inferredRequiresConfirm = false
        let requiresConfirm = raw.meta["requiresConfirm"]?.boolValue ?? inferredRequiresConfirm
        let confirmationText = raw.meta["confirmationText"]?.stringValue

        let meta = OperationMeta(
            opId: opId,
            requiresConfirm: requiresConfirm,
            confirmationText: confirmationText,
            maxRetries: maxRetries
        )

        let verify = try decodeVerify(raw.verify, context: name.rawValue)
        let payload = try decodePayload(name: name, target: raw.target, args: raw.args, opId: opId, depth: 0)

        operations.append(PlanOperation(name: name, payload: payload, verify: verify, meta: meta))
    }

    return ValidatedPlan(meta: plan.meta, operations: operations)
}

private func decodeVerify(_ value: [String: JSONValue], context: String) throws -> VerifySpec {
    var verify = VerifySpec.none

    verify.presentationOpen = value["presentationOpen"]?.boolValue
    verify.slideExists = value["slideExists"]?.boolValue
    verify.elementExists = value["elementExists"]?.boolValue
    verify.textPrefix = value["textPrefix"]?.stringValue
    verify.textContains = value["textContains"]?.stringValue
    verify.notesContains = value["notesContains"]?.stringValue

    if let bulletCount = value["bulletCount"]?.intValue {
        if bulletCount < 0 {
            throw ValidationError(message: "\(context).verify.bulletCount must be >= 0")
        }
        verify.bulletCount = bulletCount
    }

    verify.frameApprox = try value.optionalFrame("frameApprox")

    return verify
}

private func decodePayload(
    name: OperationName,
    target: [String: JSONValue],
    args: [String: JSONValue],
    opId: String,
    depth: Int
) throws -> OperationPayload {
    switch name {
    case .openPresentation:
        let path = try target.requiredString("presentationPath", context: "openPresentation.target")
        return .openPresentation(path: path)
    case .attachToFrontPresentation:
        return .attachToFrontPresentation
    case .savePresentation:
        return .savePresentation
    case .transaction:
        guard depth < 3 else {
            throw ValidationError(message: "transaction nesting depth exceeded")
        }
        let operations = try decodeNestedOperations(raw: args["operations"], parentOpId: opId, depth: depth + 1)
        let rollbackOnFailure = args.optionalBool("rollbackOnFailure") ?? true
        return .transaction(operations: operations, rollbackOnFailure: rollbackOnFailure)
    case .assertState:
        return .assertState(
            slideKey: target.optionalString("slideKey"),
            elementName: target.optionalString("elementName")
        )
    case .resolveTarget:
        let slideKey = try target.requiredString("slideKey", context: "resolveTarget.target")
        let elementName = try target.requiredString("elementName", context: "resolveTarget.target")
        let selector = try decodeSelector(args: args, target: target, context: "resolveTarget")
        return .resolveTarget(slideKey: slideKey, elementName: elementName, selector: selector)
    case .ensureSlide:
        let slideKey = try target.requiredString("slideKey", context: "ensureSlide.target")
        return .ensureSlide(
            slideKey: slideKey,
            layout: args.optionalString("layout"),
            index: args.optionalInt("index"),
            title: args.optionalString("title")
        )
    case .duplicateSlide:
        let fromSlideKey = try target.requiredString("fromSlideKey", context: "duplicateSlide.target")
        let slideKey = try target.requiredString("slideKey", context: "duplicateSlide.target")
        return .duplicateSlide(
            fromSlideKey: fromSlideKey,
            slideKey: slideKey,
            index: args.optionalInt("index"),
            title: args.optionalString("title")
        )
    case .deleteSlide:
        let slideKey = try target.requiredString("slideKey", context: "deleteSlide.target")
        return .deleteSlide(slideKey: slideKey)
    case .hideSlide:
        let slideKey = try target.requiredString("slideKey", context: "hideSlide.target")
        let hidden = args.optionalBool("hidden") ?? true
        return .hideSlide(slideKey: slideKey, hidden: hidden)
    case .moveSlide:
        let slideKey = try target.requiredString("slideKey", context: "moveSlide.target")
        guard let index = args.optionalInt("index"), index > 0 else {
            throw ValidationError(message: "moveSlide.args.index must be a positive integer")
        }
        return .moveSlide(slideKey: slideKey, index: index)
    case .ensureTextBox:
        let slideKey = try target.requiredString("slideKey", context: "ensureTextBox.target")
        let elementName = try target.requiredString("elementName", context: "ensureTextBox.target")
        let text = args.optionalString("text") ?? ""
        let frame = try args.optionalFrame("frame")
        var role: String?
        if let style = args["style"], case .object(let object) = style {
            role = object["role"]?.stringValue
        }
        return .ensureTextBox(slideKey: slideKey, elementName: elementName, text: text, frame: frame, role: role)
    case .ensureBullets:
        let slideKey = try target.requiredString("slideKey", context: "ensureBullets.target")
        let elementName = try target.requiredString("elementName", context: "ensureBullets.target")
        let items = try args.requiredFlexibleStringArray("items", context: "ensureBullets.args")
        let frame = try args.optionalFrame("frame")
        return .ensureBullets(slideKey: slideKey, elementName: elementName, items: items, frame: frame)
    case .ensureImage:
        let slideKey = try target.requiredString("slideKey", context: "ensureImage.target")
        let elementName = try target.requiredString("elementName", context: "ensureImage.target")
        let path = try args.requiredString("path", context: "ensureImage.args")
        let frame = try args.optionalFrame("frame")
        return .ensureImage(slideKey: slideKey, elementName: elementName, path: path, frame: frame)
    case .ensureShape:
        let slideKey = try target.requiredString("slideKey", context: "ensureShape.target")
        let elementName = try target.requiredString("elementName", context: "ensureShape.target")
        let shapeType = args.optionalString("shapeType") ?? args.optionalString("shape")
        let text = args.optionalString("text")
        let frame = try args.optionalFrame("frame")
        return .ensureShape(slideKey: slideKey, elementName: elementName, shapeType: shapeType, text: text, frame: frame)
    case .deleteElement:
        let slideKey = try target.requiredString("slideKey", context: "deleteElement.target")
        let elementName = try target.requiredString("elementName", context: "deleteElement.target")
        return .deleteElement(slideKey: slideKey, elementName: elementName)
    case .setFrame:
        let slideKey = try target.requiredString("slideKey", context: "setFrame.target")
        let elementName = try target.requiredString("elementName", context: "setFrame.target")
        let frame = try args.requiredFrame("frame", context: "setFrame.args")
        return .setFrame(slideKey: slideKey, elementName: elementName, frame: frame)
    case .setOpacity:
        let slideKey = try target.requiredString("slideKey", context: "setOpacity.target")
        let elementName = try target.requiredString("elementName", context: "setOpacity.target")
        let opacity = try args.requiredDouble("opacity", context: "setOpacity.args")
        guard opacity >= 0, opacity <= 100 else {
            throw ValidationError(message: "setOpacity.args.opacity must be between 0 and 100")
        }
        return .setOpacity(slideKey: slideKey, elementName: elementName, opacity: opacity)
    case .setZOrder:
        let slideKey = try target.requiredString("slideKey", context: "setZOrder.target")
        let elementName = try target.requiredString("elementName", context: "setZOrder.target")
        guard let modeRaw = args.optionalString("mode"), let mode = ZOrderMode(rawValue: modeRaw) else {
            throw ValidationError(message: "setZOrder.args.mode must be one of bringToFront, sendToBack, bringForward, sendBackward")
        }
        return .setZOrder(slideKey: slideKey, elementName: elementName, mode: mode)
    case .setPresenterNotes:
        let slideKey = try target.requiredString("slideKey", context: "setPresenterNotes.target")
        let text = args.optionalString("text") ?? ""
        return .setPresenterNotes(slideKey: slideKey, text: text)
    case .setTextStyle:
        let slideKey = try target.requiredString("slideKey", context: "setTextStyle.target")
        let elementName = try target.requiredString("elementName", context: "setTextStyle.target")
        let style = extractStyle(args: args, context: "setTextStyle.args")
        return .setTextStyle(slideKey: slideKey, elementName: elementName, style: style)
    case .setParagraphStyle:
        let slideKey = try target.requiredString("slideKey", context: "setParagraphStyle.target")
        let elementName = try target.requiredString("elementName", context: "setParagraphStyle.target")
        let style = extractStyle(args: args, context: "setParagraphStyle.args")
        return .setParagraphStyle(slideKey: slideKey, elementName: elementName, style: style)
    case .setFillStyle:
        let slideKey = try target.requiredString("slideKey", context: "setFillStyle.target")
        let elementName = try target.requiredString("elementName", context: "setFillStyle.target")
        let style = extractStyle(args: args, context: "setFillStyle.args")
        return .setFillStyle(slideKey: slideKey, elementName: elementName, style: style)
    case .setStrokeStyle:
        let slideKey = try target.requiredString("slideKey", context: "setStrokeStyle.target")
        let elementName = try target.requiredString("elementName", context: "setStrokeStyle.target")
        let style = extractStyle(args: args, context: "setStrokeStyle.args")
        return .setStrokeStyle(slideKey: slideKey, elementName: elementName, style: style)
    case .alignElements:
        let slideKey = try target.requiredString("slideKey", context: "alignElements.target")
        let elementNames = extractElementNames(target: target, args: args, context: "alignElements")
        let alignment = try extractStringArg(args: args, key: "alignment", context: "alignElements.args")
        let useSelection = args.optionalBool("useSelection") ?? target.optionalBool("useSelection") ?? false
        if !useSelection && elementNames.isEmpty {
            throw ValidationError(message: "alignElements requires elementNames or useSelection=true")
        }
        return .alignElements(slideKey: slideKey, elementNames: elementNames, alignment: alignment, useSelection: useSelection)
    case .distributeElements:
        let slideKey = try target.requiredString("slideKey", context: "distributeElements.target")
        let elementNames = extractElementNames(target: target, args: args, context: "distributeElements")
        let axis = try extractStringArg(args: args, key: "axis", context: "distributeElements.args")
        let spacing = args.optionalDouble("spacing")
        let useSelection = args.optionalBool("useSelection") ?? target.optionalBool("useSelection") ?? false
        if !useSelection && elementNames.isEmpty {
            throw ValidationError(message: "distributeElements requires elementNames or useSelection=true")
        }
        return .distributeElements(slideKey: slideKey, elementNames: elementNames, axis: axis, spacing: spacing, useSelection: useSelection)
    }
}

private func decodeNestedOperations(
    raw: JSONValue?,
    parentOpId: String,
    depth: Int
) throws -> [PlanOperation] {
    guard let raw, case .array(let values) = raw else {
        throw ValidationError(message: "transaction.args.operations must be an array")
    }

    var operations: [PlanOperation] = []
    operations.reserveCapacity(values.count)

    for (index, value) in values.enumerated() {
        guard case .object(let object) = value else {
            throw ValidationError(message: "transaction.args.operations[\(index)] must be an object")
        }

        guard let opNameRaw = object["op"]?.stringValue,
              let opName = OperationName(rawValue: opNameRaw) else {
            throw ValidationError(message: "transaction.args.operations[\(index)].op is invalid")
        }

        let target = object["target"]?.objectValue ?? [:]
        let args = object["args"]?.objectValue ?? [:]
        let verifyRaw = object["verify"]?.objectValue ?? [:]
        let metaRaw = object["meta"]?.objectValue ?? [:]

        let childOpId = metaRaw["opId"]?.stringValue ?? "\(parentOpId).\(index + 1)"
        let maxRetries = metaRaw["maxRetries"]?.intValue ?? 1
        if maxRetries < 0 || maxRetries > 3 {
            throw ValidationError(message: "\(opName.rawValue).meta.maxRetries must be between 0 and 3")
        }

        let meta = OperationMeta(
            opId: childOpId,
            requiresConfirm: metaRaw["requiresConfirm"]?.boolValue ?? false,
            confirmationText: metaRaw["confirmationText"]?.stringValue,
            maxRetries: maxRetries
        )

        let verify = try decodeVerify(verifyRaw, context: "\(opName.rawValue)")
        let payload = try decodePayload(
            name: opName,
            target: target,
            args: args,
            opId: childOpId,
            depth: depth
        )

        operations.append(PlanOperation(name: opName, payload: payload, verify: verify, meta: meta))
    }

    return operations
}

private func decodeSelector(
    args: [String: JSONValue],
    target: [String: JSONValue],
    context: String
) throws -> TargetSelector {
    let selectorObject: [String: JSONValue]
    if let value = args["selector"], let obj = value.objectValue {
        selectorObject = obj
    } else {
        selectorObject = args.merging(target) { left, _ in left }
    }

    let role = selectorObject.optionalString("role")
    let typeRaw = selectorObject.optionalString("type") ?? selectorObject.optionalString("elementType")
    let type = try parseElementType(raw: typeRaw, context: "\(context).selector.type")
    let textEquals = selectorObject.optionalString("textEquals")
        ?? selectorObject.optionalString("slideTitleEquals")
    let textContains = selectorObject.optionalString("textContains")
        ?? selectorObject.optionalString("matchText")
        ?? textEquals
    let textPrefix = selectorObject.optionalString("textPrefix") ?? textEquals
    let index = selectorObject.optionalInt("index")
    if let index, index < 1 {
        throw ValidationError(message: "\(context).selector.index must be >= 1")
    }
    let isSelected = selectorObject.optionalBool("isSelected")
    let boundsNear = try selectorObject.optionalFrame("boundsNear")

    return TargetSelector(
        role: role,
        type: type,
        textContains: textContains,
        textPrefix: textPrefix,
        index: index,
        isSelected: isSelected,
        boundsNear: boundsNear
    )
}

private func parseElementType(raw: String?, context: String) throws -> SlideElementType? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !raw.isEmpty else {
        return nil
    }

    switch raw {
    case "text", "textbox", "textitem", "body", "title":
        return .text
    case "image", "photo", "picture":
        return .image
    case "shape":
        return .shape
    case "unknown":
        return .unknown
    default:
        throw ValidationError(message: "\(context) must be text, image, shape, or unknown")
    }
}

private func extractStyle(args: [String: JSONValue], context: String) -> [String: JSONValue] {
    if let style = args["style"]?.objectValue {
        return style
    }
    var style = args
    style.removeValue(forKey: "style")
    return style
}

private func extractElementNames(
    target: [String: JSONValue],
    args: [String: JSONValue],
    context: String
) -> [String] {
    if let names = target.optionalFlexibleStringArray("elementNames") ?? args.optionalFlexibleStringArray("elementNames") {
        return names
    }
    if let single = target.optionalString("elementName")?.trimmingCharacters(in: .whitespacesAndNewlines), !single.isEmpty {
        return [single]
    }
    return []
}

private func extractStringArg(args: [String: JSONValue], key: String, context: String) throws -> String {
    guard let value = args.optionalString(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        throw ValidationError(message: "\(context).\(key) must be a non-empty string")
    }
    return value
}
