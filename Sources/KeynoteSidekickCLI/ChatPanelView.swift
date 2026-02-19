import SwiftUI
import AppKit

private enum ChatTheme {
    static let contentLeading: CGFloat = 16
    static let composerOuterHorizontalInset: CGFloat = 7
    static let composerTextInsetX: CGFloat = contentLeading - composerOuterHorizontalInset

    static let canvas = NSColor(
        calibratedRed: 0.20,
        green: 0.23,
        blue: 0.27,
        alpha: 1.0
    )
    static let composerArea = NSColor(
        calibratedRed: 0.17,
        green: 0.19,
        blue: 0.23,
        alpha: 1.0
    )
    static let sectionDivider = NSColor(white: 1.0, alpha: 0.10)
    static let busyOverlay = NSColor(
        calibratedRed: 0.14,
        green: 0.16,
        blue: 0.20,
        alpha: 0.92
    )
    static let primaryText = NSColor(calibratedWhite: 0.90, alpha: 1.0)
    static let secondaryText = NSColor(calibratedWhite: 0.72, alpha: 1.0)
    static let accentText = NSColor(
        calibratedRed: 0.66,
        green: 0.79,
        blue: 0.98,
        alpha: 1.0
    )
    static let requestText = NSColor(
        calibratedRed: 0.95,
        green: 0.75,
        blue: 0.45,
        alpha: 1.0
    )
    static let responseText = NSColor(
        calibratedRed: 0.60,
        green: 0.86,
        blue: 0.67,
        alpha: 1.0
    )
    static let errorText = NSColor(
        calibratedRed: 0.98,
        green: 0.56,
        blue: 0.56,
        alpha: 1.0
    )

    static let canvasColor = Color(nsColor: canvas)
    static let composerAreaColor = Color(nsColor: composerArea)
    static let sectionDividerColor = Color(nsColor: sectionDivider)
    static let secondaryTextColor = Color(nsColor: secondaryText)
    static let accentTextColor = Color(nsColor: accentText)
}

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
        case progress
        case codexRequest
        case codexResponse
        case error
    }

    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
}

