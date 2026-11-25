import SwiftUI

/// One message in a conversation, drawn as a Liquid Glass bubble.
struct MessageRow: View {
    let message: ChatMessage
    /// Sends one of the offered answers; nil when the question can no longer be answered.
    let onOption: ((String) -> Void)?
    /// Shows a sent file in full; nil where there is nowhere to show it (iOS).
    var onOpenFile: ((Attachment) -> Void)? = nil
    /// Shows the reply in full beside the chat; nil where there is nowhere to show it.
    var onOpenReply: (() -> Void)? = nil

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(message.attachments, id: \.self) { name in
                        let file = message.files.first { $0.filename == name }
                        let chip = Label(name, systemImage: file?.isImage == true ? "photo" : "paperclip")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular.interactive(), in: .capsule)
                        if let file, let onOpenFile {
                            Button { onOpenFile(file) } label: { chip }
                                .buttonStyle(.plain)
                                .help("右に表示")
                        } else {
                            chip
                        }
                    }
                    Text(message.text)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: .rect(cornerRadius: 18))
                }
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
                    if let onOpenReply, !message.failed {
                        Button(action: onOpenReply) {
                            Label("右で開く", systemImage: "sidebar.right")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .help("この返答を右のペインに全文表示")
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
