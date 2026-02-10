import Foundation
import Testing
@testable import KeynoteSidekickCore
import KeynoteSidekickAdapters

@Suite("Execution")
struct ExecutionTests {
    @Test("Plan execution is idempotent with mock adapter")
    func planIsIdempotentWithMockAdapter() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let planPath = cwd.appendingPathComponent("Examples/mvp_plan.json").path
        let data = try Data(contentsOf: URL(fileURLWithPath: planPath))
        let decoded = try JSONDecoder().decode(IRPlan.self, from: data)
        let plan = try validate(plan: decoded)
        let adapter = MockKeynoteAdapter()
        let executor = PlanExecutor(adapter: adapter)

        let first = try executor.execute(plan)
        let firstDigest = try adapter.deckDigest()
        let second = try executor.execute(plan)
        let secondDigest = try adapter.deckDigest()

        #expect(first.summary.failed == 0)
        #expect(second.summary.failed == 0)
        #expect(firstDigest == secondDigest)
    }

    @Test("Invalid IR version is rejected")
    func rejectsWrongIRVersion() throws {
        let json = """
        {
          "meta": {
            "irVersion": "9.9.9"
          },
          "operations": []
        }
        """

        let data = json.data(using: .utf8)!
        let plan = try JSONDecoder().decode(IRPlan.self, from: data)

        do {
            _ = try validate(plan: plan)
            Issue.record("Expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("Unsupported irVersion"))
        }
    }

    @Test("Executor refreshes slide bindings after structural ops")
    func executorRefreshesBindingsAfterStructuralOps() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let planPath = cwd.appendingPathComponent("Examples/mvp_plan.json").path
        let data = try Data(contentsOf: URL(fileURLWithPath: planPath))
        let decoded = try JSONDecoder().decode(IRPlan.self, from: data)
        let plan = try validate(plan: decoded)

        let adapter = MockKeynoteAdapter()
        let executor = PlanExecutor(adapter: adapter)
        _ = try executor.execute(plan)

        #expect(adapter.refreshSlideBindingsCallCount > 0)
    }
}