final class RunCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var isBusy = false
    @Published var isCodexActive = false
    @Published var busyStatusText = "Preparing request..."
    @Published var isKeynoteRunning = false

    private let engine = LiveAutomationEngine()
    private let settings: AppConfigStore
    private let runLogWriter = RunLogWriter.shared
    private let workerQueue = DispatchQueue(label: "com.christian.keynotesidekick.chat", qos: .userInitiated)
    private var runCancellationToken: RunCancellationToken?

    init(settings: AppConfigStore) {
        self.settings = settings
        let keynoteRunning = Self.isKeynoteRunning()
        self.isKeynoteRunning = keynoteRunning
        let welcomeText: String
        if keynoteRunning {
            welcomeText = "Connected to Keynote"
        } else {
            welcomeText = "Keynote is not running"
        }
        let welcome = ChatMessage(
            role: .assistant,
            text: welcomeText,
            timestamp: Date()
        )
        messages = [welcome]
        runLogWriter.append(rolePrefix: rolePrefix(welcome.role), text: welcome.text, at: welcome.timestamp)
    }

    private static func isKeynoteRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.apple.iWork.Keynote"
        }
    }

    func refreshKeynoteAvailability(announceIfChanged: Bool) {
        let current = Self.isKeynoteRunning()
        let changed = (current != isKeynoteRunning)
        if changed {
            isKeynoteRunning = current
            if announceIfChanged {
                let message = current
                    ? "Keynote detected. Composer enabled."
                    : "Keynote not detected. Composer disabled."
                append(role: .progress, text: message)
            }
        }
    }

    func sendCurrentDraft() {
        refreshKeynoteAvailability(announceIfChanged: true)
        guard isKeynoteRunning else {
            append(role: .error, text: "Keynote is not running. Open Keynote, then try again.")
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !isBusy else { return }

        let snapshot: LLMSettingsSnapshot
        do {
            snapshot = try settings.snapshot()
        } catch {
            append(role: .error, text: error.localizedDescription)
            if let configError = error as? AppConfigError,
               configError == .invalidCodexPath || configError == .invalidModel {
                NotificationCenter.default.post(name: .sidekickOpenSettingsRequested, object: nil)
            }
            return
        }

        draft = ""
        isBusy = true
        setBusyStatus("Preparing request...")
        runLogWriter.markRunStart(prompt: text)
        append(role: .user, text: text)
        append(role: .progress, text: "Preparing request...")
        let cancellationToken = RunCancellationToken()
        runCancellationToken = cancellationToken

        let engine = self.engine
        workerQueue.async { [text, snapshot] in
            let outcome = engine.handle(
                input: text,
                settings: snapshot,
                shouldCancel: { cancellationToken.isCancelled() },
                onCodexActivity: { isActive in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.isCodexActive = isActive
                        if isActive {
                            if self.busyStatusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                self.busyStatusText == "Preparing request..." ||
                                self.busyStatusText == "Applying changes in Keynote..." {
                                self.setBusyStatus("Waiting for Codex response...")
                            }
                        } else if self.isBusy {
                            self.setBusyStatus("Applying changes in Keynote...")
                        }
                    }
                },
                onProgress: { event in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.updateBusyStatus(from: event)
                        let allowReasoningEvent = self.settings.showRawAgentReasoning && self.isReasoningEvent(event)
                        if self.isDebugLogEvent(event) &&
                            !self.settings.debugLoggingEnabled &&
                            !allowReasoningEvent {
                            return
                        }

                        let role: ChatMessage.Role
                        if event.hasPrefix("Codex request:") {
                            role = .codexRequest
                        } else if event.hasPrefix("Codex response raw:") {
                            role = .codexResponse
                        } else {
                            role = .progress
                        }

                        if self.isDebugLogEvent(event) &&
                            !self.settings.debugLoggingEnabled &&
                            !allowReasoningEvent {
                            self.runLogWriter.append(rolePrefix: self.rolePrefix(role), text: event)
                            return
                        }
                        self.append(role: role, text: event)
                    }
                }
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.runCancellationToken = nil
                self.isCodexActive = false
                self.setBusyStatus("")

                if outcome.cancelled {
                    if self.messages.last?.text != "Run canceled by user." {
                        self.append(role: .progress, text: "Run canceled by user.")
                    }
                } else if outcome.success {
                    self.append(role: .assistant, text: outcome.reply)
                } else {
                    self.append(role: .error, text: outcome.reply)
                }

                self.isBusy = false
            }
        }
    }

    func stopCurrentRun() {
        guard isBusy else { return }
        runCancellationToken?.cancel()
        setBusyStatus("Cancel requested...")
        append(role: .progress, text: "Cancel requested by user...")
    }

    private func append(role: ChatMessage.Role, text: String) {
        let message = ChatMessage(role: role, text: text, timestamp: Date())
        messages.append(message)
        runLogWriter.append(rolePrefix: rolePrefix(role), text: text, at: message.timestamp)
    }

    private func isDebugLogEvent(_ event: String) -> Bool {
        event.hasPrefix("Codex request:") ||
            event.hasPrefix("Codex response raw:") ||
            event.hasPrefix("Codex event:") ||
            event.hasPrefix("Plan raw:") ||
            event.hasPrefix("Plan sanitized:")
    }

    private func isReasoningEvent(_ event: String) -> Bool {
        event.hasPrefix("Codex event: proto.agent_reasoning") ||
            event.hasPrefix("Codex event: proto.agent_reasoning_delta") ||
            event.hasPrefix("Codex event: proto.agent_reasoning_section_break")
    }

    private func updateBusyStatus(from event: String) {
        let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("Sending request to Codex") {
            setBusyStatus("Sending request to Codex...")
            return
        }

        if trimmed.hasPrefix("Codex event: proto.task_started") {
            setBusyStatus("Waiting for Codex response...")
            return
        }

        if trimmed.hasPrefix("Codex event: proto.heartbeat ") {
            let token = trimmed
                .replacingOccurrences(of: "Codex event: proto.heartbeat ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let secondsToken = token.split(separator: " ").first {
                setBusyStatus("Codex is thinking... (\(secondsToken))")
            } else {
                setBusyStatus("Codex is thinking...")
            }
            return
        }

        if trimmed.hasPrefix("Codex event: proto.agent_reasoning") ||
            trimmed.hasPrefix("Codex event: proto.agent_message_delta") {
            setBusyStatus("Codex is preparing response...")
            return
        }

        if trimmed.hasPrefix("Codex event: proto.agent_message received (finalizing)") {
            setBusyStatus("Finalizing Codex response...")
            return
        }

        if trimmed.hasPrefix("Collecting full presentation context from Keynote") ||
            trimmed.hasPrefix("Collecting presentation context from Keynote") {
            setBusyStatus("Collecting Keynote context...")
            return
        }

        if trimmed.hasPrefix("Capturing presentation state") {
            setBusyStatus("Capturing deck state...")
            return
        }

        if trimmed.hasPrefix("Reflection iteration ") {
            setBusyStatus(truncateStatus(trimmed, max: 120))
            return
        }

        if trimmed.hasPrefix("Execution complete.") {
            setBusyStatus("Execution complete.")
            return
        }
    }

    private func setBusyStatus(_ status: String) {
        guard busyStatusText != status else { return }
        busyStatusText = status
    }

    private func truncateStatus(_ text: String, max: Int) -> String {
        guard text.count > max, max > 3 else { return text }
        let end = text.index(text.startIndex, offsetBy: max - 3)
        return String(text[..<end]) + "..."
    }

    private func rolePrefix(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user:
            return "YOU"
        case .assistant:
            return "SIDEKICK"
        case .progress:
            return "PROGRESS"
        case .codexRequest:
            return "CODEX->"
        case .codexResponse:
            return "CODEX<-"
        case .error:
            return "ERROR"
        }
    }
}

