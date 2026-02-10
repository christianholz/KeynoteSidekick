import Testing
@testable import KeynoteSidekickCLI

@Suite("App Main Launch Mode")
struct AppMainLaunchModeTests {
    @Test("Defaults to GUI mode")
    func defaultsToGUI() {
        let mode = KeynoteSidekickMain.parseLaunchMode(arguments: [])
        #expect(mode == .gui)
    }

    @Test("Parses pipeline mode")
    func parsesPipeline() {
        let mode = KeynoteSidekickMain.parseLaunchMode(arguments: ["--pipeline"])
        #expect(mode == .pipeline(prompt: nil, forceDebugLogging: false))
    }

    @Test("Parses single prompt and debug mode")
    func parsesPromptAndDebug() {
        let mode = KeynoteSidekickMain.parseLaunchMode(
            arguments: ["--pipeline", "--pipeline-debug", "--prompt", "rename title"]
        )
        #expect(mode == .pipeline(prompt: "rename title", forceDebugLogging: true))
    }

    @Test("Parses inline prompt format")
    func parsesInlinePrompt() {
        let mode = KeynoteSidekickMain.parseLaunchMode(
            arguments: ["--pipeline", "--prompt=add a slide"]
        )
        #expect(mode == .pipeline(prompt: "add a slide", forceDebugLogging: false))
    }

    @Test("Parses help mode")
    func parsesHelp() {
        let mode = KeynoteSidekickMain.parseLaunchMode(arguments: ["--help"])
        #expect(mode == .help)
    }
}
