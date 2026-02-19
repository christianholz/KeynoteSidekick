import AppKit
import SwiftUI
import Foundation
import Darwin

@MainActor
private final class StartupLogger {
    static let shared = StartupLogger()
    private let logURL = URL(fileURLWithPath: "/tmp/keynotesidekick-startup.log")

    private init() {}

    func log(_ message: String) {
        let line = "[\(isoNow())] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    return
                }
            }
            try? data.write(to: logURL, options: [.atomic])
        }
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var floatToggleButton: NSButton?
    private var floatToggleContainer: NSView?
    private var isFloatAtopEnabled = true
    private let logger = StartupLogger.shared

    func configureAndShowWindow() {
        if window == nil {
            logger.log("Creating window")
            window = buildWindow()
            window?.delegate = self
        }

        guard let window else {
            logger.log("Window is nil after build")
            return
        }

        positionWindowOnRight(window)
        applyFloatAtopState(for: window)
        updateFloatTogglePosition(for: window)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.setIsVisible(true)

        NSApp.activate(ignoringOtherApps: true)
        logger.log("Window frame: \(window.frame.debugDescription)")
        logger.log("Window should now be visible; isVisible=\(window.isVisible)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let window = self.window else { return }
            if !window.isVisible {
                self.logger.log("Window not visible after startup safeguard, showing alert")
                let alert = NSAlert()
                alert.messageText = "Keynote Sidekick started but window is hidden"
                alert.informativeText = "Try Window > Keynote Sidekick or relaunch. Diagnostic log: /tmp/keynotesidekick-startup.log"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("applicationDidFinishLaunching")
        configureAndShowWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        logger.log("applicationDidBecomeActive")
        configureAndShowWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.log("applicationShouldHandleReopen visible=\(flag)")
        if !flag {
            configureAndShowWindow()
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        logger.log("windowWillClose")
        NSApp.terminate(nil)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        updateFloatTogglePosition(for: window)
    }

    private func buildWindow() -> NSWindow {
        let frame = defaultFrame()

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "KeynoteSidekick"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(
            calibratedRed: 0.20,
            green: 0.23,
            blue: 0.27,
            alpha: 1.0
        )
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
        window.tabbingMode = .disallowed
        configureTrafficLights(for: window)
        installFloatAtopToggle(on: window)
        window.contentViewController = NSHostingController(rootView: ChatPanelView())

        return window
    }

    private func configureTrafficLights(for window: NSWindow) {
        if let minimizeButton = window.standardWindowButton(.miniaturizeButton) {
            minimizeButton.isEnabled = false
            minimizeButton.isHidden = true
        }
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.isEnabled = false
            zoomButton.isHidden = true
        }
    }

    private func installFloatAtopToggle(on window: NSWindow) {
        floatToggleButton?.removeFromSuperview()
        floatToggleContainer?.removeFromSuperview()

        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(floatToggleChanged(_:)))
        checkbox.controlSize = .small
        checkbox.state = isFloatAtopEnabled ? .on : .off
        checkbox.bezelStyle = .regularSquare
        checkbox.sizeToFit()

        let label = NSTextField(labelWithString: "float atop")
        label.font = .systemFont(ofSize: 11, weight: .light)
        label.textColor = .secondaryLabelColor
        label.backgroundColor = .clear
        label.sizeToFit()

        let container = NSView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checkbox)
        container.addSubview(label)
        let spacing: CGFloat = 6
        let checkboxXOffset: CGFloat = 2
        let contentHeight = max(checkbox.fittingSize.height, label.fittingSize.height)
        checkbox.frame = NSRect(
            x: checkboxXOffset,
            y: (contentHeight - checkbox.fittingSize.height) / 2.0,
            width: checkbox.fittingSize.width,
            height: checkbox.fittingSize.height
        )
        label.frame = NSRect(
            x: checkbox.fittingSize.width + spacing,
            y: (contentHeight - label.fittingSize.height) / 2.0,
            width: label.fittingSize.width,
            height: label.fittingSize.height
        )
        container.frame = NSRect(x: 0, y: 0, width: label.frame.maxX, height: contentHeight)

        if let closeButton = window.standardWindowButton(.closeButton),
           let titlebarView = closeButton.superview {
            titlebarView.addSubview(container)
        }
        floatToggleButton = checkbox
        floatToggleContainer = container
        updateFloatTogglePosition(for: window)
    }

    private func updateFloatTogglePosition(for window: NSWindow) {
        guard let container = floatToggleContainer,
              let closeButton = window.standardWindowButton(.closeButton),
              container.superview != nil else { return }

        let size = container.frame.size
        let x = closeButton.frame.maxX + 6
        let y = closeButton.frame.midY - (size.height / 2.0)
        container.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func applyFloatAtopState(for window: NSWindow) {
        if isFloatAtopEnabled {
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.remove(.fullScreenAuxiliary)
        }
        floatToggleButton?.state = isFloatAtopEnabled ? .on : .off
    }

    @objc
    private func floatToggleChanged(_ sender: NSButton) {
        isFloatAtopEnabled = (sender.state == .on)
        guard let window else { return }
        applyFloatAtopState(for: window)
        if isFloatAtopEnabled {
            window.orderFrontRegardless()
        }
    }

    private func positionWindowOnRight(_ window: NSWindow) {
        let frame = defaultFrame(width: max(window.frame.width, 380), height: max(window.frame.height, 560))
        window.setFrame(frame, display: true)
    }

    private func defaultFrame(width: CGFloat = 430, height: CGFloat? = nil) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h = height ?? max(560, visible.height - 24)
        let w = min(max(width, 380), 620)
        let x = visible.maxX - w - 12
        let y = visible.minY + 12
        return NSRect(x: x, y: y, width: w, height: h)
    }
}