struct ChatPanelView: View {
    @StateObject private var settings = AppConfigStore.shared
    @StateObject private var model: ChatViewModel
    @State private var showSettings = false
    @State private var composerHeight: CGFloat = 36
    @State private var isComposerFocused = false
    @State private var isWindowActive = true
    @State private var inputFocusNonce: Int = 0
    @State private var didRunInitialSetupCheck = false

    init() {
        let shared = AppConfigStore.shared
        _settings = StateObject(wrappedValue: shared)
        _model = StateObject(wrappedValue: ChatViewModel(settings: shared))
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            inputBar
                .padding(.top, 7)
                .padding(.bottom, 8)
                .background(ChatTheme.composerAreaColor)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(ChatTheme.sectionDividerColor)
                        .frame(height: 1)
                }
        }
        .background(ChatTheme.canvasColor)
        .sheet(isPresented: $showSettings) {
            SettingsDialogView(settings: settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidekickOpenSettingsRequested)) { _ in
            showSettings = true
        }
        .onAppear {
            model.refreshKeynoteAvailability(announceIfChanged: false)
            DispatchQueue.main.async {
                inputFocusNonce += 1
            }
            runInitialSetupBootstrapIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshKeynoteAvailability(announceIfChanged: true)
            isWindowActive = true
            guard !showSettings else { return }
            DispatchQueue.main.async {
                inputFocusNonce += 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            isWindowActive = false
        }
        .onChange(of: model.isBusy) { busy in
            guard !busy, !showSettings else { return }
            DispatchQueue.main.async {
                inputFocusNonce += 1
            }
        }
    }

    private var transcript: some View {
        TranscriptTextView(messages: model.messages, isWindowActive: isWindowActive)
    }

    private var inputBar: some View {
        ZStack(alignment: .trailing) {
            ZStack(alignment: .topLeading) {
                if !model.isKeynoteRunning {
                    Text("Open Keynote to enable edits...")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(ChatTheme.secondaryTextColor)
                        .padding(.horizontal, ChatTheme.composerTextInsetX)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                } else if model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !model.isBusy &&
                    !isComposerFocused {
                    Text("Describe what to change in Keynote...")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(ChatTheme.secondaryTextColor)
                        .padding(.horizontal, ChatTheme.composerTextInsetX)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                PromptComposerTextView(
                    text: $model.draft,
                    height: $composerHeight,
                    isFocused: $isComposerFocused,
                    isEditable: !model.isBusy && model.isKeynoteRunning,
                    focusNonce: inputFocusNonce,
                    onSend: {
                        model.sendCurrentDraft()
                    }
                )

                if model.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.busyStatusText)
                            .font(.caption)
                            .foregroundStyle(ChatTheme.secondaryTextColor)
                        Spacer()
                    }
                    .padding(.horizontal, ChatTheme.composerTextInsetX)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                }
            }
            .padding(.trailing, 34)
            .frame(height: composerHeight)

            Button {
                if model.isBusy {
                    model.stopCurrentRun()
                } else {
                    model.sendCurrentDraft()
                }
                } label: {
                if model.isBusy {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                }
            .buttonStyle(.plain)
            .frame(width: 24, height: 24)
            .foregroundStyle(model.isBusy ? Color.red : ChatTheme.accentTextColor)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!model.isBusy && (!model.isKeynoteRunning || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .opacity((!model.isBusy && (!model.isKeynoteRunning || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) ? 0.55 : 1.0)
            .padding(.trailing, 10)
        }
        .padding(.horizontal, ChatTheme.composerOuterHorizontalInset)
    }

    private func runInitialSetupBootstrapIfNeeded() {
        guard !didRunInitialSetupCheck else { return }
        didRunInitialSetupCheck = true
        guard settings.needsInitialSetup else { return }

        let configuredPath = settings.codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configuredPath.isEmpty ? "codex" : configuredPath

        DispatchQueue.global(qos: .userInitiated).async {
            let loginState = CodexCLI.loginState(codexPath: path)
            let discoveredModels = CodexCLI.discoverAccessibleModels(codexPath: path)

            DispatchQueue.main.async {
                settings.applyDiscoveredModelIfMissing(discoveredModels)
                settings.markInitialSetupCompleted()

                let hasModel = !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let shouldForceSettings: Bool
                switch loginState {
                case .unauthenticated:
                    shouldForceSettings = true
                case .authenticated, .unknown:
                    shouldForceSettings = !hasModel
                }

                if shouldForceSettings {
                    showSettings = true
                }
            }
        }
    }
}

