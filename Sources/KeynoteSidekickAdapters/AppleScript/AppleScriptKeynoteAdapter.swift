import Foundation
import CryptoKit
import KeynoteSidekickCore

private struct AdapterState: Codable {
    var presentationPath: String?
    var slideIndices: [String: Int]
    var elementAliases: [String: [String: String]]

    static let empty = AdapterState(presentationPath: nil, slideIndices: [:], elementAliases: [:])
}

public final class AppleScriptKeynoteAdapter: KeynoteAutomationAdapter {
    public let adapterName = "appleScript"
    public let defaultDriver: DriverUsed = .script

    private var state = AdapterState.empty
    private var tombstonedSlideKeys: Set<String> = []

    public init() {}

    public func openPresentation(path: String) throws {
        let script = """
        tell application "Keynote"
          open POSIX file \(q(path))
          if (count of documents) is 0 then error "No document was opened"
          try
            return POSIX path of (file of front document)
          on error
            return \(q(path))
          end try
        end tell
        """
        let openedPath = try runAppleScript(script)
        state.presentationPath = openedPath.isEmpty ? path : openedPath
        loadState()
        try resyncSlideBindingsFromDeck()
    }

    public func attachToFrontPresentation() throws {
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No front presentation"
          try
            return POSIX path of (file of front document)
          on error
            return ""
          end try
        end tell
        """
        let fallbackAttachScript = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No front presentation"
          return ""
        end tell
        """
        let path: String
        do {
            path = try runAppleScript(script)
        } catch {
            _ = try runAppleScript(fallbackAttachScript)
            path = ""
        }
        if path.isEmpty {
            state = AdapterState.empty
            tombstonedSlideKeys.removeAll()
            try resyncSlideBindingsFromDeck()
            return
        }
        state.presentationPath = path
        loadState()
        try resyncSlideBindingsFromDeck()
    }

    public func savePresentation() throws {
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          save front document
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
        persistState()
    }

    public func ensureSlide(slideKey: String, layout: String?, index: Int?, title: String?) throws {
        var existingIndex = state.slideIndices[slideKey] ?? -1
        if let hintedIndex = hintedSlideIndex(from: slideKey),
           (try? slideExists(at: hintedIndex)) == true {
            existingIndex = hintedIndex
            state.slideIndices[slideKey] = hintedIndex
            tombstonedSlideKeys.remove(slideKey)
        }
        let requestedIndex = index ?? -1
        let hasTitle = !(title ?? "").isEmpty
        let layoutName = layout ?? ""
        let normalizedLayoutName = layoutName.trimmingCharacters(in: .whitespacesAndNewlines)
        var effectiveLayoutName = layoutName
        var boundExistingSlide = false

        if existingIndex <= 0,
           requestedIndex > 0,
           hintedSlideIndex(from: slideKey) != nil {
            boundExistingSlide = try slideExists(at: requestedIndex)
            if boundExistingSlide {
                state.slideIndices[slideKey] = requestedIndex
                tombstonedSlideKeys.remove(slideKey)
                existingIndex = requestedIndex
            }
        }
        if existingIndex <= 0, normalizedLayoutName.isEmpty, requestedIndex > 0, !boundExistingSlide {
            effectiveLayoutName = "Title & Bullets"
        }
        if !normalizedLayoutName.isEmpty {
            do {
                effectiveLayoutName = try resolveMasterSlideName(for: normalizedLayoutName)
            } catch {
                // Fall back to the caller-provided label if master resolution fails.
                effectiveLayoutName = layoutName
            }
        }

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set targetIndex to \(requestedIndex)
          set existingIndex to \(existingIndex)
          set masterName to \(q(effectiveLayoutName))
          set outSlide to missing value
          set selectedMaster to missing value
          set finalIndex to -1

          if masterName is not "" then
            try
              set selectedMaster to first master slide of d whose name is masterName
            end try
          end if

          if existingIndex > 0 and existingIndex <= (count of slides of d) then
            set outSlide to slide existingIndex of d
            if selectedMaster is not missing value then
              try
                set base slide of outSlide to selectedMaster
              end try
            end if
            set finalIndex to existingIndex
          else
            if selectedMaster is missing value then set selectedMaster to first master slide of d

            if targetIndex > 0 then
              set total to count of slides of d
              if targetIndex > (total + 1) then set targetIndex to total + 1
              if total is 0 then
                set outSlide to make new slide at end of slides of d with properties {base slide:selectedMaster}
              else
                if targetIndex <= 1 then
                  set outSlide to make new slide at before slide 1 of d with properties {base slide:selectedMaster}
                else if targetIndex <= total then
                  set outSlide to make new slide at before slide targetIndex of d with properties {base slide:selectedMaster}
                else
                  set outSlide to make new slide at end of slides of d with properties {base slide:selectedMaster}
                end if
              end if
              set finalIndex to slide number of outSlide
            else
              set outSlide to make new slide at end of slides of d with properties {base slide:selectedMaster}
              set finalIndex to slide number of outSlide
            end if
          end if

          set current slide of d to outSlide
          if \(hasTitle ? "1" : "0") is 1 then
            try
              set object text of default title item of outSlide to \(q(title ?? ""))
            end try
          end if

          if finalIndex < 1 then
            set finalIndex to slide number of outSlide
          end if
          return finalIndex as text
        end tell
        """

        let output: String
        do {
            output = try runAppleScript(script)
        } catch {
            guard shouldRetryEnsureSlide(error) else { throw error }
            output = try runAppleScript(
                fallbackEnsureSlideScript(
                    index: requestedIndex,
                    hasTitle: hasTitle,
                    title: title ?? "",
                    layoutName: effectiveLayoutName
                )
            )
        }
        guard let slideIndex = Int(output) else {
            throw AdapterError(code: "PARSE_ERROR", message: "Unable to parse slide index from ensureSlide output")
        }
        let createdNewSlide = existingIndex <= 0 && !boundExistingSlide
        if createdNewSlide {
            remapSlideBindingsForInsertion(at: slideIndex)
        }
        state.slideIndices[slideKey] = slideIndex
        tombstonedSlideKeys.remove(slideKey)
        try resyncSlideBindingsFromDeck()
    }

    public func duplicateSlide(fromSlideKey: String, slideKey: String, index: Int?, title: String?) throws {
        let fromIndex = try requireSlideIndex(fromSlideKey)
        let requestedIndex = index ?? -1
        let hasTitle = !(title ?? "").isEmpty

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          if \(fromIndex) > (count of slides of d) then error "Source slide index is out of range"

          set sourceSlide to slide \(fromIndex) of d
          set targetIndex to \(requestedIndex)

          if targetIndex > 0 and targetIndex <= (count of slides of d) then
            set duplicatedSlide to duplicate sourceSlide to before slide targetIndex of d
          else
            set duplicatedSlide to duplicate sourceSlide to after last slide of d
          end if

          if \(hasTitle ? "1" : "0") is 1 then
            try
              set object text of default title item of duplicatedSlide to \(q(title ?? ""))
            end try
          end if

          set current slide of d to duplicatedSlide
          return (slide number of duplicatedSlide) as text
        end tell
        """

        let output = try runAppleScript(script)
        guard let slideIndex = Int(output) else {
            throw AdapterError(code: "PARSE_ERROR", message: "Unable to parse duplicate slide index")
        }

        remapSlideBindingsForInsertion(at: slideIndex)
        state.slideIndices[slideKey] = slideIndex
        tombstonedSlideKeys.remove(slideKey)
        try resyncSlideBindingsFromDeck()
    }

