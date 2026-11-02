//
//  MercariSettingsView.swift
//  wonni
//
//  Every Mercari preference on one page (mock approved 2026-11-02): Smart Pricing,
//  what "sold out" does on Mercari, and the autofill shipping choices, with the
//  carrier checklist on a small sub-page. Replaces MercariShippingPreferencesView,
//  and is also the one-time setup shown before the first Mercari cross-post
//  (`isFirstTimeSetup`).
//
//  Storage is unchanged so nothing migrates: the AppStorage keys below are the local
//  cache the Mercari autofill reads, and IntegrationRepository syncs the same values
//  to `users/{uid}/settings/mercariShipping`. The only new field is `soldOutAction`.
//  "Use Mercari labels" off = ShippingMode.shipOnOwn; on = cheapestPrepaid when every
//  carrier is checked, else cheapestAmongCarriers with the checked set.
//

import SwiftUI

struct MercariSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("mercariAcceptSuggestions") private var acceptSuggestions = true
    @AppStorage("mercariShippingMode") private var shippingModeRaw = ShippingMode.cheapestPrepaid.rawValue
    @AppStorage("mercariSelectedCarriers") private var selectedCarriersRaw = Carrier.usps.rawValue
    @AppStorage("mercariPrefsConfigured") private var prefsConfigured = false
    @AppStorage("mercariKeepSmartPricing") private var keepSmartPricingStored = false
    @AppStorage(MercariSoldOutAction.storageKey) private var soldOutActionRaw = MercariSoldOutAction.deactivate.rawValue

    /// When true, shown as one-time setup before the first cross-post (vs. editing in Settings).
    var isFirstTimeSetup = false
    var onSaved: (() -> Void)?

    // Local editing copies, committed on Save.
    @State private var smartPricing = false
    @State private var soldOutAction: MercariSoldOutAction = .deactivate
    @State private var useMercariLabels = true
    @State private var acceptSuggestionsLocal = true
    @State private var carriers: Set<Carrier> = Set(Carrier.allCases)

    var body: some View {
        Form {
            Section {
                Toggle("Smart Pricing", isOn: $smartPricing)
                    .accessibilityIdentifier("mercariSmartPricingToggle")
            } header: {
                Text("Pricing")
            } footer: {
                Text("Listings under $10 always have Smart Pricing off. Mercari's minimum smart price is $9.")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How to handle sold out listings?")
                    Picker("Sold out action", selection: $soldOutAction) {
                        ForEach(MercariSoldOutAction.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("mercariSoldOutActionPicker")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Sold out")
            } footer: {
                Text("Deactivate keeps the listing's likes and views for a restock. Delete removes it from Mercari, and a restock posts it again from scratch. Applies to sold-out runs you start and to sell-outs after a sale on another platform.")
            }

            Section {
                Toggle("Use Mercari labels", isOn: $useMercariLabels)
                Toggle("Use Mercari's suggested weight & label", isOn: $acceptSuggestionsLocal)
                NavigationLink {
                    PreferredCarriersView(carriers: $carriers)
                } label: {
                    HStack {
                        Text("Preferred Shipping Carriers")
                        Spacer()
                        Text(carriersSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .disabled(!useMercariLabels)
            } header: {
                Text("Shipping")
            } footer: {
                Text(useMercariLabels
                     ? "We pick the cheapest label among your preferred carriers."
                     : "You ship on your own: no Mercari label is chosen.")
            }
        }
        .navigationTitle(isFirstTimeSetup ? "Mercari setup" : "Mercari")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isFirstTimeSetup ? "Continue" : "Save") { save() }
                    .disabled(useMercariLabels && carriers.isEmpty)
            }
        }
        .onAppear(perform: loadLocal)
    }

    private var carriersSummary: String {
        if carriers.count == Carrier.allCases.count { return "All" }
        return Carrier.allCases.filter(carriers.contains).map(\.displayName).joined(separator: ", ")
    }

    private func loadLocal() {
        smartPricing = keepSmartPricingStored
        soldOutAction = MercariSoldOutAction(rawValue: soldOutActionRaw) ?? .deactivate
        acceptSuggestionsLocal = acceptSuggestions
        let mode = ShippingMode(rawValue: shippingModeRaw) ?? .cheapestPrepaid
        useMercariLabels = mode != .shipOnOwn
        let parsed = Set(selectedCarriersRaw.split(separator: ",").compactMap { Carrier(rawValue: String($0)) })
        carriers = mode == .cheapestAmongCarriers && !parsed.isEmpty ? parsed : Set(Carrier.allCases)
    }

    private func save() {
        let mode = Self.shippingMode(useMercariLabels: useMercariLabels, carriers: carriers)
        let carrierList = Carrier.allCases.filter(carriers.contains).map(\.rawValue)
        keepSmartPricingStored = smartPricing
        soldOutActionRaw = soldOutAction.rawValue
        acceptSuggestions = acceptSuggestionsLocal
        shippingModeRaw = mode.rawValue
        selectedCarriersRaw = carrierList.joined(separator: ",")
        prefsConfigured = true
        Task {
            await IntegrationRepository.shared.saveMercariShippingPreferences(
                acceptSuggestions: acceptSuggestionsLocal, mode: mode.rawValue, carriers: carrierList,
                keepSmartPricing: smartPricing, soldOutAction: soldOutAction.rawValue
            )
        }
        onSaved?()
        dismiss()
    }

    /// Labels off = ship on your own; every carrier = cheapest overall; a subset =
    /// cheapest among those. Pure so it can be tested.
    static func shippingMode(useMercariLabels: Bool, carriers: Set<Carrier>) -> ShippingMode {
        guard useMercariLabels else { return .shipOnOwn }
        return carriers.count >= Carrier.allCases.count ? .cheapestPrepaid : .cheapestAmongCarriers
    }
}

struct PreferredCarriersView: View {
    @Binding var carriers: Set<Carrier>

    var body: some View {
        Form {
            Section {
                ForEach(Carrier.allCases) { carrier in
                    Toggle(carrier.displayName, isOn: Binding(
                        get: { carriers.contains(carrier) },
                        set: { isOn in
                            if isOn { carriers.insert(carrier) } else { carriers.remove(carrier) }
                        }
                    ))
                }
            } footer: {
                Text("We pick the cheapest label among these. Leave all on for the cheapest label overall.")
            }
        }
        .navigationTitle("Preferred Shipping Carriers")
        .navigationBarTitleDisplayMode(.inline)
    }
}
