import SwiftUI

/// One message in a conversation, drawn as a Liquid Glass bubble.
struct MessageRow: View {
    let message: ChatMessage
    /// Sends one of the offered answers; nil when the question can no longer be answered.
    let onOption: ((String) -> Void)?

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .rect(cornerRadius: 18))
            }
        case .assistant:
            // Empty until the first text arrives; the activity capsule stands in for it.
            if !message.text.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        MarkdownView(message.text)
                            .foregroundStyle(message.failed ? Color.red : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .glassEffect(
                                message.failed ? .regular.tint(.red.opacity(0.25)) : .regular,
                                in: .rect(cornerRadius: 18))
                        Spacer(minLength: 32)
                    }
                    if let onOption, !message.options.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.options, id: \.self) { option in
                                Button(option) { onOption(option) }
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                            }
                        }
                    }
                }
            }
        }
    }
}
