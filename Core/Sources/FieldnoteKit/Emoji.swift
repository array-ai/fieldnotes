import Foundation

enum Emoji {
    /// The first emoji in `text`, as one character (flags, skin tones and joined
    /// emoji stay whole), or nil if there is none. Digits, "#" and "*" count as
    /// emoji in Unicode on their own; only their keycap forms are taken.
    static func first(in text: String) -> String? {
        for character in text {
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { continue }
            let presented = first.properties.isEmojiPresentation
                || (first.properties.isEmoji && scalars.count > 1)
                || (first.properties.isEmoji && first.value > 0x238C)
            if presented { return String(character) }
        }
        return nil
    }
}
