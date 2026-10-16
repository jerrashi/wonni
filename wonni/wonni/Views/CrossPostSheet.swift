//
//  CrossPostSheet.swift
//  wonni
//
//  The ONE platform-picker sheet, shown from two places:
//  - Review & Publish (`.publish`): the drafts are about to become Wonni listings
//    and may fan out to other platforms right after.
//  - Profile multi-select (`.crossPost`): the listings are live on Wonni already;
//    only the extra platforms are at stake.
//
//  Both used to have their own copy (PublishConfirmationSheet in
//  CreateListingView, BulkCrossPostSheet in ProfileView) that drifted: the
//  Profile one still listed every selected listing above the toggles, ignored
//  the remembered defaults, and would happily queue a Mercari post for a
//  listing already on Mercari. Merged 2026-10-16 (mock
//  https://claude.ai/artifact/BAzAyB7BX2Jm1oKvFHWipZ, approved).
//
//  The sheet takes candidates (id, title, price, platforms already posted),
//  a mode and the remembered defaults, and hands back a platform set. Each
//  caller keeps its own execution; the planner below tells both which
//  candidates to skip per platform so neither ever double-posts.
//

import SwiftUI

/// One draft or listing offered to the sheet. Drafts carry no posted platforms.
struct CrossPostCandidate: Identifiable, Equatable {
    let id: String
    let title: String
    let price: Double?
    /// Platforms this listing is already on ("posted" or in flight).
    let postedPlatforms: Set<String>

    init(id: String, title: String, price: Double?, postedPlatforms: Set<String> = []) {
        self.id = id
        self.title = title
        self.price = price
        self.postedPlatforms = postedPlatforms
    }

    init(listing: UserListing) {
        self.init(
            id: listing.id ?? UUID().uuidString,
            title: listing.customTitle ?? "Untitled",
            price: listing.price,
            postedPlatforms: Set((listing.crossPostStatus ?? [:])
                .filter { CrossPostPlan.countsAsPosted($0.value) }
                .map(\.key))
        )
    }

    init(draft: Item) {
        self.init(
            id: draft.id.uuidString,
            title: draft.userEditedTitle ?? draft.aiSuggestedTitle ?? "Untitled",
            price: draft.userEditedPrice ?? draft.aiSuggestedPrice
        )
    }
}

enum CrossPostSheetMode {
    /// From Review & Publish: Wonni is the real step, other platforms are extra.
    case publish
    /// From Profile: everything is on Wonni already, so an empty choice is a no-op.
    case crossPost
}

/// Pure rules shared by the sheet and its callers. No SwiftUI, unit-tested.
enum CrossPostPlan {
    static let apiPlatforms: Set<String> = ["ebay", "etsy"]

    static func countsAsPosted(_ status: String?) -> Bool {
        status == "posted" || status == "pending" || status == "active"
    }

    /// Candidates that still need `platform`.
    static func remaining(_ candidates: [CrossPostCandidate], for platform: String) -> [CrossPostCandidate] {
        candidates.filter { !$0.postedPlatforms.contains(platform) }
    }

    /// The footer line under a platform row, or nil when nothing is skipped.
    static func skipNote(_ candidates: [CrossPostCandidate], for platform: String, name: String) -> String? {
        let total = candidates.count
        let skipped = total - remaining(candidates, for: platform).count
        guard skipped > 0 else { return nil }
        if skipped == total {
            return total == 1 ? "Already on \(name)" : "All \(total) are already on \(name)"
        }
        return "\(skipped) of \(total) are already on \(name) and will be skipped"
    }

    /// A platform the user can switch on: connected if it needs a connection, and
    /// not already carrying every candidate.
    static func canSelect(_ platform: String, connected: Bool, candidates: [CrossPostCandidate]) -> Bool {
        if apiPlatforms.contains(platform) && !connected { return false }
        return !remaining(candidates, for: platform).isEmpty
    }

    /// Whether the confirm button does anything. In publish mode an empty set is
    /// still a publish (to Wonni); in cross-post mode it is nothing at all.
    static func canConfirm(_ selected: Set<String>, mode: CrossPostSheetMode) -> Bool {
        mode == .publish || !selected.isEmpty
    }

    static func displayName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "Facebook Marketplace"
        default: return platform.capitalized
        }
    }
}

struct CrossPostSheet: View {
    let candidates: [CrossPostCandidate]
    let mode: CrossPostSheetMode
    let onConfirm: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var integrationRepo = IntegrationRepository.shared
    @State private var selectedPlatforms: Set<String> = []
    /// Platforms whose toggle the user has explicitly touched. The async `.task`
    /// default-selection may still seed the others, but must never overwrite an
    /// explicit user choice made while integrations were loading (issues #8, #46).
    @State private var touchedPlatforms: Set<String> = []
    @State private var showAddressSetupSheet = false
    @State private var platformToEnableAfterAddressSetup = ""
    /// Gates the confirm button until integrations/settings finish loading, so a
    /// fast tap can't confirm with `selectedPlatforms` still empty.
    @State private var isLoadingIntegrations = true
    @State private var showEmptyPlatformsConfirm = false
    @State private var showCandidates = false

    private var isPublish: Bool { mode == .publish }

