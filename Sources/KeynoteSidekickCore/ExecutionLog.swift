import Foundation

public enum DriverUsed: String, Codable {
    case script
    case ax
    case mock
}

public struct VerificationDetails: Codable {
    public let passed: Bool
    public let checks: [String: Bool]
    public let deltas: [String: Double]
    public let messages: [String]

    public init(passed: Bool, checks: [String: Bool], deltas: [String: Double], messages: [String]) {
        self.passed = passed
        self.checks = checks
        self.deltas = deltas
        self.messages = messages
    }
}

public struct OperationLogEntry: Codable {
    public let timestamp: String
    public let opId: String
    public let op: String
    public let status: String
    public let attempt: Int
    public let driverUsed: DriverUsed
    public let driftDetected: Bool
    public let resyncPerformed: Bool
    public let resyncAmbiguous: Bool
    public let verification: VerificationDetails?
    public let error: String?
}

public struct ExecutionSummary: Codable {
    public let startedAt: String
    public let endedAt: String
    public let total: Int
    public let ok: Int
    public let failed: Int
    public let retried: Int
    public let fallbackCount: Int
}

public struct ExecutionReport: Codable {
    public let summary: ExecutionSummary
    public let entries: [OperationLogEntry]
}

public final class ExecutionLogger {
    private(set) var entries: [OperationLogEntry] = []
    private let startedAt = ISO8601DateFormatter().string(from: Date())

    public init() {}

    public func append(_ entry: OperationLogEntry) {
        entries.append(entry)
    }

    public func report() -> ExecutionReport {
        let ok = entries.filter { $0.status == "ok" }.count
        let failed = entries.filter { $0.status == "failed" }.count
        let retried = entries.filter { $0.attempt > 1 }.count
        let fallbackCount = entries.filter { $0.driverUsed == .ax }.count
        let summary = ExecutionSummary(
            startedAt: startedAt,
            endedAt: ISO8601DateFormatter().string(from: Date()),
            total: entries.count,
            ok: ok,
            failed: failed,
            retried: retried,
            fallbackCount: fallbackCount
        )
        return ExecutionReport(summary: summary, entries: entries)
    }
}
