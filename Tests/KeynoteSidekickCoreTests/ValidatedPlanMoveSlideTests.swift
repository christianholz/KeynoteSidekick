import Foundation
import Testing
@testable import KeynoteSidekickCore

@Suite("Validated Plan MoveSlide")
struct ValidatedPlanMoveSlideTests {
    @Test("moveSlide accepts common index aliases")
    func moveSlideAcceptsIndexAliases() throws {
        let samples: [(String, String)] = [
            ("index", "2"),
            ("toIndex", "3"),
            ("destinationIndex", "4"),
            ("targetIndex", "5"),
            ("to", "6"),
            ("to", #"{"index":7}"#)
        ]

        for (key, rawValue) in samples {
            let json = """
            {
              "meta": {
                "irVersion": "0.1.0"
              },
              "operations": [
                {
                  "op": "moveSlide",
                  "target": { "slideKey": "s3" },
                  "args": { "\(key)": \(rawValue) }
                }
              ]
            }
            """

            let data = try #require(json.data(using: .utf8))
            let plan = try JSONDecoder().decode(IRPlan.self, from: data)
            let validated = try validate(plan: plan)
            #expect(validated.operations.count == 1)
            guard case .moveSlide(_, let index) = validated.operations[0].payload else {
                Issue.record("Expected moveSlide payload for alias \(key)")
                continue
            }
            #expect(index > 0)
        }
    }
}
