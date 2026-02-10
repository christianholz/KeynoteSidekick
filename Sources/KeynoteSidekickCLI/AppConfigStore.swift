import Foundation

extension Notification.Name {
    static let sidekickOpenSettingsRequested = Notification.Name("sidekick.openSettingsRequested")
}

struct LLMSettingsSnapshot {
    let codexPath: String
    let model: String
    let reasoningEffort: String
    let hideAgentReasoning: Bool
    let modelReasoningSummary: String
    let showRawAgentReasoning: Bool
    let systemPrompt: String
    let debugLoggingEnabled: Bool
    let reflectionBasedEditsEnabled: Bool
}

enum AppConfigError: LocalizedError {
    case invalidCodexPath
    case invalidModel

    var errorDescription: String? {
        switch self {
        case .invalidCodexPath:
            return "Settings Codex CLI path cannot be empty."
        case .invalidModel:
            return "Settings model cannot be empty."
        }
    }
}

@MainActor
final class AppConfigStore: ObservableObject {
    static let shared = AppConfigStore()

    @Published var codexPath: String
    @Published var model: String
    @Published var reasoningEffort: String
    @Published var hideAgentReasoning: Bool
    @Published var modelReasoningSummary: String
    @Published var showRawAgentReasoning: Bool
    @Published var systemPrompt: String
    @Published var debugLoggingEnabled: Bool
    @Published var reflectionBasedEditsEnabled: Bool

    private let defaults = UserDefaults.standard
    private let initialSetupCompletedKey = "app.initialSetupCompleted"
    private let debugLoggingEnabledKey = "ui.debugLoggingEnabled"
    private let reasoningEffortKey = "codex.reasoningEffort"
    private let hideAgentReasoningKey = "codex.hideAgentReasoning"
    private let modelReasoningSummaryKey = "codex.modelReasoningSummary"
    private let showRawAgentReasoningKey = "codex.showRawAgentReasoning"
    private let reflectionBasedEditsEnabledKey = "ui.reflectionBasedEditsEnabled"

    private init() {
        let defaults = UserDefaults.standard

        self.codexPath = defaults.string(forKey: "codex.path") ?? "codex"
        self.model = defaults.string(forKey: "codex.model")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reasoningEffort = Self.normalizeReasoningEffort(
            defaults.string(forKey: reasoningEffortKey) ?? "medium"
        )
        if defaults.object(forKey: hideAgentReasoningKey) == nil {
            defaults.set(true, forKey: hideAgentReasoningKey)
        }
        self.hideAgentReasoning = defaults.bool(forKey: hideAgentReasoningKey)
        self.modelReasoningSummary = Self.normalizeReasoningSummary(
            defaults.string(forKey: modelReasoningSummaryKey) ?? "auto"
        )
        self.showRawAgentReasoning = defaults.bool(forKey: showRawAgentReasoningKey)
        self.systemPrompt = defaults.string(forKey: "codex.systemPrompt") ?? ""
        self.debugLoggingEnabled = defaults.bool(forKey: debugLoggingEnabledKey)
        self.reflectionBasedEditsEnabled = defaults.bool(forKey: reflectionBasedEditsEnabledKey)
    }

    func save(
        codexPath: String,
        model: String,
        reasoningEffort: String,
        hideAgentReasoning: Bool,
        modelReasoningSummary: String,
        showRawAgentReasoning: Bool,
        systemPrompt: String,
        debugLoggingEnabled: Bool,
        reflectionBasedEditsEnabled: Bool
    ) throws {
        let cleanedCodexPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedReasoningEffort = Self.normalizeReasoningEffort(reasoningEffort)
        let cleanedReasoningSummary = Self.normalizeReasoningSummary(modelReasoningSummary)
        let cleanedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedCodexPath.isEmpty else {
            throw AppConfigError.invalidCodexPath
        }
        guard !cleanedModel.isEmpty else {
            throw AppConfigError.invalidModel
        }

        defaults.set(cleanedCodexPath, forKey: "codex.path")
        defaults.set(cleanedModel, forKey: "codex.model")
        defaults.set(cleanedReasoningEffort, forKey: reasoningEffortKey)
        defaults.set(hideAgentReasoning, forKey: hideAgentReasoningKey)
        defaults.set(cleanedReasoningSummary, forKey: modelReasoningSummaryKey)
        defaults.set(showRawAgentReasoning, forKey: showRawAgentReasoningKey)
        defaults.set(cleanedSystemPrompt, forKey: "codex.systemPrompt")
        defaults.set(debugLoggingEnabled, forKey: debugLoggingEnabledKey)
        defaults.set(reflectionBasedEditsEnabled, forKey: reflectionBasedEditsEnabledKey)

        self.codexPath = cleanedCodexPath
        self.model = cleanedModel
        self.reasoningEffort = cleanedReasoningEffort
        self.hideAgentReasoning = hideAgentReasoning
        self.modelReasoningSummary = cleanedReasoningSummary
        self.showRawAgentReasoning = showRawAgentReasoning
        self.systemPrompt = cleanedSystemPrompt
        self.debugLoggingEnabled = debugLoggingEnabled
        self.reflectionBasedEditsEnabled = reflectionBasedEditsEnabled
    }

    func snapshot() throws -> LLMSettingsSnapshot {
        let cleanedCodexPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedCodexPath.isEmpty else {
            throw AppConfigError.invalidCodexPath
        }
        guard !cleanedModel.isEmpty else {
            throw AppConfigError.invalidModel
        }
        return LLMSettingsSnapshot(
            codexPath: cleanedCodexPath,
            model: cleanedModel,
            reasoningEffort: Self.normalizeReasoningEffort(reasoningEffort),
            hideAgentReasoning: hideAgentReasoning,
            modelReasoningSummary: Self.normalizeReasoningSummary(modelReasoningSummary),
            showRawAgentReasoning: showRawAgentReasoning,
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            debugLoggingEnabled: debugLoggingEnabled,
            reflectionBasedEditsEnabled: reflectionBasedEditsEnabled
        )
    }

    var needsInitialSetup: Bool {
        !defaults.bool(forKey: initialSetupCompletedKey)
    }

    func markInitialSetupCompleted() {
        defaults.set(true, forKey: initialSetupCompletedKey)
    }

    func applyDiscoveredModelIfMissing(_ discoveredModels: [String]) {
        let current = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty, let newest = discoveredModels.first else { return }
        model = newest
        defaults.set(newest, forKey: "codex.model")
    }

    private static func normalizeReasoningEffort(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowered {
        case "low", "medium", "high":
            return lowered
        default:
            return "medium"
        }
    }

    private static func normalizeReasoningSummary(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lowered {
        case "auto", "brief", "detailed":
            return lowered
        default:
            return "auto"
        }
    }
}
