import Foundation

/// Shared Character utilities for text normalization across ASR protocols.
extension Character {
    var isClosingPunctuation: Bool {
        ",.!?;:)]}\"'".contains(self)
    }

    var isOpeningPunctuation: Bool {
        "([{/\"'".contains(self)
    }

    var isCJKUnifiedIdeograph: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
