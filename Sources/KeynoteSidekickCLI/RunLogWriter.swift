import Foundation

struct ReflectionRunLogHandle: Sendable {
    let id: UUID
    let path: String
    fileprivate let url: URL
}

final class RunLogWriter: @unchecked Sendable {
    static let shared = RunLogWriter()

    private let queue = DispatchQueue(label: "com.christian.keynotesidekick.runlog", qos: .utility)
    private let isoFormatter = ISO8601DateFormatter()
    private let transcriptURL: URL
    private let failureURL: URL
    private let reflectionRunsURL: URL
    private let maxBytes: UInt64 = 20 * 1024 * 1024

    init(baseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KeynoteSidekick", isDirectory: true)) {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        transcriptURL = baseURL.appendingPathComponent("sidekick.log")
        failureURL = baseURL.appendingPathComponent("failures.ndjson")
        reflectionRunsURL = baseURL.appendingPathComponent("reflection-runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: reflectionRunsURL, withIntermediateDirectories: true)
    }

    var logPaths: (transcript: String, failures: String, reflectionRuns: String) {
        (transcriptURL.path, failureURL.path, reflectionRunsURL.path)
    }

    func markRunStart(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ts = isoFormatter.string(from: Date())
        let line = "\(ts) RUN prompt=\(trimmed.replacingOccurrences(of: "\n", with: " "))"
        enqueueAppend(line: line, to: transcriptURL)
    }

    func append(rolePrefix: String, text: String, at timestamp: Date = Date()) {
        let message = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let ts = isoFormatter.string(from: timestamp)
        for raw in lines {
            enqueueAppend(line: "\(ts) \(rolePrefix): \(raw)", to: transcriptURL)
        }
        recordFailureIfPresent(rolePrefix: rolePrefix, text: message, timestamp: timestamp)
    }

    func startReflectionRun(prompt: String, at timestamp: Date = Date()) -> ReflectionRunLogHandle {
        let id = UUID()
        let fileURL = reflectionRunsURL.appendingPathComponent(reflectionFileName(timestamp: timestamp, id: id))
        let handle = ReflectionRunLogHandle(id: id, path: fileURL.path, url: fileURL)
        let ts = isoFormatter.string(from: timestamp)
        queue.sync {
            let header = [
                "\(ts) REFLECTION_RUN id=\(id.uuidString)",
                "\(ts) PROMPT: \(prompt.replacingOccurrences(of: "\n", with: " "))",
                "\(ts) ---"
            ].joined(separator: "\n") + "\n"
            if let data = header.data(using: .utf8) {
                try? data.write(to: fileURL, options: [.atomic])
            }
        }
        return handle
    }

    func appendReflection(_ text: String, to handle: ReflectionRunLogHandle, at timestamp: Date = Date()) {
        let message = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let ts = isoFormatter.string(from: timestamp)
        for raw in lines {
            enqueueAppend(line: "\(ts) \(raw)", to: handle.url)
        }
    }

    @discardableResult
    func finishReflectionRun(_ handle: ReflectionRunLogHandle, retain: Bool) -> String? {
        queue.sync {
            if retain {
                return handle.path
            }
            try? FileManager.default.removeItem(at: handle.url)
            return nil
        }
    }

    private func recordFailureIfPresent(rolePrefix: String, text: String, timestamp: Date) {
        let prefix = "FAILURE_JSON "
        let payloads: [String] = text
            .components(separatedBy: .newlines)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix(prefix) else { return nil }
                let payload = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !payload.isEmpty else { return nil }
                guard payload.first == "{" || payload.first == "[" else { return nil }
                return payload
            }

        guard !payloads.isEmpty else { return }

        queue.async {
            self.rotateIfNeeded(self.failureURL)
            for payloadText in payloads {
                var envelope: [String: Any] = [
                    "timestamp": self.isoFormatter.string(from: timestamp),
                    "role": rolePrefix
                ]

                if let payloadData = payloadText.data(using: .utf8),
                   let payload = try? JSONSerialization.jsonObject(with: payloadData, options: []) {
                    envelope["failure"] = payload
                } else {
                    envelope["failureRaw"] = payloadText
                }

                guard let jsonData = try? JSONSerialization.data(withJSONObject: envelope, options: []),
                      let jsonLine = String(data: jsonData, encoding: .utf8) else {
                    continue
                }
                self.appendLine(jsonLine, to: self.failureURL)
            }
        }
    }

    private func enqueueAppend(line: String, to url: URL) {
        queue.async {
            self.rotateIfNeeded(url)
            self.appendLine(line, to: url)
        }
    }

    private func appendLine(_ line: String, to url: URL) {
        let payload = line + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.uint64Value >= maxBytes else {
            return
        }

        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    private func reflectionFileName(timestamp: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let shortId = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "reflection-\(formatter.string(from: timestamp))-\(shortId).log"
    }
}
