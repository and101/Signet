import SwiftUI

/// Edits a list of "this → that" rename rules (bundle IDs or app names).
struct RenameRulesView: View {
    let title: String
    @Binding var rules: [SigningOptions.RenameRule]
    let matchPrompt: String
    let replacementPrompt: String
    let footer: String

    @State private var editing: SigningOptions.RenameRule?
    @State private var match = ""
    @State private var replacement = ""

    var body: some View {
        List {
            Section {
                ForEach(rules) { rule in
                    Button {
                        match = rule.match
                        replacement = rule.replacement
                        editing = rule
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.match).foregroundStyle(.primary)
                            Text("→ \(rule.replacement)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { rules.remove(atOffsets: $0) }
                Button {
                    match = ""
                    replacement = ""
                    editing = SigningOptions.RenameRule(match: "", replacement: "")
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !rules.isEmpty { EditButton() } }
        .alert(editing.map { rule in rules.contains { $0.id == rule.id } ? "Edit Rule" : "New Rule" } ?? "",
               isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField(matchPrompt, text: $match)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(replacementPrompt, text: $replacement)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Matches exactly. Leave nothing blank.")
        }
    }

    private func save() {
        guard var rule = editing else { return }
        let match = match.trimmingCharacters(in: .whitespaces)
        let replacement = replacement.trimmingCharacters(in: .whitespaces)
        guard !match.isEmpty, !replacement.isEmpty else { return }
        rule.match = match
        rule.replacement = replacement
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            // A second rule for the same app would never apply, so replace it instead.
            rules.removeAll { $0.match == match }
            rules.append(rule)
        }
    }
}
