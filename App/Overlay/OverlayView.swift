import SwiftUI
import VoiceInputCore

@MainActor final class OverlayModel: ObservableObject {
    @Published var state: SessionState = .idle
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 16)
            .frame(width: OverlayPanel.size.width, height: OverlayPanel.size.height)
            .background(.regularMaterial, in: Capsule())
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .recording(let level, let preview):
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                LevelBar(level: level)
                Text(preview.isEmpty ? "録音中" : preview)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .processing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("文字に変換しています").foregroundStyle(.secondary)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
        case .notice(let message):
            Label(message, systemImage: "info.circle.fill")
                .lineLimit(1)
        }
    }
}

private struct LevelBar: View {
    let level: Float

    var body: some View {
        // 話し声の RMS はおおむね 0.02〜0.2 なので、平方根で広げて見やすくする。
        let fraction = CGFloat(min(1, (max(0, level)).squareRoot() * 2))
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(.green).frame(width: 48 * fraction)
        }
        .frame(width: 48, height: 6)
        .animation(.linear(duration: 0.1), value: fraction)
    }
}
