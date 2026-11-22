import Foundation

/// How dictated text is tidied before it is pasted.
enum CleanupMode: String, CaseIterable {
    case off
    /// Filler removal inside the app: instant, free, and conservative.
    case fast
    /// A language model rewrites the text: also fixes restarts and punctuation,
    /// at the cost of a network round trip and a billed request.
    case thorough

    var title: String {
        switch self {
        case .off: return "オフ"
        case .fast: return "高速 (アプリ内)"
        case .thorough: return "高精度 (LLM)"
        }
    }
}

/// Removes filler words without a network call.
///
/// Deliberately conservative: it only drops sounds that are never real words
/// ("えーと", "あのー", "um") and leaves anything ambiguous alone, because a wrongly
/// deleted word is worse than a filler left in.
enum TranscriptCleaner {
    static func clean(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in rules {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let rules: [(String, String)] = [
        // Japanese fillers that are unmistakable wherever they appear, with a trailing comma.
        ("(?:えーっと|えーと|えっとー*|ええと|えー+|あのー+|あのう|うーん+|んー+|あー+)[、,]?[ 　]*", ""),
        // Words that are only fillers when they stand alone between punctuation
        // ("あの、" at the start of a clause; not "あの人").
        ("(^|[、。！？!?\\n])[ 　]*(?:あの|えと|まあ|まぁ)[、,][ 　]*", "$1"),
        // English fillers as whole words.
        ("\\b(?:um+|uh+|erm+|uhm+)\\b[,]?[ ]*", ""),
        // Punctuation left behind by a removed filler.
        ("、{2,}", "、"),
        ("(^|[。！？!?\\n])[ 　]*、", "$1"),
        ("、(?=[。！？!?])", ""),
        ("[ ]{2,}", " "),
    ]
}
