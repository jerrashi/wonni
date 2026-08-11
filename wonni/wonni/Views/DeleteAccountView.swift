//
//  DeleteAccountView.swift
//  wonni
//

import SwiftUI

/// Explains the soft-delete grace period (#62) and, on confirm, calls
/// `AuthManager.requestAccountDeletion()`. Presented from `SettingsSheet`'s
/// Account section.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @StateObject private var integrationRepo = IntegrationRepository.shared

    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    // eBay/Etsy have no account-deauthorization API today (see #62 plan) —
    // we can only link out. Mercari is web-automation-only, and account
    // deletion is deliberately never scripted through that fragile path.
    private let accountManagementURLs: [String: URL] = [
        "ebay": URL(string: "https://www.ebay.com/help/home")!,
        "etsy": URL(string: "https://www.etsy.com/your/account")!,
        "mercari": URL(string: "https://www.mercari.com/settings/")!,
    ]

    private func platformDisplayName(_ platform: String) -> String {
        switch platform {
        case "ebay": return "eBay"
        case "etsy": return "Etsy"
        case "mercari": return "Mercari"
        case "facebook": return "Facebook Marketplace"
        default: return platform.capitalized
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Deleting your Wonni account:")
                        .font(.headline)
                    Label("Hides your listings and profile from everyone immediately.", systemImage: "eye.slash")
                    Label("Permanently erases your account after 30 days.", systemImage: "clock")
                    Label("Any sale still in progress or within its return window is completed first — deletion is delayed until it's settled.", systemImage: "shippingbox")
                    Label("Buyers who purchased from you through Wonni keep access to what they bought, even after your account is gone.", systemImage: "person.crop.circle.badge.checkmark")
                    Label("Your saved Mercari/eBay/Etsy sales records are personal bookkeeping only — they're deleted permanently and can't be recovered.", systemImage: "trash")
                }

                let connected = integrationRepo.integrations.filter { $0.isConnected }
                if !connected.isEmpty {
                    Section("Connected platform accounts") {
                        Text("Wonni can't delete or disconnect these accounts for you — manage them directly if you want to close them too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(connected, id: \.platform) { integration in
                            if let url = accountManagementURLs[integration.platform] {
                                Link(destination: url) {
                                    HStack {
                                        Text(platformDisplayName(integration.platform))
                                        Spacer()
                                        Image(systemName: "arrow.up.right")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                            } else {
                                Text("Delete My Account")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isDeleting)
                }
            }
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Delete Account?", isPresented: $showConfirm) {
                Button("Delete", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This starts the 30-day deletion process described above. This cannot be undone once it completes.")
            }
            .alert("Couldn't Delete Account", isPresented: .constant(errorMessage != nil), presenting: errorMessage) { _ in
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        do {
            try await authManager.requestAccountDeletion()
        } catch {
            errorMessage = error.localizedDescription
        }
        isDeleting = false
    }
}