@MainActor
private final class RetainedController {
    static let shared = RetainedController()
    var controller: AppController?
    var menuActions: MenuActions?
}

@MainActor
final class MenuActions: NSObject {
    @objc func openSettings(_ sender: Any?) {
        NotificationCenter.default.post(name: .sidekickOpenSettingsRequested, object: nil)
    }
}

@main
@MainActor
struct KeynoteSidekickMain {
    enum LaunchMode: Equatable {
        case gui
        case pipeline(prompt: String?, forceDebugLogging: Bool)
        case help
    }

    nonisolated static func parseLaunchMode(arguments: [String]) -> LaunchMode {
        var pipeline = false
        var forceDebugLogging = false
        var singlePrompt: String?

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                return .help
            case "--pipeline":
                pipeline = true
            case "--pipeline-debug":
                pipeline = true
                forceDebugLogging = true
            case "--prompt":
                if index + 1 < arguments.count {
                    singlePrompt = arguments[index + 1]
                    index += 1
                }
            default:
                if arg.hasPrefix("--prompt=") {
                    singlePrompt = String(arg.dropFirst("--prompt=".count))
                }
            }
            index += 1
        }

        if pipeline {
            return .pipeline(prompt: singlePrompt, forceDebugLogging: forceDebugLogging)
        }
        return .gui
    }

    static func main() {
        let logger = StartupLogger.shared
        logger.log("main start")
        let launchMode = parseLaunchMode(arguments: Array(ProcessInfo.processInfo.arguments.dropFirst()))

        switch launchMode {
        case .help:
            printUsage()
            return
        case .pipeline(let prompt, let forceDebugLogging):
            logger.log("starting pipeline mode")
            let code = runPipeline(prompt: prompt, forceDebugLogging: forceDebugLogging)
            exit(Int32(code))
        case .gui:
            break
        }

        let app = NSApplication.shared
        let controller = AppController()
        let menuActions = MenuActions()

        RetainedController.shared.controller = controller
        RetainedController.shared.menuActions = menuActions

        app.setActivationPolicy(.regular)
        app.delegate = controller
        app.mainMenu = buildMenu(appName: ProcessInfo.processInfo.processName, menuActions: menuActions)

        controller.configureAndShowWindow()
        logger.log("entering app.run")

        app.run()
    }

    private static func printUsage() {
        let usage = """
        Usage:
          keynote-sidekick [--pipeline [--pipeline-debug] [--prompt "<text>"]]
          keynote-sidekick --help

        Modes:
          GUI (default): starts the sidecar app window.
          Pipeline: reads prompts from STDIN and writes progress/results to STDOUT.

        Pipeline commands:
          /quit   Exit pipeline mode.
          /help   Show pipeline commands.
        """
        writeStdout(usage)
    }

    @MainActor
    private static func runPipeline(prompt: String?, forceDebugLogging: Bool) -> Int {
        let engine = LiveAutomationEngine()

        func effectiveSettings() throws -> LLMSettingsSnapshot {
            let snapshot = try AppConfigStore.shared.snapshot()
            guard forceDebugLogging else {
                return snapshot
            }
            return LLMSettingsSnapshot(
                codexPath: snapshot.codexPath,
                model: snapshot.model,
                reasoningEffort: snapshot.reasoningEffort,
                hideAgentReasoning: snapshot.hideAgentReasoning,
                modelReasoningSummary: snapshot.modelReasoningSummary,
                showRawAgentReasoning: snapshot.showRawAgentReasoning,
                systemPrompt: snapshot.systemPrompt,
                debugLoggingEnabled: true,
                reflectionBasedEditsEnabled: snapshot.reflectionBasedEditsEnabled
            )
        }

        func runSinglePrompt(_ rawPrompt: String) -> Bool {
            let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return true }

            let settings: LLMSettingsSnapshot
            do {
                settings = try effectiveSettings()
            } catch {
                writeStdout("ERROR: \(error.localizedDescription)")
                return false
            }

            writeStdout("YOU: \(prompt)")
            let outcome = engine.handle(
                input: prompt,
                settings: settings,
                onProgress: { line in
                    writeStdout("PROGRESS: \(line)")
                }
            )

            if outcome.cancelled {
                writeStdout("ERROR: Canceled.")
                return false
            }
            if outcome.success {
                writeStdout("SIDEKICK: \(outcome.reply)")
                return true
            }
            writeStdout("ERROR: \(outcome.reply)")
            return false
        }

        if let prompt {
            return runSinglePrompt(prompt) ? 0 : 1
        }

        let stdinIsTTY = isatty(STDIN_FILENO) != 0
        if stdinIsTTY {
            writeStdout("PIPELINE: ready. Enter prompt lines. /quit to exit.")
        }

        var sawInput = false
        while let line = readLine(strippingNewline: true) {
            sawInput = true
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed == "/quit" {
                return 0
            }
            if trimmed == "/help" {
                writeStdout("PIPELINE: /quit exits. Each non-empty line is sent as a prompt.")
                continue
            }
            _ = runSinglePrompt(trimmed)
        }

        if !sawInput && stdinIsTTY {
            writeStdout("PIPELINE: no input received.")
        }
        return 0
    }

    private static func writeStdout(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    private static func buildMenu(appName: String, menuActions: MenuActions) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(MenuActions.openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = menuActions
        appMenu.addItem(settings)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu

        return mainMenu
    }
}
