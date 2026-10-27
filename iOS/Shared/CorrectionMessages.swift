import Foundation

// Correcting a selection rides the dictation channel: the keyboard sends what
// is selected along with `start`, and the app answers with the text to write
// instead of `finalText`. Plain types only, since the widget compiles Shared
// without the correction core.

struct CorrectionRequest: Codable, Equatable, Sendable {
    /// Empty when reading context is off or the field looks sensitive.
    var before = ""
    var selected: String
    var after = ""
    /// Spellings the user already rejected, oldest first.
    var attempts: [String] = []
}

struct CorrectionOutcome: Codable, Equatable, Sendable {
    var replacement: String
    /// Other places in `before`/`after` to change too, numbered as
    /// `CorrectionOccurrences` numbers them.
    var also: [Int] = []
    /// Already in the vocabulary, so the keyboard doesn't offer to remember it.
    var isHotword = false
}
