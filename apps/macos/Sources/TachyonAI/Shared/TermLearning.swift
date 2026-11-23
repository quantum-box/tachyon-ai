import Foundation

/// Finds the words worth adding to the vocabulary without being asked: names the
/// user typed themselves, and words they fixed after a dictation was pasted.
enum TermLearning {
    // MARK: - Names in typed text

    /// Product and proper names written in Latin letters ("Tachyon Field", "GitHub", "iOS").
    ///
    /// Only words with a capital letter count, since a lowercase word says nothing about
    /// being a name. Japanese words are left alone: without a dictionary a rare katakana
    /// name cannot be told from an everyday one, and everyday ones would fill the list.
    static func terms(in text: String) -> [String] {
        let prose = stripped(text)
        let source = prose as NSString
        var groups: [[NSRange]] = []
        var previousEnd = -1
        for match in wordPattern.matches(in: prose, range: NSRange(location: 0, length: source.length)) {
            let range = match.range
            guard isTermWord(source.substring(with: range)), !isCodeLike(range, in: source) else {
                previousEnd = -1
                continue
            }
            // Capitalized words one space apart are one name: "Tachyon Field".
            if previousEnd >= 0, range.location == previousEnd + 1, source.character(at: previousEnd) == space,
               let last = groups.indices.last, groups[last].count < maximumWords {
                groups[last].append(range)
            } else {
                groups.append([range])
            }
            previousEnd = NSMaxRange(range)
        }

        var seen = Set<String>()
        return groups.compactMap { group -> String? in
            let range = NSUnionRange(group[0], group[group.count - 1])
            let term = source.substring(with: range)
            guard term.count <= maximumLength, !stopWords.contains(term),
                  !(group.count == 1 && opensEnglishSentence(range, in: source)) else { return nil }
            return seen.insert(term.lowercased()).inserted ? term : nil
        }
    }

