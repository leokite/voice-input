import AppKit
import SwiftUI
import VoiceInputCore

struct HistoryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selections: [UUID: String] = [:]
    @State private var registering: RegisterRequest?

    struct RegisterRequest: Identifiable {
        let id = UUID()
        let from: String
    }

    var body: some View {
        Group {
            if coordinator.history.entries.isEmpty {
                Text("履歴はまだありません").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(coordinator.history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            if !entry.inserted {
                                Text("未挿入").font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("コピー") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            }
                            Button("用語集に登録") {
                                let selected = selections[entry.id] ?? ""
                                registering = RegisterRequest(from: selected.isEmpty ? entry.text : selected)
                            }
                        }
                        SelectableText(text: entry.text) { selections[entry.id] = $0 }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(item: $registering) { request in
            RegisterCorrectionSheet(from: request.from) { from, to in
                var g = coordinator.glossary
                g.addCorrection(from: from, to: to)
                coordinator.updateGlossary(g)
            }
        }
    }
}

private struct RegisterCorrectionSheet: View {
    @State var from: String
    @State private var to = ""
    let onRegister: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(from: String, onRegister: @escaping (String, String) -> Void) {
        _from = State(initialValue: from)
        self.onRegister = onRegister
    }

    private var trimmedFrom: String { from.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTo: String { to.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("用語集に登録").font(.headline)
            TextField("置き換え元", text: $from)
            TextField("置き換え先", text: $to)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("登録") {
                    onRegister(trimmedFrom, trimmedTo)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedFrom.isEmpty || trimmedTo.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }
}

/// 読み取り専用で、一部を選べるテキスト。選んだ文字列を `onSelect` で知らせる。
private struct SelectableText: NSViewRepresentable {
    let text: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onSelect = onSelect
        if view.string != text { view.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            let selected = range.length > 0 ? (view.string as NSString).substring(with: range) : ""
            DispatchQueue.main.async { self.onSelect(selected) }
        }
    }
}