private final class PromptInputNSTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = keyCode == 36 || keyCode == 76

        if isReturn {
            if modifiers.contains(.shift) {
                super.keyDown(with: event)
                return
            }
            onSend?()
            return
        }

        super.keyDown(with: event)
    }
}

private struct PromptComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    let isEditable: Bool
    let focusNonce: Int
    let onSend: () -> Void

    private let minHeight: CGFloat = 36
    private let maxHeight: CGFloat = 140

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptInputNSTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 14, weight: .regular)
        textView.textColor = ChatTheme.primaryText
        textView.insertionPointColor = ChatTheme.primaryText
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: ChatTheme.composerTextInsetX, height: 8)
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        textView.isEditable = isEditable

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.lastFocusNonce = focusNonce
        recalculateHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.onSend = onSend

        if textView.string != text {
            textView.string = text
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if !isEditable && isFocused {
            DispatchQueue.main.async {
                isFocused = false
            }
        }

        if context.coordinator.lastFocusNonce != focusNonce, let window = textView.window {
            context.coordinator.lastFocusNonce = focusNonce
            DispatchQueue.main.async {
                window.makeFirstResponder(textView)
                isFocused = true
            }
        }

        recalculateHeight(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func recalculateHeight(for textView: NSTextView) {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let contentHeight = usedRect.height + (textView.textContainerInset.height * 2)
        let clamped = min(max(minHeight, ceil(contentHeight)), maxHeight)
        if abs(height - clamped) > 0.5 {
            DispatchQueue.main.async {
                height = clamped
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptComposerTextView
        weak var textView: PromptInputNSTextView?
        var lastFocusNonce: Int = 0

        init(parent: PromptComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let newText = textView.string
            if parent.text != newText {
                parent.text = newText
            }
            parent.recalculateHeight(for: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }
    }
}

struct TranscriptTextView: NSViewRepresentable {
    let messages: [ChatMessage]
    let isWindowActive: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.font = .systemFont(ofSize: 14.5, weight: .regular)
        textView.textContainerInset = NSSize(width: ChatTheme.contentLeading, height: 14)
        textView.backgroundColor = ChatTheme.canvas
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ChatTheme.canvas
        scrollView.documentView = textView

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let newPlainText = messages.map { "\(rolePrefix($0.role)): \($0.text)" }.joined(separator: "\n")
        let needsStyleRefresh = context.coordinator.lastWindowActive != isWindowActive
        context.coordinator.lastWindowActive = isWindowActive
        guard textView.string != newPlainText || needsStyleRefresh else { return }

        let shouldStickToBottom = isNearBottom(scrollView)
        let clipView = scrollView.contentView
        let previousOrigin = clipView.bounds.origin

        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.setAttributedString(attributedTranscript())
            storage.endEditing()
        } else {
            textView.textStorage?.setAttributedString(attributedTranscript())
        }

        if let textContainer = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: textContainer)
        }
        textView.layoutSubtreeIfNeeded()
        textView.needsDisplay = true
        clipView.needsDisplay = true

        if shouldStickToBottom {
            scrollToBottom(scrollView)
        } else {
            let maxOffsetY = max(0, textView.frame.height - clipView.bounds.height)
            let clampedY = min(max(previousOrigin.y, 0), maxOffsetY)
            clipView.scroll(to: NSPoint(x: previousOrigin.x, y: clampedY))
            scrollView.reflectScrolledClipView(clipView)
        }

        DispatchQueue.main.async {
            textView.needsDisplay = true
            clipView.needsDisplay = true
            if shouldStickToBottom {
                scrollToBottom(scrollView)
            } else {
                scrollView.reflectScrolledClipView(clipView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func isNearBottom(_ scrollView: NSScrollView) -> Bool {
        guard let doc = scrollView.documentView else { return true }
        let clipBounds = scrollView.contentView.bounds
        let contentHeight = doc.frame.height
        if contentHeight <= clipBounds.height + 1 {
            return true
        }

        let visibleMaxY = clipBounds.origin.y + clipBounds.height
        return (contentHeight - visibleMaxY) <= 6
    }

    private func scrollToBottom(_ scrollView: NSScrollView) {
        guard let doc = scrollView.documentView else { return }
        doc.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let maxOffsetY = max(0, doc.frame.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maxOffsetY))
        scrollView.reflectScrolledClipView(clipView)
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastWindowActive: Bool?
    }

    private func attributedTranscript() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 14.5, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.0

        for (index, message) in messages.enumerated() {
            let line = "\(rolePrefix(message.role)): \(message.text)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: roleColor(message.role),
                .paragraphStyle: paragraph
            ]
            out.append(NSAttributedString(string: line, attributes: attributes))
            if index < messages.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }

        return out
    }

    private func rolePrefix(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user:
            return "YOU"
        case .assistant:
            return "SIDEKICK"
        case .progress:
            return "PROGRESS"
        case .codexRequest:
            return "CODEX->"
        case .codexResponse:
            return "CODEX<-"
        case .error:
            return "ERROR"
        }
    }

    private func roleColor(_ role: ChatMessage.Role) -> NSColor {
        let base: NSColor
        switch role {
        case .user:
            base = ChatTheme.accentText
        case .assistant:
            base = ChatTheme.primaryText
        case .progress:
            base = ChatTheme.secondaryText
        case .codexRequest:
            base = ChatTheme.requestText
        case .codexResponse:
            base = ChatTheme.responseText
        case .error:
            base = ChatTheme.errorText
        }
        if isWindowActive {
            return base
        }
        return base.withAlphaComponent(0.78)
    }
}