    var body: some View {
        NavigationStack {
            Form {
                candidatesSection
                platformsSection
            }
            .navigationTitle(isPublish ? "Publish Listings" : "Cross-Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoadingIntegrations {
                        ProgressView()
                    } else {
                        Button(isPublish ? "Publish" : "Post") {
                            if selectedPlatforms.isEmpty {
                                showEmptyPlatformsConfirm = true
                            } else {
                                confirm()
                            }
                        }
                        .fontWeight(.bold)
                        .disabled(!CrossPostPlan.canConfirm(selectedPlatforms, mode: mode))
                        .accessibilityIdentifier("crossPostConfirmButton")
                    }
                }
            }
            .task { await loadDefaults() }
            .sheet(isPresented: $showAddressSetupSheet) {
                AddressSetupSheet {
                    if !platformToEnableAfterAddressSetup.isEmpty {
                        selectedPlatforms.insert(platformToEnableAfterAddressSetup)
                        platformToEnableAfterAddressSetup = ""
                    }
                }
            }
            // Publish mode only: Wonni is still a real destination, so confirm it.
            // Cross-post mode never gets here — the button is disabled when empty.
            .confirmationDialog(
                "Publish to Wonni only? No cross-post platforms are selected.",
                isPresented: $showEmptyPlatformsConfirm,
                titleVisibility: .visible
            ) {
                Button("Publish to Wonni Only") { confirm() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var candidatesSection: some View {
        Section {
            HStack {
                Text(candidates.count == 1 ? "1 listing" : "\(candidates.count) listings")
                    .fontWeight(.semibold)
                Spacer()
                Button(showCandidates ? "Hide" : "Show") {
                    withAnimation { showCandidates.toggle() }
                }
                .font(.subheadline)
                .accessibilityIdentifier("crossPostShowListings")
            }
            if showCandidates {
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.title)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(candidateDetail(candidate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            if isPublish {
                Text("Every listing is also published to Wonni.")
            }
        }
    }

    private func candidateDetail(_ candidate: CrossPostCandidate) -> String {
        var parts: [String] = []
        if let price = candidate.price {
            parts.append(String(format: "$%.2f", price))
        }
        let on = candidate.postedPlatforms.sorted().map(CrossPostPlan.displayName)
        if !on.isEmpty {
            parts.append(on.joined(separator: ", "))
        }
        return parts.isEmpty ? "No price" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var platformsSection: some View {
        Section {
            if integrationRepo.integrations.isEmpty {
                Text("No integrations available. Set them up in Profile Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(integrationRepo.integrations) { integration in
                    platformRow(integration)
                }
            }
        } header: {
            Text(isPublish ? "Also post to" : "Post to")
        } footer: {
            Text(platformsFooter)
        }
    }

    private var platformsFooter: String {
        if !isPublish && selectedPlatforms.isEmpty && !isLoadingIntegrations {
            return "Choose at least one platform to post."
        }
        if isPublish {
            return "Your choice is remembered as the default for next time. Change it any time in Profile › Settings › Cross-posting."
        }
        return "Listings already on a platform are left alone. Your choice is remembered as the default for next time."
    }

    @ViewBuilder private func platformRow(_ integration: PlatformIntegration) -> some View {
        let platform = integration.platform
        let isAPI = CrossPostPlan.apiPlatforms.contains(platform)
        let name = CrossPostPlan.displayName(platform)
        let skipNote = CrossPostPlan.skipNote(candidates, for: platform, name: name)
        let selectable = CrossPostPlan.canSelect(platform, connected: integration.isConnected, candidates: candidates)
        let isOn = Binding<Bool>(
            get: { selectedPlatforms.contains(platform) },
            set: { isSelected in
                touchedPlatforms.insert(platform)
                if isSelected {
                    if isAPI && SellingSettingsRepository.shared.settings?.defaultLocation.postalCode.isEmpty != false {
                        platformToEnableAfterAddressSetup = platform
                        showAddressSetupSheet = true
                    } else {
                        selectedPlatforms.insert(platform)
                    }
                } else {
                    selectedPlatforms.remove(platform)
                }
            }
        )
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                    if !isAPI {
                        Text("Autofill")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                }
                if isAPI && !integration.isConnected {
                    Text("Not connected (Link in settings)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let skipNote {
                    Text(skipNote)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if isAPI {
                    Text("Connected as: \(integration.connectedUsername ?? "Unknown")")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(isPublish ? "Opens \(name) in the app after publishing" : "Opens \(name) in the app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // A Form Toggle only responds on the switch itself; the label — most of
            // the row — was dead space, which read as "tapping does nothing".
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if selectable { isOn.wrappedValue.toggle() } }
        }
        .disabled(!selectable)
    }

    // MARK: Actions

    private func loadDefaults() async {
        await integrationRepo.loadIntegrations()
        await SellingSettingsRepository.shared.loadSettings()
        // Preselect the remembered default set (last confirm here, or Settings);
        // first time ever, every connected API platform. Only platforms the user
        // hasn't toggled while the load was in flight, and never one every
        // candidate is already on.
        let available = integrationRepo.integrations
            .filter { CrossPostPlan.canSelect($0.platform, connected: $0.isConnected, candidates: candidates) }
            .map(\.platform)
        let defaults = CrossPostDefaults.platforms(available: available)
        for platform in defaults where !touchedPlatforms.contains(platform) {
            selectedPlatforms.insert(platform)
        }
        isLoadingIntegrations = false
    }

    private func confirm() {
        CrossPostDefaults.remember(selectedPlatforms)
        onConfirm(selectedPlatforms)
        dismiss()
    }
}
