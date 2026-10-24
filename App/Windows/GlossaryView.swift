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
                ForEach(glossary.terms.indices, id: \.self) { i in
                    HStack {
                        TextField("用語", text: glossary.terms[i].text)
                        lastUsed(glossary.wrappedValue.terms[i].lastUsed)
                        Button(role: .destructive) {
                            var g = coordinator.glossary
                            g.terms.remove(at: i)
                            coordinator.updateGlossary(g)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
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
