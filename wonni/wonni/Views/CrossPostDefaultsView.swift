//
//  CrossPostDefaultsView.swift
//  wonni
//
//  Which platforms the Publish screen preselects. One stored set, two ways to
//  change it: every Publish remembers what was chosen (so nobody re-toggles the
//  same platforms each time), and this screen edits it explicitly. First time
//  ever (nothing stored yet) the default is every connected API platform, which
//  is what the Publish screen always did.
//
//  Planned, not built (user, 2026-10-13): an "AI suggested platforms" button on
//  the Publish screen that proposes a set per listing for the user to review.
//

import SwiftUI

enum CrossPostDefaults {
    static let key = "crossPostDefaultPlatforms"
    /// Distinguishes "never set" (fall back to connected API platforms) from
    /// "deliberately none" (Wonni only).
    static let hasValueKey = "crossPostDefaultPlatformsSet"

    static var stored: Set<String>? {
        guard UserDefaults.standard.bool(forKey: hasValueKey) else { return nil }
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    static func remember(_ platforms: Set<String>) {
        UserDefaults.standard.set(platforms.sorted().joined(separator: ","), forKey: key)
        UserDefaults.standard.set(true, forKey: hasValueKey)
    }

    /// The set to preselect, limited to platforms the user can actually post to
    /// (`available` = connected API platforms + the autofill ones).
    static func platforms(available: [String]) -> Set<String> {
        if let stored { return stored.intersection(available) }
        return Set(available.filter { $0 == "ebay" || $0 == "etsy" })
    }

    static let all: [(id: String, name: String)] = [
        ("ebay", "eBay"), ("etsy", "Etsy"), ("mercari", "Mercari"), ("facebook", "Facebook Marketplace")
    ]
}

struct CrossPostDefaultsView: View {
    @ObservedObject private var integrationRepo = IntegrationRepository.shared
    @State private var selected: Set<String> = []

    var body: some View {
        Form {
            Section {
                ForEach(CrossPostDefaults.all, id: \.id) { platform in
                    let integration = integrationRepo.integrations.first { $0.platform == platform.id }
                    let isAPI = platform.id == "ebay" || platform.id == "etsy"
                    let connected = integration?.isConnected == true
                    Toggle(isOn: Binding(
                        get: { selected.contains(platform.id) },
                        set: { on in
                            if on { selected.insert(platform.id) } else { selected.remove(platform.id) }
                            CrossPostDefaults.remember(selected)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(platform.name)
                            if isAPI {
                                Text(connected ? "Connected" : "Not connected — link it under Platforms")
                                    .font(.caption)
                                    .foregroundStyle(connected ? .green : .secondary)
                            } else {
                                Text("Browser autofill after publishing")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isAPI && !connected)
                }
            } header: {
                Text("Preselected when publishing")
            } footer: {
                Text("Every listing is always published to Wonni. The Publish screen starts with these platforms on, and whatever you choose there becomes the new default.")
            }
        }
        .navigationTitle("Default platforms")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await integrationRepo.loadIntegrations()
            let available = integrationRepo.integrations
                .filter { $0.isConnected || !($0.platform == "ebay" || $0.platform == "etsy") }
                .map(\.platform)
            selected = CrossPostDefaults.platforms(available: available)
        }
    }
}