    private static let maximumWords = 4
    private static let maximumLength = 40
    private static let space: UInt16 = 0x20
    private static let stopWords: Set<String> = ["OK", "NG", "AM", "PM"]

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9]*(?:[.\-][A-Za-z0-9]+)*"#)
    /// Code blocks, inline code, links and addresses are not prose.
    private static let noisePattern = try! NSRegularExpression(
        pattern: #"```[\s\S]*?(?:```|$)|`[^`\n]*`|[A-Za-z][A-Za-z0-9+.\-]*://\S+|\S+@\S+\.\S+"#)

    private static func stripped(_ text: String) -> String {
        noisePattern.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "\n")
    }

    private static func isTermWord(_ word: String) -> Bool {
        guard word.count >= 2, let first = word.unicodeScalars.first else { return false }
        if CharacterSet.uppercaseLetters.contains(first) { return true }
        // Lowercase first: "iOS", "macOS", "iPhone", but not a camelCase identifier.
        let tail = word.drop { $0.isLowercase }
        let prefix = word.count - tail.count
        guard let head = tail.first, head.isUppercase else { return false }
        return tail.dropFirst().first?.isUppercase == true || (prefix == 1 && "ie".contains(word.first!))
    }

    /// Part of a path, a call or an identifier rather than a word in a sentence.
    private static func isCodeLike(_ range: NSRange, in source: NSString) -> Bool {
        let before = range.location > 0 ? source.character(at: range.location - 1) : 0
        let after = NSMaxRange(range) < source.length ? source.character(at: NSMaxRange(range)) : 0
        return codeNeighbors.contains(before) || codeNeighbors.contains(after)
    }

    private static let codeNeighbors = Set("/\\_@#$=<{[".utf16)

    /// "The", "This": a word that is capitalized only for starting an English sentence.
    private static func opensEnglishSentence(_ range: NSRange, in source: NSString) -> Bool {
        let word = source.substring(with: range)
        guard word.dropFirst().allSatisfy({ $0.isLowercase }) else { return false }
        var index = range.location - 1
        while index >= 0, source.character(at: index) == space { index -= 1 }
        let startsSentence = index < 0 || Set(".!?\n".utf16).contains(source.character(at: index))
        let next = NSMaxRange(range) + 1
        let followedByLowercase = next < source.length
            && source.character(at: next - 1) == space
            && (UInt16(0x61)...UInt16(0x7A)).contains(source.character(at: next))
        return startsSentence && followedByLowercase
    }

    // MARK: - Words fixed after a paste

    struct Correction: Equatable {
        /// What the transcription wrote.
        var heard: String
        /// What the user changed it to.
        var written: String
    }

    /// The words the user rewrote between the pasted text and what it became.
    ///
    /// Only a rewritten name is of interest: the transcription's side must be katakana or
    /// Latin letters, which is how it spells a word it does not know. Changes among kanji
    /// and hiragana are choices between homophones or edits to the sentence, and say
    /// nothing that holds for the next dictation. Neither does a changed number.
    /// A fix to the capitals alone counts ("Github" to "GitHub"): they are part of how a
    /// name is spelled.
    static func corrections(from pasted: String, to edited: String) -> [Correction] {
        let old = Array(pasted), new = Array(edited)
        guard old != new, old.count <= maximumCompared, new.count <= maximumCompared else { return [] }

        var removed = [Bool](repeating: false, count: old.count)
        var inserted = [Bool](repeating: false, count: new.count)
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed[offset] = true
            case .insert(let offset, _, _): inserted[offset] = true
            }
        }
        // Mostly different: the user rewrote the text instead of fixing words in it.
        guard removed.filter({ $0 }).count <= max(maximumHeard, old.count / 2) else { return [] }

        var hunks: [(old: Range<Int>, new: Range<Int>)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            let startOld = i, startNew = j
            while (i < old.count && removed[i]) || (j < new.count && inserted[j]) {
                if i < old.count, removed[i] { i += 1 } else { j += 1 }
            }
            // Letters only added or only taken out count when it happened inside a word
            // ("Noton" to "Notion"). At the edge of one it is the user writing more, or less.
            let rewritten = i > startOld && j > startNew
            let lettersAdded = i == startOld && isInsideWord(startOld, old, changed: new[startNew..<j])
            let lettersDropped = j == startNew && isInsideWord(startNew, new, changed: old[startOld..<i])
            if rewritten || lettersAdded || lettersDropped {
                hunks.append(widened(startOld..<i, startNew..<j, old, new))
            }
            if i == startOld, j == startNew { i += 1; j += 1 }
        }

        var seen = Set<String>()
        let found = hunks.compactMap { hunk -> Correction? in
            let heard = String(old[hunk.old]).trimmingCharacters(in: .whitespaces)
            let written = String(new[hunk.new]).trimmingCharacters(in: .whitespaces)
            guard heard.count >= 2, written.count >= 2,
                  heard.count <= maximumHeard, written.count <= maximumHeard,
                  heard != written, heard.contains(where: \.isLetter),
                  heard.allSatisfy({ [.latin, .katakana, .joiner].contains(Script(of: $0)) }),
                  written.allSatisfy({ Script(of: $0) != .other }),
                  written.contains(where: { [.latin, .katakana].contains(Script(of: $0)) }),
                  seen.insert(heard.lowercased()).inserted else { return nil }
            return Correction(heard: heard, written: written)
        }
        return found.count <= maximumCorrections ? found : []
    }

    private static let maximumCompared = 2000
    private static let maximumHeard = 30
    private static let maximumCorrections = 3

    /// Grows a changed stretch to the whole word around it: fixing one letter of
    /// "タキヨン" is a correction of the word, not of the letter. The text on either
    /// side is the same before and after, so both stretches grow together, and only
    /// through characters that continue the word on both sides.
    private static func widened(
        _ oldRange: Range<Int>, _ newRange: Range<Int>, _ old: [Character], _ new: [Character]
    ) -> (old: Range<Int>, new: Range<Int>) {
        var lowerOld = oldRange.lowerBound, lowerNew = newRange.lowerBound
        var upperOld = oldRange.upperBound, upperNew = newRange.upperBound
        while lowerOld > 0, lowerNew > 0,
              continues(old[lowerOld - 1], old[lowerOld]), continues(new[lowerNew - 1], new[lowerNew]) {
            lowerOld -= 1
            lowerNew -= 1
        }
        while upperOld < old.count, upperNew < new.count,
              continues(old[upperOld], old[upperOld - 1]), continues(new[upperNew], new[upperNew - 1]) {
            upperOld += 1
            upperNew += 1
        }
        return (lowerOld..<upperOld, lowerNew..<upperNew)
    }

    /// `changed` was added or taken out at `position` of `text`, between two letters of
    /// one word, and is made of the same kind of letters.
    private static func isInsideWord(
        _ position: Int, _ text: [Character], changed: ArraySlice<Character>
    ) -> Bool {
        guard !changed.isEmpty, position > 0, position < text.count,
              continues(text[position - 1], text[position]) else { return false }
        return changed.allSatisfy { Script(of: $0) == Script(of: text[position]) }
    }

    /// `neighbor` belongs to the same word as `edge`, the character next to it.
    private static func continues(_ neighbor: Character, _ edge: Character) -> Bool {
        let script = Script(of: neighbor)
        return (script == .latin || script == .katakana) && script == Script(of: edge)
    }

    private enum Script {
        case latin, katakana, kanji, hiragana
        /// A space or hyphen inside a name of several words.
        case joiner
        case other

        init(of character: Character) {
            guard let scalar = character.unicodeScalars.first else { self = .other; return }
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: self = .latin
            // The long vowel mark "ー" and the middle dot "・" are parts of katakana words.
            case 0x30A1...0x30FA, 0x30FC, 0x30FB: self = .katakana
            case 0x3041...0x3096: self = .hiragana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x3005: self = .kanji
            case 0x20, 0x2D, 0x2E, 0x27: self = .joiner
            default: self = .other
            }
        }
    }
}
