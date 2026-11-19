//
//  SoldOutConfirmSheet.swift
//  wonni
//
//  The one confirm step before a sold-out run (mock 2026-11-19, board 1:
//  https://claude.ai/artifact/6x2zRqZfwuRfzJCCPxmqL3). One toggle per platform the
//  selected listings are on, all on every time; turning one off leaves that listing
//  alone there (the seller already marked it sold out by hand). Wonni is always on.
//  The Mercari row names the account's Deactivate / Delete setting, which is the
//  per-run confirmation agreed for Delete (2026-10-29). Every entry point goes through
//  SoldOutRunner.requestMarkSoldOut; MainView presents this.
//

import SwiftUI

struct SoldOutConfirmSheet: View {
    let listings: [UserListing]
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Set<String> = []

    private let action = SoldOutRunner.mercariAction

    /// The jobs these listings would become, used only to work out the toggles.
    private var previewJobs: [SoldOutJob] {
        listings.compactMap { listing in
            guard let id = listing.id else { return nil }
            return SoldOutPlan.makeJob(
                listingId: id, title: listing.customTitle, coverPhotoPath: nil,
                quantity: listing.quantity, crossPostStatus: listing.crossPostStatus,
                crossPostListingIds: listing.crossPostListingIds, action: action
            )
        }
    }

    private var platforms: [String] { SoldOutPlan.togglePlatforms(previewJobs) }

    var body: some View {
        NavigationStack {
            List {
                Section("Mark sold out on") {
                    HStack {
                        Text("Wonni")
                        Spacer()
                        Text("Always").foregroundStyle(.secondary)
                    }
                    ForEach(platforms, id: \.self) { platform in
                        Toggle(isOn: binding(platform)) {
                            HStack {
                                Text(SoldOutPlan.displayName(platform))
                                if platform == "mercari" {
                                    Spacer()
                                    Text(action.label)
                                        .font(.footnote)
                                        .foregroundStyle(action == .delete ? Color.red : Color.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("soldOutToggle-\(platform)")
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(listings.count == 1 ? "1 listing" : "\(listings.count) listings")
                        Text(listings.map { $0.customTitle ?? "Untitled listing" }.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        let skip = Set(platforms).subtracting(enabled)
                        SoldOutRunner.shared.enqueue(listings, action: action, skip: skip)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("soldOutStartButton")
                }
            }
            .onAppear { enabled = Set(platforms) }
        }
        .presentationDetents([.medium, .large])
    }

    private func binding(_ platform: String) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(platform) },
            set: { isOn in
                if isOn { enabled.insert(platform) } else { enabled.remove(platform) }
            }
        )
    }
}
