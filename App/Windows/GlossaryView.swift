import SwiftUI
import VoiceInputCore

struct GlossaryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var newTerm = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    private var glossary: Binding<Glossary> {
        Binding(get: { coordinator.glossary }, set: { coordinator.updateGlossary($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            termsTable
            Divider()
            replacementsTable
        }
    }

    private var termsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("用語").font(.headline)
            header(["用語", "最後に使った日"])
            List {
                ForEach(coordinator.glossary.terms, id: \.text) { term in
                    TermRow(term: term,
                            rename: { newText in
                                var g = coordinator.glossary
                                guard g.renameTerm(from: term.text, to: newText) else { return false }
                                coordinator.updateGlossary(g)
                                return true
                            },
                            delete: {
                                var g = coordinator.glossary
                                g.terms.removeAll { $0.text == term.text }
                                coordinator.updateGlossary(g)
                            },
                            lastUsed: lastUsed)
                }
            }
            HStack {
                TextField("新しい用語", text: $newTerm)
                Button("追加") {
                    let text = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                    var g = coordinator.glossary
                    g.addTerm(text)
                    coordinator.updateGlossary(g)
                    newTerm = ""
                }
                .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private var replacementsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("置き換え").font(.headline)
            header(["置き換え元", "置き換え先", "最後に使った日"])
            List {
                ForEach(glossary.replacements) { $item in
                    HStack {
                        TextField("置き換え元", text: $item.from)
                        TextField("置き換え先", text: $item.to)
                        lastUsed(item.lastUsed)
                        Button(role: .destructive) {
                            var g = coordinator.glossary
                            g.replacements.removeAll { $0.id == item.id }
                            coordinator.updateGlossary(g)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                TextField("置き換え元", text: $newFrom)
                TextField("置き換え先", text: $newTo)
                Button("追加") {
                    var g = coordinator.glossary
                    g.addCorrection(from: newFrom.trimmingCharacters(in: .whitespacesAndNewlines),
                                    to: newTo.trimmingCharacters(in: .whitespacesAndNewlines))
                    coordinator.updateGlossary(g)
                    newFrom = ""
                    newTo = ""
                }
                .disabled(newFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func header(_ titles: [String]) -> some View {
        HStack {
            ForEach(titles, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
    }

    private func lastUsed(_ date: Date?) -> some View {
        Group {
            if let date {
                Text(date, format: .relative(presentation: .named))
            } else {
                Text("—")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 90, alignment: .trailing)
    }
}

/// 用語 1 件。入力中は手元の下書きを直し、Return か入力欄を離れたときに確定する。
private struct TermRow<LastUsed: View>: View {
    let term: Term
    let rename: (String) -> Bool
    let delete: () -> Void
    let lastUsed: (Date?) -> LastUsed
    @State private var draft: String

    init(term: Term, rename: @escaping (String) -> Bool, delete: @escaping () -> Void,
         lastUsed: @escaping (Date?) -> LastUsed) {
        self.term = term
        self.rename = rename
        self.delete = delete
        self.lastUsed = lastUsed
        _draft = State(initialValue: term.text)
    }

    var body: some View {
        HStack {
            TextField("用語", text: $draft).onSubmit(commit)
            lastUsed(term.lastUsed)
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { draft = term.text } else if text != term.text, !rename(text) { draft = term.text }
    }
}