    public func deleteSlide(slideKey: String) throws {
        let index = try requireSlideIndex(slideKey)
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set total to count of slides of d
          if total <= 1 then error "Cannot delete the only slide in the presentation"
          if \(index) < 1 or \(index) > total then error "Slide index out of range"
          delete slide \(index) of d
          return "ok"
        end tell
        """

        _ = try runAppleScript(script)
        let removedKeys = removeSlideBindings(at: index)
        tombstonedSlideKeys.formUnion(removedKeys)
        tombstonedSlideKeys.insert(slideKey)
        try resyncSlideBindingsFromDeck()
    }

    public func hideSlide(slideKey: String, hidden: Bool) throws {
        let index = try requireSlideIndex(slideKey)
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set skipped of s to \(hidden ? "true" : "false")
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func moveSlide(slideKey: String, index: Int) throws {
        let fromIndex = try requireSlideIndex(slideKey)
        let requestedIndex = max(index, 1)
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set total to count of slides of d
          set fromIndex to \(fromIndex)
          set toIndex to \(requestedIndex)

          if fromIndex < 1 or fromIndex > total then error "Source slide index out of range"
          if toIndex < 1 then set toIndex to 1
          if toIndex > total then set toIndex to total

          if fromIndex is not toIndex then
            set movingSlide to slide fromIndex of d
            if toIndex = 1 then
              move movingSlide to beginning of slides of d
            else if toIndex = total then
              move movingSlide to after last slide of d
            else
              move movingSlide to before slide toIndex of d
            end if
            set current slide of d to movingSlide
            return (slide number of movingSlide) as text
          end if

          return fromIndex as text
        end tell
        """

        let output = try runAppleScript(script)
        guard let toIndex = Int(output) else {
            throw AdapterError(code: "PARSE_ERROR", message: "Unable to parse destination slide index after move")
        }
        remapSlideBindingsForMove(fromIndex: fromIndex, toIndex: toIndex)
        try resyncSlideBindingsFromDeck()
    }

    public func ensureTextBox(slideKey: String, elementName: String, text: String, frame: Frame?, role: String?) throws {
        let index = try requireSlideIndex(slideKey)
        let requestedName = elementName
        let resolvedName = resolveElementName(slideKey: slideKey, elementName: requestedName)
        let resolvedRole = roleFromAlias(resolvedName)
        let normalizedRole = normalizeTextRole(role)
        let roleHint = normalizedRole.isEmpty ? (resolvedRole ?? "") : normalizedRole
        let lookupName = resolvedRole == nil ? resolvedName : requestedName
        let frameScript = frameSetter(frame)
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(lookupName))
          set textValue to \(q(text))
          set roleHint to \(q(roleHint))
          set target to missing value
          set roleAlias to ""
          set effectiveName to itemName

          if roleHint is "title" then
            try
              set target to default title item of s
              set roleAlias to \(q(roleAlias(for: "title")))
            end try
          else if roleHint is "body" then
            try
              set target to default body item of s
              set roleAlias to \(q(roleAlias(for: "body")))
            end try
          end if

          try
            if target is missing value then
              set target to first text item of s whose name is itemName
            end if
          end try

          if target is missing value then
            set target to make new text item at end of text items of s
          end if

          try
            try
              set name of target to itemName
              set effectiveName to itemName
            on error
              if roleAlias is not "" then
                set effectiveName to roleAlias
              else
                try
                  set effectiveName to (name of target as text)
                on error
                  set effectiveName to itemName
                end try
              end if
            end try
          on error
            if roleAlias is not "" then
              set effectiveName to roleAlias
            else
              set effectiveName to itemName
            end if
          end try

          try
            set object text of target to textValue
          on error
            set object text of target to (textValue as text)
          end try
          \(frameScript)
          return effectiveName
        end tell
        """
        do {
            let boundName = try runAppleScript(script)
            bindElementAlias(
                slideKey: slideKey,
                requestedName: requestedName,
                resolvedName: resolvedName,
                boundName: boundName
            )
        } catch {
            guard isTransientAppleEventFailure(error) else { throw error }
            let boundName = try runAppleScript(
                fallbackEnsureTextScript(
                    index: index,
                    itemName: lookupName,
                    text: text,
                    roleHint: roleHint,
                    frameScript: frameScript
                )
            )
            bindElementAlias(
                slideKey: slideKey,
                requestedName: requestedName,
                resolvedName: resolvedName,
                boundName: boundName
            )
        }
    }

    public func ensureBullets(slideKey: String, elementName: String, items: [String], frame: Frame?) throws {
        let bulletText = items.joined(separator: "\n")
        try ensureTextBox(slideKey: slideKey, elementName: elementName, text: bulletText, frame: frame, role: "body")
    }

    public func ensureImage(slideKey: String, elementName: String, path: String, frame: Frame?) throws {
        let index = try requireSlideIndex(slideKey)
        let actualName = resolveElementName(slideKey: slideKey, elementName: elementName)
        let frameScript = frameSetter(frame)

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(actualName))
          set imagePath to \(q(path))
          set target to missing value

          try
            set target to first image of s whose name is itemName
          end try

          if target is missing value then
            set target to make new image at s with properties {file name:POSIX file imagePath}
            try
              set name of target to itemName
            end try
          else
            try
              set file name of target to POSIX file imagePath
            end try
          end if

          \(frameScript)
          return "ok"
        end tell
        """

