import Foundation
import KeynoteSidekickCore

public final class SystemEventsAXFallbackAdapter: AXFallbackAdapter {
    public init() {}

    public func setPresenterNotes(slideKey: String, text: String) throws {
        _ = slideKey
        let script = """
        tell application "Keynote" to activate
        tell application "System Events"
          tell process "Keynote"
            set frontmost to true
            try
              set candidate to first text area of front window
              set value of candidate to \(q(text))
              return "ok"
            on error
              set the clipboard to \(q(text))
              keystroke "a" using {command down}
              keystroke "v" using {command down}
              return "ok"
            end try
          end tell
        end tell
        """
        _ = try ProcessRunner.run("/usr/bin/osascript", ["-e", script])
    }

    public func setZOrder(slideKey: String, elementName: String, mode: ZOrderMode) throws {
        _ = slideKey
        _ = elementName

        let menuTitle: String
        switch mode {
        case .bringToFront: menuTitle = "Bring to Front"
        case .sendToBack: menuTitle = "Send to Back"
        case .bringForward: menuTitle = "Bring Forward"
        case .sendBackward: menuTitle = "Send Backward"
        }

        let script = """
        tell application "Keynote" to activate
        tell application "System Events"
          tell process "Keynote"
            set frontmost to true
            click menu item \(q(menuTitle)) of menu 1 of menu item "Arrange" of menu 1 of menu bar item "Format" of menu bar 1
            return "ok"
          end tell
        end tell
        """

        _ = try ProcessRunner.run("/usr/bin/osascript", ["-e", script])
    }

    private func q(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