struct SettingsDialogView: View {
    @ObservedObject var settings: AppConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var codexPath: String = ""
    @State private var model: String = ""
    @State private var reasoningEffort: String = "medium"
    @State private var hideAgentReasoning: Bool = true
    @State private var modelReasoningSummary: String = "auto"
    @State private var showRawAgentReasoning: Bool = false
    @State private var systemPrompt: String = ""
    @State private var debugLoggingEnabled: Bool = false
    @State private var reflectionBasedEditsEnabled: Bool = false
    @State private var codexStatus: String = ""
    @State private var isCheckingStatus = false
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelDiscoveryStatus: String = ""
    @State private var errorMessage: String?
    private let logPaths = RunLogWriter.shared.logPaths

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Settings")
                        .font(.title3.weight(.semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Codex CLI Path")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("codex", text: $codexPath)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ChatGPT Login")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Check Status") {
                                refreshCodexStatus()
                            }
                            .buttonStyle(.link)
                            .disabled(isCheckingStatus)
                            Button("Run codex login") {
                                openTerminalForCodexLogin()
                            }
                            .buttonStyle(.link)
                        }

                        Text(codexStatus.isEmpty ? "Status not checked yet." : codexStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Model")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Load Available Models") {
                                refreshAvailableModels()
                            }
                            .buttonStyle(.link)
                            .disabled(isLoadingModels)
                        }
                        TextField("e.g. gpt-5.2-codex", text: $model)
                            .textFieldStyle(.roundedBorder)

                        Group {
                            if !availableModels.isEmpty {
                                Picker("Discovered", selection: $model) {
                                    ForEach(availableModels, id: \.self) { candidate in
                                        Text(candidate).tag(candidate)
                                    }
                                    if !availableModels.contains(model) {
                                        Text(model).tag(model)
                                    }
                                }
                                .pickerStyle(.menu)
                            } else {
                                Text("Discovered models will appear here.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .opacity(0.5)
                            }
                        }
                        .frame(height: 22, alignment: .leading)

                        Group {
                            if isLoadingModels {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Discovering models...")
                                }
                            } else if !modelDiscoveryStatus.isEmpty {
                                Text(modelDiscoveryStatus)
                            } else {
                                Text(" ")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 16, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reasoning Effort")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Reasoning Effort", selection: $reasoningEffort) {
                            Text("Low").tag("low")
                            Text("Medium").tag("medium")
                            Text("High").tag("high")
                        }
                        .pickerStyle(.segmented)
                        Text("Higher effort can improve plan quality but increases latency.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reasoning Visibility")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Reasoning Summary", selection: $modelReasoningSummary) {
                            Text("Auto").tag("auto")
                            Text("Brief").tag("brief")
                            Text("Detailed").tag("detailed")
                        }
                        .pickerStyle(.segmented)

                        Toggle("Hide agent reasoning", isOn: $hideAgentReasoning)
                            .toggleStyle(.checkbox)
                        Toggle("Show raw agent reasoning events", isOn: $showRawAgentReasoning)
                            .toggleStyle(.checkbox)

                        Text("Raw reasoning can expose verbose internal model traces in the transcript.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Prompt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Always applied to Codex planning for this app.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: NSFont.systemFontSize))
                            .frame(minHeight: 110, maxHeight: 180)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                    }

                    Toggle(isOn: $debugLoggingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show debug logs in transcript")
                            Text("Includes Codex request/response payloads and proto heartbeat/usage events.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $reflectionBasedEditsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reflection-based edits")
                            Text("Captures per-run before/after deck state, runs codex self-check/repair loops, and keeps logs only when repairs were needed.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run log: \(logPaths.transcript)")
                        Text("Failure log: \(logPaths.failures)")
                        Text("Reflection logs: \(logPaths.reflectionRuns)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 760)
        .onAppear {
            codexPath = settings.codexPath
            model = settings.model
            reasoningEffort = settings.reasoningEffort
            hideAgentReasoning = settings.hideAgentReasoning
            modelReasoningSummary = settings.modelReasoningSummary
            showRawAgentReasoning = settings.showRawAgentReasoning
            systemPrompt = settings.systemPrompt
            debugLoggingEnabled = settings.debugLoggingEnabled
            reflectionBasedEditsEnabled = settings.reflectionBasedEditsEnabled
            refreshCodexStatus()
            refreshAvailableModels()
        }
    }

    private func save() {
        do {
            try settings.save(
                codexPath: codexPath,
                model: model,
                reasoningEffort: reasoningEffort,
                hideAgentReasoning: hideAgentReasoning,
                modelReasoningSummary: modelReasoningSummary,
                showRawAgentReasoning: showRawAgentReasoning,
                systemPrompt: systemPrompt,
                debugLoggingEnabled: debugLoggingEnabled,
                reflectionBasedEditsEnabled: reflectionBasedEditsEnabled
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshCodexStatus() {
        isCheckingStatus = true
        codexStatus = "Checking..."
        let path = codexPath.isEmpty ? "codex" : codexPath
        DispatchQueue.global(qos: .userInitiated).async {
            let status = CodexCLI.loginStatus(codexPath: path)
            DispatchQueue.main.async {
                let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                self.codexStatus = "[\(timestamp)] \(status)"
                self.isCheckingStatus = false
            }
        }
    }

    private func refreshAvailableModels() {
        isLoadingModels = true
        modelDiscoveryStatus = ""
        let path = codexPath.isEmpty ? "codex" : codexPath
        DispatchQueue.global(qos: .userInitiated).async {
            let discovered = CodexCLI.discoverAccessibleModels(codexPath: path)
            DispatchQueue.main.async {
                self.availableModels = discovered
                if let newest = discovered.first {
                    let current = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    if current.isEmpty || !discovered.contains(current) {
                        self.model = newest
                    }
                    self.modelDiscoveryStatus = "Using newest available model: \(newest)"
                } else {
                    self.modelDiscoveryStatus = "No accessible models discovered. You can still type one manually."
                }
                self.isLoadingModels = false
            }
        }
    }

    private func openTerminalForCodexLogin() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"codex login\""
        ]
        try? process.run()
    }

}