        _ = try runAppleScript(script)
    }

    public func ensureShape(slideKey: String, elementName: String, shapeType: String?, text: String?, frame: Frame?) throws {
        _ = shapeType
        let index = try requireSlideIndex(slideKey)
        let requestedName = elementName
        let resolvedName = resolveElementName(slideKey: slideKey, elementName: requestedName)
        let frameScript = frameSetter(frame)

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(resolvedName))
          set textValue to \(q(text ?? ""))
          set target to missing value
          set effectiveName to itemName

          try
            set target to first shape of s whose name is itemName
          end try

          if target is missing value then
            set target to make new shape at s
          end if

          try
            set name of target to itemName
            set effectiveName to itemName
          on error
            try
              set effectiveName to (name of target as text)
            on error
              set effectiveName to itemName
            end try
          end try

          if textValue is not "" then
            try
              set object text of target to textValue
            end try
          end if

          \(frameScript)
          return effectiveName
        end tell
        """

        let boundName = try runAppleScript(script)
        bindElementAlias(
            slideKey: slideKey,
            requestedName: requestedName,
            resolvedName: resolvedName,
            boundName: boundName
        )
    }

    public func deleteElement(slideKey: String, elementName: String) throws {
        let index = try requireSlideIndex(slideKey)
        let actualName = resolveElementName(slideKey: slideKey, elementName: elementName)
        if let selectedOrdinal = selectedElementOrdinal(from: actualName) {
            let script = """
            tell application "Keynote"
              if (count of documents) is 0 then error "No open presentation"
              set d to front document
              set s to slide \(index) of d
              set selectedItems to {}
              try
                set selectedItems to selection of d
              end try
              if (count of selectedItems) is 0 then error "No selected elements"

              set nonSlideItems to {}
              repeat with candidate in selectedItems
                try
                  if class of candidate is not slide then
                    set end of nonSlideItems to candidate
                  end if
                end try
              end repeat

              if (count of nonSlideItems) < \(selectedOrdinal) then error "Selected element index out of range"
              set target to item \(selectedOrdinal) of nonSlideItems
              delete target
              return "ok"
            end tell
            """
            _ = try runAppleScript(script)
            return
        }

        let roleHint = normalizeTextRole(elementName)
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(actualName))
          set roleValue to \(q(roleHint))
          set target to missing value

          if roleValue is "title" then
            try
              set target to default title item of s
            end try
          else if roleValue is "body" then
            try
              set target to default body item of s
            end try
          end if

          try
            if target is missing value then
              set target to first text item of s whose name is itemName
            end if
          end try
          if target is missing value then
            try
              set target to first image of s whose name is itemName
            end try
          end if
          if target is missing value then
            try
              set target to first shape of s whose name is itemName
            end try
          end if

          if target is missing value then error "Element not found"

          delete target
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
        removeElementAliases(slideKey: slideKey, requestedName: elementName, resolvedName: actualName)
    }

    public func setFrame(slideKey: String, elementName: String, frame: Frame) throws {
        let index = try requireSlideIndex(slideKey)
        let actualName = resolveElementName(slideKey: slideKey, elementName: elementName)
        let frameScript = frameSetter(frame)

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(actualName))
          set target to missing value

          try
            set target to first text item of s whose name is itemName
          end try
          if target is missing value then
            try
              set target to first image of s whose name is itemName
            end try
          end if
          if target is missing value then
            try
              set target to first shape of s whose name is itemName
            end try
          end if

          if target is missing value then error "Element not found"

          \(frameScript)
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func setOpacity(slideKey: String, elementName: String, opacity: Double) throws {
        let index = try requireSlideIndex(slideKey)
        let actualName = resolveElementName(slideKey: slideKey, elementName: elementName)
        let clampedOpacity = max(0, min(100, opacity))

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(actualName))
          set target to missing value

          try
            set target to first text item of s whose name is itemName
          end try
          if target is missing value then
            try
              set target to first image of s whose name is itemName
            end try
          end if
          if target is missing value then
            try
              set target to first shape of s whose name is itemName
            end try
          end if

          if target is missing value then error "Element not found"

          set opacity of target to \(clampedOpacity)
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func setZOrder(slideKey: String, elementName: String, mode: ZOrderMode) throws {
        _ = slideKey
        _ = elementName
        _ = mode
        throw AdapterError(code: "UNSUPPORTED_ZORDER", message: "AppleScript z-order is not reliable in all Keynote versions")
    }

    public func setPresenterNotes(slideKey: String, text: String) throws {
        let index = try requireSlideIndex(slideKey)
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set presenter notes of s to \(q(text))
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func setTextStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        let index = try requireSlideIndex(slideKey)
        let actualName = resolveElementName(slideKey: slideKey, elementName: elementName)
        let roleHint = roleFromAlias(actualName) ?? roleFromAlias(elementName) ?? ""
        let fontName = styleString(style, keys: ["fontName", "font"])
        let fontSize = styleDouble(style, keys: ["fontSize", "size"]) ?? 0
        let bold = styleBool(style, keys: ["bold"])
        let italic = styleBool(style, keys: ["italic"])
        let underline = styleBool(style, keys: ["underline", "underlined"])
        let color = styleColor(style, keys: ["color", "textColor"])
        let hasColor = color != nil
        let red = color?.0 ?? 0
        let green = color?.1 ?? 0
        let blue = color?.2 ?? 0

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(actualName))
          set roleValue to \(q(roleHint))
          set target to missing value

          if roleValue is "title" then
            try
              set target to default title item of s
            end try
          else if roleValue is "body" then
            try
              set target to default body item of s
            end try
          end if

          try
            if target is missing value then
              set target to first text item of s whose name is itemName
            end if
          end try
          if target is missing value then error "Element not found"

          set textRef to object text of target
          if \(q(fontName)) is not "" then
            try
              set font of textRef to \(q(fontName))
            end try
          end if
          if \(fontSize) > 0 then
            try
              set size of textRef to \(fontSize)
            end try
          end if
          \(scriptBoolSet(enabled: bold != nil, property: "bold", value: bold ?? false, objectRef: "textRef"))
          \(scriptBoolSet(enabled: italic != nil, property: "italic", value: italic ?? false, objectRef: "textRef"))
          \(scriptBoolSet(enabled: underline != nil, property: "underlined", value: underline ?? false, objectRef: "textRef"))
          if \(hasColor ? "1" : "0") is 1 then
            try
              set color of textRef to {\(red), \(green), \(blue)}
            end try
          end if
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func setParagraphStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        let index = try requireSlideIndex(slideKey)
        let actualName = resolveElementName(slideKey: slideKey, elementName: elementName)
        let roleHint = roleFromAlias(actualName) ?? roleFromAlias(elementName) ?? ""
        let alignmentRaw = styleString(style, keys: ["alignment", "textAlign"]).lowercased()
        let alignmentToken = paragraphAlignmentToken(from: alignmentRaw)

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(actualName))
          set roleValue to \(q(roleHint))
          set target to missing value

          if roleValue is "title" then
            try
              set target to default title item of s
            end try
          else if roleValue is "body" then
            try
              set target to default body item of s
            end try
          end if

          try
            if target is missing value then
              set target to first text item of s whose name is itemName
            end if
          end try
          if target is missing value then error "Element not found"

          set textRef to object text of target
          if \(q(alignmentToken)) is not "" then
            repeat with p in paragraphs of textRef
              try
                if \(q(alignmentToken)) is "left" then
                  set alignment of p to left
                else if \(q(alignmentToken)) is "center" then
                  set alignment of p to center
                else if \(q(alignmentToken)) is "right" then
                  set alignment of p to right
                else if \(q(alignmentToken)) is "justified" then
                  set alignment of p to justified
                end if
              end try
            end repeat
          end if

          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func setFillStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        _ = try element(slideKey: slideKey, elementName: elementName)
        if let opacity = styleDouble(style, keys: ["opacity", "alpha"]) {
            try setOpacity(slideKey: slideKey, elementName: elementName, opacity: opacity)
        }
    }

    public func setStrokeStyle(slideKey: String, elementName: String, style: [String: JSONValue]) throws {
        _ = try element(slideKey: slideKey, elementName: elementName)
        if let opacity = styleDouble(style, keys: ["opacity", "alpha"]) {
            try setOpacity(slideKey: slideKey, elementName: elementName, opacity: opacity)
        }
    }

    public func alignElements(slideKey: String, elementNames: [String], alignment: String, useSelection: Bool) throws {
        if useSelection {
            try alignSelection(slideKey: slideKey, alignment: alignment)
            return
        }
        try alignNamedElements(slideKey: slideKey, elementNames: elementNames, alignment: alignment)
    }

    public func distributeElements(slideKey: String, elementNames: [String], axis: String, spacing: Double?, useSelection: Bool) throws {
        if useSelection {
            try distributeSelection(slideKey: slideKey, axis: axis, spacing: spacing)
            return
        }
        try distributeNamedElements(slideKey: slideKey, elementNames: elementNames, axis: axis, spacing: spacing)
    }

    public func isPresentationOpen() throws -> Bool {
        let script = """
        tell application "Keynote"
          if (count of documents) > 0 then
            return "1"
          else
            return "0"
          end if
        end tell
        """
        return try runAppleScript(script) == "1"
    }

    public func slideExists(slideKey: String) throws -> Bool {
        if tombstonedSlideKeys.contains(slideKey) {
            try? resyncSlideBindingsFromDeck()
            if state.slideIndices[slideKey] != nil {
                tombstonedSlideKeys.remove(slideKey)
                persistState()
            } else {
                return false
            }
        }

        if state.slideIndices[slideKey] == nil {
            try? resyncSlideBindingsFromDeck()
        }

        if let index = state.slideIndices[slideKey] {
            let script = """
            tell application "Keynote"
              if (count of documents) is 0 then return "0"
              set d to front document
              if \(index) <= (count of slides of d) then
                return "1"
              else
                return "0"
              end if
            end tell
            """
            return try runAppleScript(script) == "1"
        }

        if let hintedIndex = hintedSlideIndex(from: slideKey), try slideExists(at: hintedIndex) {
            state.slideIndices[slideKey] = hintedIndex
            persistState()
            return true
        }

        return false
    }

    public func element(slideKey: String, elementName: String) throws -> SlideElementSnapshot? {
        let index = try requireSlideIndex(slideKey)
        let actualName = resolveElementName(slideKey: slideKey, elementName: elementName)
        let roleHint = roleFromAlias(actualName) ?? roleFromAlias(elementName) ?? ""
        let separator = String(UnicodeScalar(31)!)

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then return ""
          set d to front document
          set s to slide \(index) of d
          set itemName to \(q(actualName))
          set roleHint to \(q(roleHint))
          set sep to ASCII character 31

          if roleHint is "title" then
            try
              set target to default title item of s
              set p to position of target
              set t to (object text of target as text)
              set c to count of paragraphs of t
              return "text" & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & t & sep & (c as text)
            end try
          else if roleHint is "body" then
            try
              set target to default body item of s
              set p to position of target
              set t to (object text of target as text)
              set c to count of paragraphs of t
              return "text" & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & t & sep & (c as text)
            end try
          end if

          try
            set target to first text item of s whose name is itemName
            set p to position of target
            set t to (object text of target as text)
            set c to count of paragraphs of t
            return "text" & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & t & sep & (c as text)
          end try

          try
            set target to first image of s whose name is itemName
            set p to position of target
            return "image" & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & "" & sep & "0"
          end try

          try
            set target to first shape of s whose name is itemName
            set p to position of target
            return "shape" & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & "" & sep & "0"
          end try

          return ""
        end tell
        """

        let output = try runAppleScript(script)
        if output.isEmpty { return nil }

        let parts = output.components(separatedBy: separator)
        guard parts.count >= 7 else {
            throw AdapterError(code: "PARSE_ERROR", message: "Unexpected element payload")
        }

        let type = SlideElementType(rawValue: parts[0]) ?? .unknown
        guard let x = Double(parts[1]), let y = Double(parts[2]), let w = Double(parts[3]), let h = Double(parts[4]) else {
            throw AdapterError(code: "PARSE_ERROR", message: "Invalid frame payload")
        }

        let frame = Frame(x: x, y: y, width: w, height: h)
        let text = parts[5].isEmpty ? nil : parts[5]
        let bulletCount = Int(parts[6])

        return SlideElementSnapshot(name: elementName, type: type, frame: frame, text: text, bulletCount: bulletCount)
    }

    public func presenterNotes(slideKey: String) throws -> String? {
        let index = try requireSlideIndex(slideKey)
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then return ""
          set d to front document
          set s to slide \(index) of d
          try
            return (presenter notes of s as text)
          on error
            return ""
          end try
        end tell
        """

        let output = try runAppleScript(script)
        return output.isEmpty ? nil : output
    }

    public func knownSlideBindings() throws -> [String: Int] {
        if try isPresentationOpen() {
            try resyncSlideBindingsFromDeck()
        }
        return state.slideIndices
    }

    public func refreshSlideBindings() throws -> [String: Int] {
        try resyncSlideBindingsFromDeck()
        return state.slideIndices
    }

    public func enumerateSlideElements(slideKey: String) throws -> [SlideElementDescriptor] {
        let index = try requireSlideIndex(slideKey)
        let sep = String(UnicodeScalar(31)!)

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then return ""
          set d to front document
          set s to slide \(index) of d
          set sep to ASCII character 31
          set outLines to {}

          repeat with target in every text item of s
            set n to ""
            try
              set n to name of target
            end try
            set p to position of target
            set t to (object text of target as text)
            if (count of characters of t) > 80 then set t to text 1 thru 80 of t
            set end of outLines to "text" & sep & n & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & t
          end repeat

          repeat with target in every image of s
            set n to ""
            try
              set n to name of target
            end try
            set p to position of target
            set end of outLines to "image" & sep & n & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & ""
          end repeat

          repeat with target in every shape of s
            set n to ""
            try
              set n to name of target
            end try
            set p to position of target
            set end of outLines to "shape" & sep & n & sep & (item 1 of p as text) & sep & (item 2 of p as text) & sep & (width of target as text) & sep & (height of target as text) & sep & ""
          end repeat

          set AppleScript's text item delimiters to linefeed
          set payload to outLines as text
          set AppleScript's text item delimiters to ""
          return payload
        end tell
        """

        let output = try runAppleScript(script)
        if output.isEmpty { return [] }

        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let parts = line.components(separatedBy: sep)
                guard parts.count >= 7 else { return nil }
                guard let x = Double(parts[2]), let y = Double(parts[3]), let w = Double(parts[4]), let h = Double(parts[5]) else { return nil }
                return SlideElementDescriptor(
                    name: parts[1].isEmpty ? nil : parts[1],
                    type: SlideElementType(rawValue: parts[0]) ?? .unknown,
                    frame: Frame(x: x, y: y, width: w, height: h),
                    textSnippet: parts[6].isEmpty ? nil : parts[6]
                )
            }
    }

    public func applyResyncBindings(slideKey: String, matches: [ResyncMatch]) throws {
        var aliases = state.elementAliases[slideKey] ?? [:]
        for match in matches {
            guard let actualName = match.element.name else { continue }
            aliases[match.target.elementName] = actualName
        }
        state.elementAliases[slideKey] = aliases
        persistState()
    }

    public func recoverAfterError() throws {
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No front presentation"
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    public func deckDigest() throws -> String {
        struct DigestSlide: Codable {
            let slideKey: String
            let notes: String?
            let elements: [SlideElementDescriptor]
        }

        let sortedKeys = state.slideIndices.keys.sorted()
        let digestSlides: [DigestSlide] = try sortedKeys.map { key in
            DigestSlide(
                slideKey: key,
                notes: try presenterNotes(slideKey: key),
                elements: try enumerateSlideElements(slideKey: key).sorted { ($0.name ?? "") < ($1.name ?? "") }
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(digestSlides)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func alignNamedElements(slideKey: String, elementNames: [String], alignment: String) throws {
        let uniqueNames = Array(Set(elementNames)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard uniqueNames.count >= 2 else {
            throw AdapterError(code: "ALIGNMENT_INPUT", message: "alignElements requires at least two elements")
        }
        let normalized = alignment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var frames: [(name: String, frame: Frame)] = []
        for name in uniqueNames {
            guard let snapshot = try element(slideKey: slideKey, elementName: name), let frame = snapshot.frame else {
                throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(name) not found or has no frame")
            }
            frames.append((name, frame))
        }

        let minX = frames.map { $0.frame.x }.min() ?? 0
        let maxX = frames.map { $0.frame.x + $0.frame.width }.max() ?? 0
        let minY = frames.map { $0.frame.y }.min() ?? 0
        let maxY = frames.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        for item in frames {
            var updated = item.frame
            switch normalized {
            case "left", "leading":
                updated.x = minX
            case "center", "centerx", "horizontalcenter":
                updated.x = centerX - (item.frame.width / 2)
            case "right", "trailing":
                updated.x = maxX - item.frame.width
            case "top":
                updated.y = minY
            case "middle", "centery", "verticalcenter":
                updated.y = centerY - (item.frame.height / 2)
            case "bottom":
                updated.y = maxY - item.frame.height
            default:
                throw AdapterError(code: "ALIGNMENT_MODE", message: "Unsupported alignment \(alignment)")
            }
            try setFrame(slideKey: slideKey, elementName: item.name, frame: updated)
        }
    }

    private func distributeNamedElements(slideKey: String, elementNames: [String], axis: String, spacing: Double?) throws {
        let uniqueNames = Array(Set(elementNames)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard uniqueNames.count >= 3 else {
            throw AdapterError(code: "DISTRIBUTE_INPUT", message: "distributeElements requires at least three elements")
        }
        let normalizedAxis = axis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var frames: [(name: String, frame: Frame)] = []
        for name in uniqueNames {
            guard let snapshot = try element(slideKey: slideKey, elementName: name), let frame = snapshot.frame else {
                throw AdapterError(code: "MISSING_ELEMENT", message: "Element \(name) not found or has no frame")
            }
            frames.append((name, frame))
        }

        switch normalizedAxis {
        case "horizontal", "x":
            frames.sort { $0.frame.x < $1.frame.x }
            let totalMiddleWidth = frames.dropFirst().dropLast().reduce(0.0) { $0 + $1.frame.width }
            let start = frames.first!.frame.x
            let firstWidth = frames.first!.frame.width
            let end = frames.last!.frame.x + frames.last!.frame.width
            let gap = spacing ?? ((end - start - firstWidth - totalMiddleWidth - frames.last!.frame.width) / Double(frames.count - 1))
            var cursor = start + firstWidth + gap
            for idx in 1..<(frames.count - 1) {
                let name = frames[idx].name
                var frame = frames[idx].frame
                frame.x = cursor
                cursor += frame.width + gap
                try setFrame(slideKey: slideKey, elementName: name, frame: frame)
            }
        case "vertical", "y":
            frames.sort { $0.frame.y < $1.frame.y }
            let totalMiddleHeight = frames.dropFirst().dropLast().reduce(0.0) { $0 + $1.frame.height }
            let start = frames.first!.frame.y
            let firstHeight = frames.first!.frame.height
            let end = frames.last!.frame.y + frames.last!.frame.height
            let gap = spacing ?? ((end - start - firstHeight - totalMiddleHeight - frames.last!.frame.height) / Double(frames.count - 1))
            var cursor = start + firstHeight + gap
            for idx in 1..<(frames.count - 1) {
                let name = frames[idx].name
                var frame = frames[idx].frame
                frame.y = cursor
                cursor += frame.height + gap
                try setFrame(slideKey: slideKey, elementName: name, frame: frame)
            }
        default:
            throw AdapterError(code: "DISTRIBUTE_AXIS", message: "Unsupported distribute axis \(axis)")
        }
    }

    private func alignSelection(slideKey: String, alignment: String) throws {
        let index = try requireSlideIndex(slideKey)
        let normalized = alignment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set selectedItems to {}
          try
            set selectedItems to selection of d
          end try
          if (count of selectedItems) < 2 then error "Need at least two selected items"

          set minX to 9999999
          set maxX to -9999999
          set minY to 9999999
          set maxY to -9999999

          repeat with target in selectedItems
            set p to position of target
            set px to item 1 of p
            set py to item 2 of p
            set pw to width of target
            set ph to height of target
            if px < minX then set minX to px
            if py < minY then set minY to py
            if (px + pw) > maxX then set maxX to (px + pw)
            if (py + ph) > maxY then set maxY to (py + ph)
          end repeat

          set centerX to (minX + maxX) / 2
          set centerY to (minY + maxY) / 2

          repeat with target in selectedItems
            set p to position of target
            set px to item 1 of p
            set py to item 2 of p
            set pw to width of target
            set ph to height of target
            set newX to px
            set newY to py

            if \(q(normalized)) is "left" or \(q(normalized)) is "leading" then
              set newX to minX
            else if \(q(normalized)) is "center" or \(q(normalized)) is "centerx" or \(q(normalized)) is "horizontalcenter" then
              set newX to centerX - (pw / 2)
            else if \(q(normalized)) is "right" or \(q(normalized)) is "trailing" then
              set newX to maxX - pw
            else if \(q(normalized)) is "top" then
              set newY to minY
            else if \(q(normalized)) is "middle" or \(q(normalized)) is "centery" or \(q(normalized)) is "verticalcenter" then
              set newY to centerY - (ph / 2)
            else if \(q(normalized)) is "bottom" then
              set newY to maxY - ph
            else
              error "Unsupported alignment \(alignment)"
            end if

            set position of target to {newX, newY}
          end repeat

          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func distributeSelection(slideKey: String, axis: String, spacing: Double?) throws {
        let index = try requireSlideIndex(slideKey)
        let normalizedAxis = axis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let spacingValue = spacing ?? -1
        let script = """
        on sortByAxis(itemRows, axisName)
          set sortedRows to itemRows
          set n to count of sortedRows
          if n < 2 then return sortedRows
          repeat with i from 1 to (n - 1)
            repeat with j from 1 to (n - i)
              set leftRow to item j of sortedRows
              set rightRow to item (j + 1) of sortedRows
              set leftFrame to item 2 of leftRow
              set rightFrame to item 2 of rightRow
              set leftPos to item 1 of leftFrame
              set rightPos to item 1 of rightFrame
              if axisName is "vertical" then
                set leftPos to item 2 of leftFrame
                set rightPos to item 2 of rightFrame
              end if
              if leftPos > rightPos then
                set item j of sortedRows to rightRow
                set item (j + 1) of sortedRows to leftRow
              end if
            end repeat
          end repeat
          return sortedRows
        end sortByAxis

        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set selectedItems to {}
          try
            set selectedItems to selection of d
          end try
          if (count of selectedItems) < 3 then error "Need at least three selected items"

          set rows to {}
          repeat with target in selectedItems
            set p to position of target
            set px to item 1 of p
            set py to item 2 of p
            set pw to width of target
            set ph to height of target
            set end of rows to {target, {px, py, pw, ph}}
          end repeat

          set axisName to \(q(normalizedAxis))
          if axisName is "x" then set axisName to "horizontal"
          if axisName is "y" then set axisName to "vertical"
          if axisName is not "horizontal" and axisName is not "vertical" then error "Unsupported distribute axis \(axis)"

          set rows to my sortByAxis(rows, axisName)
          set total to count of rows
          set firstFrame to item 2 of item 1 of rows
          set lastFrame to item 2 of item total of rows

          if axisName is "horizontal" then
            set startPos to item 1 of firstFrame
            set endPos to (item 1 of lastFrame) + (item 3 of lastFrame)
            set interiorSize to 0
            repeat with i from 2 to (total - 1)
              set interiorSize to interiorSize + (item 3 of item 2 of item i of rows)
            end repeat
            set edgeFirst to item 3 of firstFrame
            set edgeLast to item 3 of lastFrame
          else
            set startPos to item 2 of firstFrame
            set endPos to (item 2 of lastFrame) + (item 4 of lastFrame)
            set interiorSize to 0
            repeat with i from 2 to (total - 1)
              set interiorSize to interiorSize + (item 4 of item 2 of item i of rows)
            end repeat
            set edgeFirst to item 4 of firstFrame
            set edgeLast to item 4 of lastFrame
          end if

          if \(spacingValue) >= 0 then
            set gap to \(spacingValue)
          else
            set gap to (endPos - startPos - edgeFirst - interiorSize - edgeLast) / (total - 1)
          end if

          set cursor to startPos + edgeFirst + gap
          repeat with i from 2 to (total - 1)
            set rowItem to item i of rows
            set target to item 1 of rowItem
            set frameItem to item 2 of rowItem
            set px to item 1 of frameItem
            set py to item 2 of frameItem
            set pw to item 3 of frameItem
            set ph to item 4 of frameItem
            if axisName is "horizontal" then
              set position of target to {cursor, py}
              set cursor to cursor + pw + gap
            else
              set position of target to {px, cursor}
              set cursor to cursor + ph + gap
            end if
          end repeat
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func styleString(_ style: [String: JSONValue], keys: [String]) -> String {
        for key in keys {
            if let value = style[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private func styleDouble(_ style: [String: JSONValue], keys: [String]) -> Double? {
        for key in keys {
            if let value = style[key]?.doubleValue {
                return value
            }
            if let text = style[key]?.stringValue, let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    private func styleBool(_ style: [String: JSONValue], keys: [String]) -> Bool? {
        for key in keys {
            if let value = style[key]?.boolValue {
                return value
            }
            if let text = style[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if text == "true" || text == "yes" || text == "1" {
                    return true
                }
                if text == "false" || text == "no" || text == "0" {
                    return false
                }
            }
        }
        return nil
    }

    private func styleColor(_ style: [String: JSONValue], keys: [String]) -> (Int, Int, Int)? {
        for key in keys {
            guard let raw = style[key] else { continue }
            if let parsed = parseColor(raw) {
                return parsed
            }
        }
        return nil
    }

    private func parseColor(_ value: JSONValue) -> (Int, Int, Int)? {
        var components: [Double] = []
        if let array = value.arrayValue {
            components = array.compactMap { $0.doubleValue ?? ($0.stringValue.flatMap(Double.init)) }
        } else if let object = value.objectValue {
            let r = object["r"]?.doubleValue ?? object["red"]?.doubleValue
            let g = object["g"]?.doubleValue ?? object["green"]?.doubleValue
            let b = object["b"]?.doubleValue ?? object["blue"]?.doubleValue
            if let r, let g, let b {
                components = [r, g, b]
            }
        }
        guard components.count >= 3 else { return nil }
        return (
            normalizedColorComponent(components[0]),
            normalizedColorComponent(components[1]),
            normalizedColorComponent(components[2])
        )
    }

    private func normalizedColorComponent(_ value: Double) -> Int {
        if value <= 1.0 {
            return Int(max(0, min(65535, (value * 65535.0).rounded())))
        }
        if value <= 255.0 {
            return Int(max(0, min(65535, ((value / 255.0) * 65535.0).rounded())))
        }
        return Int(max(0, min(65535, value.rounded())))
    }

    private func paragraphAlignmentToken(from raw: String) -> String {
        switch raw {
        case "left", "leading":
            return "left"
        case "center", "middle":
            return "center"
        case "right", "trailing":
            return "right"
        case "justified", "justify":
            return "justified"
        default:
            return ""
        }
    }

    private func scriptBoolSet(enabled: Bool, property: String, value: Bool, objectRef: String) -> String {
        guard enabled else { return "" }
        return """
          try
            set \(property) of \(objectRef) to \(value ? "true" : "false")
          end try
        """
    }

    private func runAppleScript(_ script: String) throws -> String {
        try ProcessRunner.run("/usr/bin/osascript", ["-e", script])
    }

    private func q(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func frameSetter(_ frame: Frame?) -> String {
        guard let frame else { return "" }
        return "set position of target to {\(frame.x), \(frame.y)}\n          set width of target to \(frame.width)\n          set height of target to \(frame.height)"
    }

    private func fallbackEnsureSlideScript(index: Int, hasTitle: Bool, title: String, layoutName: String) -> String {
        """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set targetIndex to \(index)
          set masterName to \(q(layoutName))
          set total to count of slides of d
          set outSlide to missing value
          set selectedMaster to missing value
          set finalIndex to -1

          if masterName is not "" then
            try
              set selectedMaster to first master slide of d whose name is masterName
            end try
          end if
          if selectedMaster is missing value then
            try
              set selectedMaster to first master slide of d
            end try
          end if

          if total is 0 then
            if selectedMaster is missing value then
              set outSlide to make new slide at end of slides of d
            else
              set outSlide to make new slide at end of slides of d with properties {base slide:selectedMaster}
            end if
          else
            if targetIndex < 1 then set targetIndex to total + 1
            if targetIndex > (total + 1) then set targetIndex to total + 1

            if targetIndex <= 1 then
              if selectedMaster is missing value then
                set outSlide to make new slide at before slide 1 of d
              else
                set outSlide to make new slide at before slide 1 of d with properties {base slide:selectedMaster}
              end if
            else if targetIndex <= total then
              if selectedMaster is missing value then
                set outSlide to make new slide at before slide targetIndex of d
              else
                set outSlide to make new slide at before slide targetIndex of d with properties {base slide:selectedMaster}
              end if
            else
              if selectedMaster is missing value then
                set outSlide to make new slide at end of slides of d
              else
                set outSlide to make new slide at end of slides of d with properties {base slide:selectedMaster}
              end if
            end if
          end if
          set finalIndex to slide number of outSlide

          try
            set current slide of d to outSlide
          end try

          if \(hasTitle ? "1" : "0") is 1 then
            try
              set object text of default title item of outSlide to \(q(title))
            on error
              try
                set object text of first text item of outSlide to \(q(title))
              end try
            end try
          end if

          if finalIndex < 1 then
            set finalIndex to slide number of outSlide
          end if
          return finalIndex as text
        end tell
        """
    }

    private func resolveMasterSlideName(for requestedLayout: String) throws -> String {
        let trimmed = requestedLayout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return requestedLayout }

        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set requestedName to \(q(trimmed))
          set selectedName to ""
          set wantsTitle to false
          set wantsBullets to false

          try
            set selectedName to (name of (first master slide of d whose name is requestedName)) as text
          end try

          if selectedName is "" then
            ignoring case
              if requestedName contains "title" then set wantsTitle to true
              if requestedName contains "bullet" or requestedName contains "body" then set wantsBullets to true
            end ignoring

            if wantsTitle is true and wantsBullets is false then
              repeat with masterRef in master slides of d
                set candidateName to (name of masterRef) as text
                ignoring case
                  if candidateName contains "title" and candidateName does not contain "bullet" and candidateName does not contain "body" then
                    set selectedName to candidateName
                    exit repeat
                  end if
                end ignoring
              end repeat
            else if wantsBullets is true then
              repeat with masterRef in master slides of d
                set candidateName to (name of masterRef) as text
                ignoring case
                  if candidateName contains "bullet" or candidateName contains "body" then
                    set selectedName to candidateName
                    exit repeat
                  end if
                end ignoring
              end repeat
            end if
          end if

          if selectedName is "" then
            repeat with masterRef in master slides of d
              set candidateName to (name of masterRef) as text
              ignoring case
                if candidateName contains requestedName then
                  set selectedName to candidateName
                  exit repeat
                end if
              end ignoring
            end repeat
          end if

          if selectedName is "" then
            set selectedName to (name of first master slide of d) as text
          end if

          return selectedName
        end tell
        """

        return try runAppleScript(script)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedElementOrdinal(from elementName: String) -> Int? {
        let token = elementName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if token == "__ksk_selected__" || token == "selected" {
            return 1
        }

        let patterns = [
            #"^__ksk_selected__(?:__)?(\d+)$"#,
            #"^selected_(\d+)$"#,
            #"^selected(\d+)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let range = NSRange(token.startIndex..<token.endIndex, in: token)
            guard let match = regex.firstMatch(in: token, options: [], range: range),
                  match.numberOfRanges > 1,
                  let indexRange = Range(match.range(at: 1), in: token),
                  let index = Int(token[indexRange]),
                  index > 0 else {
                continue
            }
            return index
        }

        return nil
    }

    private func fallbackEnsureTextScript(index: Int, itemName: String, text: String, roleHint: String, frameScript: String) -> String {
        """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set s to slide \(index) of d
          set roleValue to \(q(roleHint))
          set target to missing value
          set roleAlias to ""
          set effectiveName to \(q(itemName))

          if roleValue is "title" then
            try
              set target to default title item of s
              set roleAlias to \(q(roleAlias(for: "title")))
            end try
          else if roleValue is "body" then
            try
              set target to default body item of s
              set roleAlias to \(q(roleAlias(for: "body")))
            end try
          end if

          try
            if target is missing value then
              set target to first text item of s whose name is \(q(itemName))
            end if
          end try

          if target is missing value then
            set target to make new text item at end of text items of s
          end if

          try
            set name of target to \(q(itemName))
            set effectiveName to \(q(itemName))
          on error
            if roleAlias is not "" then
              set effectiveName to roleAlias
            else
              try
                set effectiveName to (name of target as text)
              on error
                set effectiveName to \(q(itemName))
              end try
            end if
          end try

          try
            set object text of target to \(q(text))
          on error
            set object text of target to (\(q(text)) as text)
          end try
          \(frameScript)
          return effectiveName
        end tell
        """
    }

    private func isTransientAppleEventFailure(_ error: Error) -> Bool {
        guard let adapterError = error as? AdapterError else { return false }
        let message = adapterError.message.lowercased()
        return message.contains("appleevent handler failed") || message.contains("(-10000)")
    }

    private func shouldRetryEnsureSlide(_ error: Error) -> Bool {
        if isTransientAppleEventFailure(error) {
            return true
        }
        guard let adapterError = error as? AdapterError else { return false }
        let message = adapterError.message.lowercased()
        if message.contains("(-1700)") {
            return true
        }
        if message.contains("can't make slide before slide") {
            return true
        }
        if message.contains("into type type") {
            return true
        }
        return false
    }

    private func slideExists(at index: Int) throws -> Bool {
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          if \(index) > 0 and \(index) <= (count of slides of d) then
            return "1"
          end if
          return "0"
        end tell
        """
        return try runAppleScript(script) == "1"
    }

    private func slideCount() throws -> Int {
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          return (count of slides of d) as text
        end tell
        """
        let output = try runAppleScript(script)
        guard let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AdapterError(code: "PARSE_ERROR", message: "Unable to parse slide count")
        }
        return value
    }

    private func updateSlideTitle(index: Int, title: String) throws {
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          if \(index) < 1 or \(index) > (count of slides of d) then error "Slide index out of range"
          set s to slide \(index) of d
          try
            set object text of default title item of s to \(q(title))
          end try
          return "ok"
        end tell
        """
        _ = try runAppleScript(script)
    }

    private func requireSlideIndex(_ slideKey: String) throws -> Int {
        if state.slideIndices[slideKey] == nil {
            try? resyncSlideBindingsFromDeck()
        }
        if let hintedIndex = hintedSlideIndex(from: slideKey), try slideExists(at: hintedIndex) {
            if state.slideIndices[slideKey] != hintedIndex || tombstonedSlideKeys.contains(slideKey) {
                state.slideIndices[slideKey] = hintedIndex
                tombstonedSlideKeys.remove(slideKey)
                persistState()
            }
            return hintedIndex
        }
        if tombstonedSlideKeys.contains(slideKey) {
            throw AdapterError(code: "MISSING_SLIDE", message: "Unknown slideKey \(slideKey). Run ensureSlide first.")
        }
        if let index = state.slideIndices[slideKey] {
            if try slideExists(at: index) {
                return index
            }
            state.slideIndices.removeValue(forKey: slideKey)
            state.elementAliases.removeValue(forKey: slideKey)
            tombstonedSlideKeys.insert(slideKey)
            persistState()
        }
        throw AdapterError(code: "MISSING_SLIDE", message: "Unknown slideKey \(slideKey). Run ensureSlide first.")
    }

    private func hintedSlideIndex(from slideKey: String) -> Int? {
        let lowered = slideKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(?:slide[_\-]?|s)(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: lowered, options: [], range: NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)),
              let range = Range(match.range(at: 1), in: lowered),
              let index = Int(lowered[range]),
              index > 0 else {
            return nil
        }
        return index
    }

    private func resolveElementName(slideKey: String, elementName: String) -> String {
        state.elementAliases[slideKey]?[elementName] ?? elementName
    }

    private func normalizeTextRole(_ role: String?) -> String {
        guard let role else { return "" }
        let lowered = role
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if lowered == "title" || lowered == "headline" {
            return "title"
        }
        if lowered == "body" || lowered == "bullets" || lowered == "bullet" || lowered == "content" {
            return "body"
        }
        return ""
    }

    private func roleAlias(for role: String) -> String {
        switch role {
        case "title":
            return "__ksk_role_title__"
        case "body":
            return "__ksk_role_body__"
        default:
            return ""
        }
    }

    private func roleFromAlias(_ alias: String?) -> String? {
        guard let alias else { return nil }
        let cleaned = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned == roleAlias(for: "title") {
            return "title"
        }
        if cleaned == roleAlias(for: "body") {
            return "body"
        }
        return nil
    }

    private func bindElementAlias(slideKey: String, requestedName: String, resolvedName: String, boundName: String) {
        let cleaned = boundName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = cleaned.isEmpty ? resolvedName : cleaned
        guard !canonical.isEmpty else { return }

        var aliases = state.elementAliases[slideKey] ?? [:]
        let before = aliases
        aliases[requestedName] = canonical
        if resolvedName != requestedName {
            aliases[resolvedName] = canonical
        }

        guard aliases != before else { return }
        state.elementAliases[slideKey] = aliases
        persistState()
    }

    private func removeElementAliases(slideKey: String, requestedName: String, resolvedName: String) {
        guard var aliases = state.elementAliases[slideKey] else { return }
        let before = aliases

        aliases.removeValue(forKey: requestedName)
        aliases.removeValue(forKey: resolvedName)
        aliases = aliases.filter { _, value in
            value != resolvedName
        }

        guard aliases != before else { return }
        if aliases.isEmpty {
            state.elementAliases.removeValue(forKey: slideKey)
        } else {
            state.elementAliases[slideKey] = aliases
        }
        persistState()
    }

    private func removeSlideBindings(at deletedIndex: Int) -> [String] {
        let removedKeys = state.slideIndices.compactMap { entry -> String? in
            guard !isConcreteSlideAlias(entry.key) else { return nil }
            return entry.value == deletedIndex ? entry.key : nil
        }
        for key in removedKeys {
            state.slideIndices.removeValue(forKey: key)
            state.elementAliases.removeValue(forKey: key)
        }

        for (key, value) in state.slideIndices {
            if isConcreteSlideAlias(key) {
                continue
            }
            if value > deletedIndex {
                state.slideIndices[key] = value - 1
            }
        }
        return removedKeys
    }

    private func remapSlideBindingsForInsertion(at insertedIndex: Int) {
        guard insertedIndex > 0 else { return }
        for (key, value) in state.slideIndices where value >= insertedIndex {
            if isConcreteSlideAlias(key) {
                continue
            }
            state.slideIndices[key] = value + 1
        }
    }

    private func remapSlideBindingsForMove(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex else { return }

        for (key, value) in state.slideIndices {
            if isConcreteSlideAlias(key) {
                continue
            }
            if value == fromIndex {
                state.slideIndices[key] = toIndex
                continue
            }

            if fromIndex < toIndex, value > fromIndex, value <= toIndex {
                state.slideIndices[key] = value - 1
                continue
            }

            if fromIndex > toIndex, value >= toIndex, value < fromIndex {
                state.slideIndices[key] = value + 1
            }
        }
    }

    private func isConcreteSlideAlias(_ key: String) -> Bool {
        hintedSlideIndex(from: key) != nil
    }

    private func isStableSlideAlias(_ key: String) -> Bool {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("sref_") || normalized.hasPrefix("sid_")
    }

    private func stableTextHash(_ text: String) -> String {
        let bytes = [UInt8](text.utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private func stableAlias(forPersistentId persistentId: String?, index: Int) -> String {
        let trimmed = (persistentId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "fallback:index:\(index)" : "persistent:\(trimmed)"
        return "sref_\(stableTextHash(seed))"
    }

    private func fetchSlideIdentityRows() throws -> [(index: Int, stableAlias: String?)] {
        let script = """
        tell application "Keynote"
          if (count of documents) is 0 then error "No open presentation"
          set d to front document
          set sep to ASCII character 31
          set outLines to {}
          set totalSlides to count of slides of d
          repeat with i from 1 to totalSlides
            set s to slide i of d
            set sid to ""
            try
              set sid to (id of s as text)
            end try
            set end of outLines to (i as text) & sep & sid
          end repeat
          set AppleScript's text item delimiters to linefeed
          set payload to outLines as text
          set AppleScript's text item delimiters to ""
          return payload
        end tell
        """
        let raw = try runAppleScript(script)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        let sep = Character(UnicodeScalar(31)!)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> (index: Int, stableAlias: String?)? in
                let parts = line.split(separator: sep, omittingEmptySubsequences: false).map(String.init)
                guard let indexPart = parts.first,
                      let index = Int(indexPart.trimmingCharacters(in: .whitespacesAndNewlines)),
                      index > 0 else {
                    return nil
                }
                let sid = parts.count > 1 ? parts[1] : ""
                return (index: index, stableAlias: stableAlias(forPersistentId: sid, index: index))
            }
    }

    private func resyncSlideBindingsFromDeck() throws {
        guard try isPresentationOpen() else { return }
        let rows = try fetchSlideIdentityRows()
        let totalSlides = rows.count
        var next: [String: Int] = [:]
        var changed = false

        let preservedAliases = state.slideIndices
            .filter { key, _ in
                !isConcreteSlideAlias(key) && !isStableSlideAlias(key)
            }

        for (index, stableAlias) in rows {
            next["slide_\(index)"] = index
            if let stableAlias {
                next[stableAlias] = index
                tombstonedSlideKeys.remove(stableAlias)
            }
        }

        for (alias, oldIndex) in preservedAliases {
            if oldIndex >= 1, oldIndex <= totalSlides {
                next[alias] = oldIndex
                tombstonedSlideKeys.remove(alias)
            } else {
                state.elementAliases.removeValue(forKey: alias)
                tombstonedSlideKeys.insert(alias)
                changed = true
            }
        }

        if next != state.slideIndices {
            state.slideIndices = next
            changed = true
        }

        if changed {
            persistState()
        }
    }

    private func stateFilePath() -> URL? {
        guard let presentationPath = state.presentationPath else { return nil }
        let url = URL(fileURLWithPath: presentationPath)
        let directory = url.deletingLastPathComponent()
        return directory.appendingPathComponent(".keynote-sidekick-state.json")
    }

    private func loadState() {
        guard let stateURL = stateFilePath(),
              let data = try? Data(contentsOf: stateURL),
              let loaded = try? JSONDecoder().decode(AdapterState.self, from: data) else {
            return
        }

        if loaded.presentationPath == state.presentationPath {
            state = loaded
            tombstonedSlideKeys.removeAll()
        }
    }

    private func persistState() {
        guard let stateURL = stateFilePath() else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL, options: [.atomic])
        } catch {
            // Keep execution deterministic; persistence failures are non-fatal for a single run.
        }
    }
}
