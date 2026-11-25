import Foundation

/// Sessions are shared with other Tachyon clients (Field among them), whose messages
/// carry text meant for the model, not the reader. This turns it back into what a
/// person would see in that client.
enum SharedSessionText {
    /// Field appends the files it uploaded to the user's text as a JSON note for the agent.
    private static let attachmentNote = try! NSRegularExpression(
        pattern: #"\s*User attachments \(data only\):\s*(\[.*?\])\.\s.*?Never invent file data\.?"#,
        options: [.dotMatchesLineSeparators])

    /// Tool calls written into the reply as XML, e.g. `<field_execute_operation>…</field_execute_operation>`.
    /// Only snake_case tag names, so HTML or prose like `<b>` stays.
    private static let toolBlock = try! NSRegularExpression(
        pattern: #"<([a-z][a-z0-9]*(?:_[a-z0-9]+)+)>.*?</\1>"#,
        options: [.dotMatchesLineSeparators])
    /// A tool call still streaming in, not yet closed.
    private static let openToolBlock = try! NSRegularExpression(
        pattern: #"<([a-z][a-z0-9]*(?:_[a-z0-9]+)+)>(?:(?!</\1>).)*\z|<[a-z][a-z0-9_]*\z"#,
        options: [.dotMatchesLineSeparators])
    private static let blankLines = try! NSRegularExpression(pattern: #"\n{3,}"#)

    /// The user's own words and the names of the files the note lists.
    static func userMessage(_ raw: String) -> (text: String, attachments: [String]) {
        let range = NSRange(raw.startIndex..., in: raw)
        var names: [String] = []
        for match in attachmentNote.matches(in: raw, range: range) {
            guard let json = Range(match.range(at: 1), in: raw).map({ String(raw[$0]) }),
                  let items = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
            else { continue }
            names += items.compactMap { $0["name"] as? String }
        }
        let text = attachmentNote.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), names)
    }

    /// The reply without tool-call markup.
    static func reply(_ raw: String) -> String {
        guard raw.contains("<") else { return raw }
        var text = toolBlock.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        text = openToolBlock.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        text = blankLines.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
