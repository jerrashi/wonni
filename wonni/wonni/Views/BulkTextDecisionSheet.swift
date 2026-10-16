//
//  BulkTextDecisionSheet.swift
//  wonni
//
//  "Several items in one entry" (2026-10-15, mock approved the same day). A pasted
//  entry like "amazing spider man issues 211-215" names five things without saying
//  they sell together; the server returns such entries unpriced in `needsDecision`
//  and this sheet asks, once per run, whether each becomes separate listings or one
//  bundle. Separate is the default. The other entries from the paste are already
//  being created while this waits; these join the queue on Continue. Dismissing the
//  sheet keeps the defaults. Presented from MainView (like the AI-photo question) so
//  it reaches the user after the paste sheet has closed.
//

import SwiftUI

struct BulkTextDecisionSheet: View {
    let decisions: [ListingDecision]
    let onContinue: ([Int: BulkTextDraftMapper.DecisionChoice]) -> Void

    @State private var choices: [Int: BulkTextDraftMapper.DecisionChoice] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("These entries name more than one thing. List each one on its own, or sell them together as one lot?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                }
                ForEach(Array(decisions.enumerated()), id: \.offset) { index, decision in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(decision.title)
                                .font(.subheadline.weight(.semibold))
                            Text(detail(for: decision))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            Picker("", selection: Binding(
                                get: { choices[index] ?? .individual },
                                set: { choices[index] = $0 }
                            )) {
                                Text("\(decision.memberTitles.count) separate listings").tag(BulkTextDraftMapper.DecisionChoice.individual)
                                Text("One bundle").tag(BulkTextDraftMapper.DecisionChoice.bundle)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("bulkTextDecisionPicker")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Several items in one entry")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    onContinue(choices)
                } label: {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
                .accessibilityIdentifier("bulkTextDecisionContinue")
            }
        }
    }

    /// "5 items · #211, #212, #213, #214, #215 · "bagged and boarded"" — the members
    /// and the entry's own words, so the user recognises what they wrote.
    private func detail(for decision: ListingDecision) -> String {
        let members = decision.memberTitles
        let shown = members.prefix(6).map(Self.shortMember).joined(separator: ", ") + (members.count > 6 ? ", …" : "")
        let snippet = decision.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "\(members.count) items · \(shown)"
        if !snippet.isEmpty && snippet.lowercased() != decision.title.lowercased() {
            out += " · “\(snippet.count > 60 ? String(snippet.prefix(60)) + "…" : snippet)”"
        }
        return out
    }

    /// Members usually share the entry's name; show what differs ("#211", "Blue").
    static func shortMember(_ title: String) -> String {
        if let hash = title.range(of: #"#\d+"#, options: .regularExpression) { return String(title[hash]) }
        return title.count > 24 ? String(title.prefix(24)) + "…" : title
    }
}
