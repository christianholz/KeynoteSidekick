import Foundation

enum PlanOperationContract {
    static func needsSlideKey(_ opName: String) -> Bool {
        switch opName {
        case "assertState", "resolveTarget", "ensureSlide", "duplicateSlide", "deleteSlide", "hideSlide", "moveSlide",
             "ensureTextBox", "ensureBullets", "ensureImage", "ensureShape", "deleteElement", "setFrame", "setOpacity",
             "setZOrder", "setPresenterNotes", "setTextStyle", "setParagraphStyle", "setFillStyle", "setStrokeStyle",
             "alignElements", "distributeElements":
            return true
        default:
            return false
        }
    }

    static func needsElementName(_ opName: String) -> Bool {
        switch opName {
        case "resolveTarget", "ensureTextBox", "ensureBullets", "ensureImage", "ensureShape", "deleteElement",
             "setFrame", "setOpacity", "setZOrder", "setTextStyle", "setParagraphStyle", "setFillStyle", "setStrokeStyle":
            return true
        default:
            return false
        }
    }
}
