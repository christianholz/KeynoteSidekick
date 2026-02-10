import Foundation

public let irVersion = "0.1.0"

public struct IRPlan: Decodable {
    public let meta: PlanMeta
    public let operations: [RawOperation]
}

public struct PlanMeta: Decodable {
    public let irVersion: String
    public let safeMode: Bool
    public let confirmedOpIds: Set<String>
    public let presentationPath: String?

    enum CodingKeys: String, CodingKey {
        case irVersion
        case safeMode
        case confirmedOpIds
        case presentationPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.irVersion = try container.decode(String.self, forKey: .irVersion)
        self.safeMode = try container.decodeIfPresent(Bool.self, forKey: .safeMode) ?? true
        self.confirmedOpIds = Set(try container.decodeIfPresent([String].self, forKey: .confirmedOpIds) ?? [])
        self.presentationPath = try container.decodeIfPresent(String.self, forKey: .presentationPath)
    }
}

public struct RawOperation: Decodable {
    public let op: String
    public let target: [String: JSONValue]
    public let args: [String: JSONValue]
    public let verify: [String: JSONValue]
    public let meta: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case op
        case target
        case args
        case verify
        case meta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.op = try container.decode(String.self, forKey: .op)
        self.target = try container.decodeIfPresent([String: JSONValue].self, forKey: .target) ?? [:]
        self.args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        self.verify = try container.decodeIfPresent([String: JSONValue].self, forKey: .verify) ?? [:]
        self.meta = try container.decodeIfPresent([String: JSONValue].self, forKey: .meta) ?? [:]
    }
}

public enum OperationName: String, CaseIterable {
    case openPresentation
    case attachToFrontPresentation
    case savePresentation
    case transaction
    case assertState
    case resolveTarget
    case ensureSlide
    case duplicateSlide
    case deleteSlide
    case hideSlide
    case moveSlide
    case ensureTextBox
    case ensureBullets
    case ensureImage
    case ensureShape
    case deleteElement
    case setFrame
    case setOpacity
    case setZOrder
    case setPresenterNotes
    case setTextStyle
    case setParagraphStyle
    case setFillStyle
    case setStrokeStyle
    case alignElements
    case distributeElements
}

public enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var stringArrayValue: [String]? {
        guard case .array(let values) = self else { return nil }
        var output: [String] = []
        for value in values {
            guard case .string(let text) = value else { return nil }
            output.append(text)
        }
        return output
    }

    public var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var frameValue: Frame? {
        guard case .array(let values) = self, values.count == 4 else { return nil }
        var nums: [Double] = []
        for value in values {
            guard case .number(let n) = value else { return nil }
            nums.append(n)
        }
        return Frame(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String, context: String) throws -> String {
        guard let raw = self[key], let value = raw.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(message: "\(context).\(key) must be a non-empty string")
        }
        return value
    }

    func optionalString(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func optionalInt(_ key: String) -> Int? {
        self[key]?.intValue
    }

    func optionalBool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func optionalDouble(_ key: String) -> Double? {
        self[key]?.doubleValue
    }

    func optionalFrame(_ key: String) throws -> Frame? {
        guard let raw = self[key] else { return nil }
        guard let frame = raw.frameValue else {
            throw ValidationError(message: "\(key) must be [x,y,w,h]")
        }
        return frame
    }

    func requiredFrame(_ key: String, context: String) throws -> Frame {
        guard let raw = self[key], let frame = raw.frameValue else {
            throw ValidationError(message: "\(context).\(key) must be [x,y,w,h]")
        }
        return frame
    }

    func requiredStringArray(_ key: String, context: String) throws -> [String] {
        guard let raw = self[key], let value = raw.stringArrayValue else {
            throw ValidationError(message: "\(context).\(key) must be a string array")
        }
        return value
    }

    func requiredFlexibleStringArray(_ key: String, context: String) throws -> [String] {
        guard let raw = self[key] else {
            throw ValidationError(message: "\(context).\(key) must be a string array")
        }

        switch raw {
        case .array(let values):
            var output: [String] = []
            output.reserveCapacity(values.count)

            for value in values {
                switch value {
                case .string(let text):
                    let normalized = normalizeBulletText(text)
                    if !normalized.isEmpty {
                        output.append(normalized)
                    }
                case .number(let number):
                    let normalized = normalizeBulletText(String(number))
                    if !normalized.isEmpty {
                        output.append(normalized)
                    }
                case .object(let object):
                    if let text = object["text"]?.stringValue ?? object["value"]?.stringValue {
                        let normalized = normalizeBulletText(text)
                        if !normalized.isEmpty {
                            output.append(normalized)
                        }
                    } else {
                        throw ValidationError(message: "\(context).\(key) must contain strings or objects with text/value")
                    }
                default:
                    throw ValidationError(message: "\(context).\(key) must contain strings or objects with text/value")
                }
            }

            if output.isEmpty {
                throw ValidationError(message: "\(context).\(key) must contain at least one non-empty item")
            }
            return output

        case .string(let text):
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { normalizeBulletText(String($0)) }
                .filter { !$0.isEmpty }
            if lines.isEmpty {
                throw ValidationError(message: "\(context).\(key) must contain at least one non-empty item")
            }
            return lines

        default:
            throw ValidationError(message: "\(context).\(key) must be a string array")
        }
    }

    func optionalFlexibleStringArray(_ key: String) -> [String]? {
        guard let raw = self[key] else { return nil }
        switch raw {
        case .array(let values):
            let output = values.compactMap { value -> String? in
                switch value {
                case .string(let text):
                    let normalized = normalizeBulletText(text)
                    return normalized.isEmpty ? nil : normalized
                case .number(let number):
                    let normalized = normalizeBulletText(String(number))
                    return normalized.isEmpty ? nil : normalized
                case .object(let object):
                    if let text = object["text"]?.stringValue ?? object["value"]?.stringValue {
                        let normalized = normalizeBulletText(text)
                        return normalized.isEmpty ? nil : normalized
                    }
                    return nil
                default:
                    return nil
                }
            }
            return output.isEmpty ? nil : output
        case .string(let text):
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { normalizeBulletText(String($0)) }
                .filter { !$0.isEmpty }
            return lines.isEmpty ? nil : lines
        default:
            return nil
        }
    }

    func requiredDouble(_ key: String, context: String) throws -> Double {
        guard let raw = self[key], let value = raw.doubleValue else {
            throw ValidationError(message: "\(context).\(key) must be a number")
        }
        return value
    }
}

private func normalizeBulletText(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return trimmed.replacingOccurrences(
        of: #"^([•\-\*]|\d+[\.\)])\s+"#,
        with: "",
        options: .regularExpression
    )
}
