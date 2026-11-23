import SwiftUI

/// The one control for "which model, thinking how hard": a button showing the current
/// choice, opening a panel with the model menu and the effort slider.
struct ModelControl: View {
    @ObservedObject var model: ChatModel
    /// Opens the settings where the offered models are chosen.
    let openSettings: () -> Void
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.models.isEmpty)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ModelPanel(model: model) {
                isOpen = false
                openSettings()
            }
            .presentationCompactAdaptation(.popover)
        }
        .help("モデルと思考量")
    }

    /// The model, plus the effort when one is set and the model honours it.
    private var title: String {
        guard model.effortApplies, model.effort != .standard else { return model.selectedModelName }
        return "\(model.selectedModelName) · \(model.effort.title)"
    }
}

private struct ModelPanel: View {
    @ObservedObject var model: ChatModel
    let openSettings: () -> Void

    private static let gradient = LinearGradient(
        colors: [Color(red: 0.55, green: 0.65, blue: 1), Color(red: 0.55, green: 0.3, blue: 0.95)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                VStack(spacing: 4) {
                    Text(model.effortApplies ? model.effort.title : "—")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Self.gradient)
                        .contentTransition(.numericText())
                    modelMenu
                }
                HStack {
                    Spacer()
                    Button {
                        model.effort = .standard
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!model.effortApplies || model.effort == .standard)
                    .help("思考量を標準に戻す")
                }
            }

            Slider(value: level, in: 0...Double(ReasoningEffort.allCases.count - 1), step: 1)
                .tint(Color(red: 0.55, green: 0.4, blue: 0.98))
                .disabled(!model.effortApplies)

            if !model.effortApplies {
                Text("このモデルは思考量の指定に対応していません (対応: OpenAI の gpt-5 / gpt-6 系)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 280)
        .animation(.snappy, value: model.effort)
    }

    private var modelMenu: some View {
        Menu {
            Picker("モデル", selection: $model.selectedModel) {
                ForEach(model.providers, id: \.self) { provider in
                    let offered = model.visibleModels.filter { $0.provider == provider }
                    if !offered.isEmpty {
                        Section(provider) {
                            ForEach(offered) { info in
                                Text(info.name).tag(Optional(info.id))
                            }
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()
            Button("表示するモデルを選ぶ…", action: openSettings)
        } label: {
            HStack(spacing: 3) {
                Text(model.selectedModelName).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var level: Binding<Double> {
        Binding(
            get: { Double(ReasoningEffort.allCases.firstIndex(of: model.effort) ?? 0) },
            set: { model.effort = ReasoningEffort.allCases[Int($0.rounded())] })
    }
}
