import Foundation

/// After Redpen writes a fix straight into another app's text field, what the field reads now decides what happens
/// next. Kept apart from Accessibility so it can be tested.
public enum WriteCheck {
    public enum Outcome: Equatable, Sendable {
        /// The field reads exactly as it should with the fix in.
        case written
        /// The field still reads exactly as before: the app ignored the write, so pasting is safe.
        case untouched
        /// Anything else: the app changed the text some other way (auto-correct, smart quotes, a write that landed
        /// late or only in part), or the field can't be read. Pasting now could put the fix in twice.
        case unexpected
    }

    /// `before`: the whole field before the write. `expected`: the whole field with the fix in. `after`: what the
    /// field reads now, nil when it can't be read. Compared unit by unit, like Accessibility positions.
    public static func outcome(before: String, expected: String, after: String?) -> Outcome {
        guard let after else { return .unexpected }
        if after.utf16.elementsEqual(expected.utf16) { return .written }
        if after.utf16.elementsEqual(before.utf16) { return .untouched }
        return .unexpected
    }
}
