import Testing
@testable import RockyKit

/// DLG-02 and DLG-03: the mini-modals' buttons, left to right, and what Return, Esc, ⌘D and Tab press. DLG-06: the
/// order of a permission request's buttons.
struct DialogButtonsTests {
    /// A tab that closes with unsaved edits, listed as `.confirmationDialog` had it (Save, Don't Save, Cancel):
    /// "Don't Save" alone at the left, then Cancel and Save, the default.
    @Test func theUnsavedPromptPutsDontSaveAtTheLeftAndSaveLast() {
        let row = DialogButtonRow([
            DialogButton(id: 0, role: .primary),
            DialogButton(id: 1, role: .destructive, isLeading: true, isDontSave: true),
            DialogButton(id: 2, role: .cancel),
        ])
        #expect(row.leading.map(\.id) == [1])
        #expect(row.trailing.map(\.id) == [2, 0])
        #expect(row.defaultButton?.id == 0)
        #expect(row.cancelButton?.id == 2)
        #expect(row.dontSaveButton?.id == 1)
    }

    /// A confirmation listed with its destructive button first: Cancel, then the button, which Return presses.
    @Test func aConfirmationEndsWithItsDestructiveDefault() {
        let row = DialogButtonRow([DialogButton(id: 0, role: .destructive), DialogButton(id: 1, role: .cancel)])
        #expect(row.buttons.map(\.id) == [1, 0])
        #expect(row.defaultButton?.id == 0)
        #expect(row.cancelButton?.id == 1)
        #expect(row.dontSaveButton == nil)
    }

    /// The error modal's one button, OK: Return and Esc both press it.
    @Test func aLoneOKIsTheDefaultAndTheCancel() {
        let row = DialogButtonRow([DialogButton(id: 0, role: .primary)])
        #expect(row.defaultButton?.id == 0)
        #expect(row.cancelButton?.id == 0)
    }

    /// A row whose rightmost button is secondary has no default: Return presses nothing until Tab moves the focus.
    @Test func aSecondaryButtonAtTheRightIsNoDefault() {
        let row = DialogButtonRow([
            DialogButton(id: 0, role: .cancel, isLeading: true),
            DialogButton(id: 1, role: .secondary),
        ])
        #expect(row.defaultButton == nil)
        #expect(row.cancelButton?.id == 0)
    }

    /// The focus starts on the default: Tab wraps to the leftmost button and walks right; ⇧Tab walks left and wraps.
    @Test func tabWalksTheRowFromTheDefaultAndWraps() {
        let row = DialogButtonRow([
            DialogButton(id: 0, role: .destructive, isLeading: true, isDontSave: true),
            DialogButton(id: 1, role: .cancel),
            DialogButton(id: 2, role: .primary),
        ])
        #expect(row.focus(after: nil, forward: true) == 0)
        #expect(row.focus(after: 0, forward: true) == 1)
        #expect(row.focus(after: 1, forward: true) == 2)
        #expect(row.focus(after: 2, forward: true) == 0)
        #expect(row.focus(after: nil, forward: false) == 1)
        #expect(row.focus(after: 0, forward: false) == 2)
    }

    /// A disabled button is skipped; with no default the first Tab goes to the leftmost, the first ⇧Tab to the
    /// rightmost; with every button disabled nothing takes the focus.
    @Test func tabSkipsDisabledButtons() {
        let commit = DialogButtonRow([DialogButton(id: 0, role: .cancel), DialogButton(id: 1, role: .primary, isEnabled: false)])
        #expect(commit.focus(after: nil, forward: true) == 0)
        #expect(commit.focus(after: 0, forward: true) == 0)

        let noDefault = DialogButtonRow([DialogButton(id: 0, role: .cancel), DialogButton(id: 1, role: .secondary)])
        #expect(noDefault.focus(after: nil, forward: true) == 0)
        #expect(noDefault.focus(after: nil, forward: false) == 1)

        let off = DialogButtonRow([DialogButton(id: 0, role: .cancel, isEnabled: false)])
        #expect(off.focus(after: nil, forward: true) == nil)
    }

    /// DLG-06, with the four kinds and one Rocky does not know, in an order that is none of the row's: Cancel and the
    /// rejects at the left, then the unknown kind, Always Allow and Allow, which is primary and the default.
    @Test func aPermissionRequestOrdersItsFourKindsAndAnUnknownOne() {
        let request = PermissionRequest(title: "Bash: pnpm test", options: [
            PermissionOption(id: "always", name: "Always Allow", kind: "allow_always"),
            PermissionOption(id: "reject", name: "Reject", kind: "reject_once"),
            PermissionOption(id: "once", name: "Allow", kind: "allow_once"),
            PermissionOption(id: "other", name: "Ask Later", kind: "ask_later"),
            PermissionOption(id: "never", name: "Always Reject", kind: "reject_always"),
        ])
        let buttons = request.buttons
        #expect(buttons.map { $0.option?.id } == [nil, "reject", "never", "other", "always", "once"])
        #expect(buttons.map(\.role) == [.cancel, .secondary, .secondary, .secondary, .secondary, .primary])
        #expect(buttons.map(\.isLeading) == [true, true, true, false, false, false])

        // The row keeps that order, Return allows once, and Esc cancels.
        let row = DialogButtonRow(buttons.enumerated().map { DialogButton(id: $0.offset, role: $0.element.role, isLeading: $0.element.isLeading) })
        #expect(row.buttons.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(row.defaultButton?.id == 5)
        #expect(row.cancelButton?.id == 0)
    }

    /// Without "Allow", Return grants nothing: Always Allow is never the default.
    @Test func aPermissionRequestWithoutAllowOnceHasNoDefault() {
        let request = PermissionRequest(title: "Edit", options: [
            PermissionOption(id: "always", name: "Always Allow", kind: "allow_always"),
            PermissionOption(id: "reject", name: "Reject", kind: "reject_once"),
        ])
        let row = DialogButtonRow(request.buttons.enumerated().map { DialogButton(id: $0.offset, role: $0.element.role, isLeading: $0.element.isLeading) })
        #expect(row.buttons.map(\.id) == [0, 1, 2])
        #expect(row.defaultButton == nil)
    }
}
