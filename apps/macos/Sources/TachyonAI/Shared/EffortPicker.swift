import SwiftUI

/// The thinking-effort popover: the current level and a four-step slider.
struct EffortPicker: View {
    @Binding var effort: ReasoningEffort
    /// False when the selected model ignores the setting.
    let applies: Bool

    private static let gradient = LinearGradient(
        colors: [Color(red: 0.55, green: 0.65, blue: 1), Color(red: 0.55, green: 0.3, blue: 0.95)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        VStack(spacing: 12) {
            Text(effort.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Self.gradient)
                .contentTransition(.numericText())

            Slider(value: level, in: 0...Double(ReasoningEffort.allCases.count - 1), step: 1)
                .tint(Color(red: 0.55, green: 0.4, blue: 0.98))
                .disabled(!applies)

            HStack {
                Text("速い")
                Spacer()
                Text("深い")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !applies {
                Text("選択中のモデルは思考量の指定に対応していません (対応: OpenAI の gpt-5 / gpt-6 系)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 260)
        .animation(.snappy, value: effort)
    }

    private var level: Binding<Double> {
        Binding(
            get: { Double(ReasoningEffort.allCases.firstIndex(of: effort) ?? 0) },
            set: { effort = ReasoningEffort.allCases[Int($0.rounded())] })
    }
}
