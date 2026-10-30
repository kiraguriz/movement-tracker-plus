import Foundation

extension String {
    /// The longest prefix of whole characters that fits in `limit` UTF-16 code units. The proxy measures strings in
    /// UTF-16 units (JavaScript `length`), so a plain `prefix(_:)` by characters can still be too long for emoji.
    func prefix(utf16Limit limit: Int) -> String {
        var result = ""
        var used = 0
        for character in self {
            let units = character.utf16.count
            if used + units > limit { break }
            result.append(character)
            used += units
        }
        return result
    }
}
