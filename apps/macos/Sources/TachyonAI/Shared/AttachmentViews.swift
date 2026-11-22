import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The files waiting to go out with the next message, each removable, plus any
/// problem adding one. Takes no space when there is nothing to show.
struct AttachmentChips: View {
    @ObservedObject var model: ChatModel

    var body: some View {
        if !model.attachments.isEmpty || model.attachmentError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !model.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.attachments) { file in
                                chip(file)
                            }
                        }
                    }
                }
                if let error = model.attachmentError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func chip(_ file: Attachment) -> some View {
        HStack(spacing: 5) {
            Image(systemName: file.isImage ? "photo" : "doc.text")
                .foregroundStyle(.secondary)
            Text(file.filename).lineLimit(1).truncationMode(.middle)
            Button {
                model.removeAttachment(file.id)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(file.filename) を外す")
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: 220)
        .background(.quaternary, in: Capsule())
    }
}

/// The paperclip: picks files (and, on iOS, photos) to attach.
struct AttachmentButton: View {
    @ObservedObject var model: ChatModel
    @State private var pickingFiles = false
    #if os(iOS)
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    #endif

    /// What the agent API accepts: images, and anything that is text.
    private static let fileTypes: [UTType] = [.image, .text, .json, .xml, .yaml, .sourceCode, .data]

    var body: some View {
        control
            .fileImporter(
                isPresented: $pickingFiles, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    model.attach(urls: urls)
                }
            }
            .help("ファイルを添付")
    }

    private var icon: some View {
        Image(systemName: "paperclip")
            .font(.system(size: 15, weight: .medium))
            .frame(width: 32, height: 32)
            .background(.quaternary, in: Circle())
            .contentShape(Circle())
    }

    @ViewBuilder private var control: some View {
        #if os(iOS)
        Menu {
            Button {
                pickingPhotos = true
            } label: {
                Label("写真を選ぶ", systemImage: "photo.on.rectangle")
            }
            Button {
                pickingFiles = true
            } label: {
                Label("ファイルを選ぶ", systemImage: "folder")
            }
        } label: {
            icon
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ファイルを添付")
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 4, matching: .images)
        .onChange(of: photos) {
            let picked = photos
            photos = []
            Task {
                for (index, item) in picked.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        model.attach(imageData: data, name: "photo-\(index + 1).jpg")
                    }
                }
            }
        }
        #else
        Button {
            pickingFiles = true
        } label: {
            icon
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ファイルを添付")
        #endif
    }
}
