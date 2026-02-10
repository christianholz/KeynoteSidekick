import Foundation

public struct ValidationError: Error, LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct ConfirmationRequiredError: Error, LocalizedError {
    public let opId: String
    public let message: String

    public init(opId: String, message: String) {
        self.opId = opId
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct SafeModeViolationError: Error, LocalizedError {
    public let opId: String
    public let message: String

    public init(opId: String, message: String) {
        self.opId = opId
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct VerificationError: Error, LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct AdapterError: Error, LocalizedError {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "[\(code)] \(message)" }
}
