import Foundation
import KeynoteSidekickCore

struct ProcessRunner {
    static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        var lastError: AdapterError?

        for attempt in 1...2 {
            do {
                return try runOnce(launchPath, arguments)
            } catch let error as AdapterError {
                lastError = error
                let message = error.message.lowercased()
                let isTransientAppleEvent = message.contains("appleevent handler failed") || message.contains("(-10000)")

                if attempt == 1 && isTransientAppleEvent {
                    Thread.sleep(forTimeInterval: 0.35)
                    continue
                }
                throw error
            }
        }

        throw lastError ?? AdapterError(code: "PROCESS_FAILED", message: "Process failed with unknown error")
    }

    private static func runOnce(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

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
            throw AdapterError(code: "PROCESS_FAILED", message: err.isEmpty ? "Process failed with status \(process.terminationStatus)" : err)
        }

        return out
    }
}
