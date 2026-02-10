import Foundation
import Testing
@testable import KeynoteSidekickCLI

@Suite("Run Log Writer")
struct RunLogWriterTests {
    @Test("Deletes reflection run log when retain is false")
    func deletesReflectionRunLogWhenNotRetained() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ksk-runlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let writer = RunLogWriter(baseURL: tempRoot)
        let handle = writer.startReflectionRun(prompt: "test prompt", at: Date(timeIntervalSince1970: 1))
        writer.appendReflection("hello", to: handle, at: Date(timeIntervalSince1970: 2))

        let retainedPath = writer.finishReflectionRun(handle, retain: false)
        #expect(retainedPath == nil)
        #expect(FileManager.default.fileExists(atPath: handle.path) == false)
    }

    @Test("Keeps reflection run log when retain is true")
    func keepsReflectionRunLogWhenRetained() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ksk-runlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let writer = RunLogWriter(baseURL: tempRoot)
        let handle = writer.startReflectionRun(prompt: "verify prompt", at: Date(timeIntervalSince1970: 1))
        writer.appendReflection("line one", to: handle, at: Date(timeIntervalSince1970: 2))
        writer.appendReflection("line two", to: handle, at: Date(timeIntervalSince1970: 3))

        let retainedPath = writer.finishReflectionRun(handle, retain: true)
        #expect(retainedPath == handle.path)
        #expect(FileManager.default.fileExists(atPath: handle.path))

        let contents = try String(contentsOfFile: handle.path, encoding: .utf8)
        #expect(contents.contains("PROMPT: verify prompt"))
        #expect(contents.contains("line one"))
        #expect(contents.contains("line two"))
    }
}
