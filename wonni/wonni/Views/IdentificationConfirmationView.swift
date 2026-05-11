//
//  IdentificationConfirmationView.swift
//  wonni
//
//  Created by Antigravity on 5/7/25.
//

import SwiftUI
import UIKit

struct IdentificationConfirmationView: View {
    let listingId: String
    let images: [UIImage]
    
    @StateObject private var gemini = GeminiService.shared
    @StateObject private var repository = ListingRepository.shared
    
    @State private var result: GeminiIdentificationResponse?
    @State private var isIdentifying = true
    @State private var errorMessage: String?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack {
                if isIdentifying {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Identifying your item...")
                            .font(.headline)
                        Text("Gemini is analyzing your photos to find a catalog match.")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxHeight: .infinity)
                } else if let result = result {
                    Form {
                        Section(header: Text("Gemini Identification")) {
                            HStack {
                                Text("Name")
                                Spacer()
                                Text(result.name ?? "Unknown")
                                    .foregroundColor(.gray)
                            }
                            HStack {
                                Text("Brand")
                                Spacer()
                                Text(result.brand ?? "Unknown")
                                    .foregroundColor(.gray)
                            }
                            HStack {
                                Text("Category")
                                Spacer()
                                Text(result.category ?? "Unknown")
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }
                        
                        Section(header: Text("Description")) {
                            Text(result.description ?? "No description generated.")
                                .font(.body)
                        }
                        
                        Section(header: Text("Pricing Recommendation")) {
                            HStack {
                                Text("Suggested Price")
                                Spacer()
                                Text(result.suggestedPrice ?? 0.0, format: .currency(code: "USD"))
                                    .fontWeight(.bold)
                                    .foregroundColor(.green)
                            }
                        }
                        
                        Section {
                            Button("Confirm and Save") {
                                confirmIdentification()
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .fontWeight(.bold)
                            
                            Button("Edit Manually", role: .cancel) {
                                dismiss()
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Identification Failed")
                            .font(.headline)
                        Text(error)
                            .padding()
                        Button("Retry") {
                            identify()
                        }
                    }
                }
            }
            .navigationTitle("Confirm Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                identify()
            }
        }
    }
    
    private func identify() {
        isIdentifying = true
        errorMessage = nil
        
        Task {
            do {
                let response = try await gemini.identifyItem(images: images)
                await MainActor.run {
                    self.result = response
                    self.isIdentifying = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isIdentifying = false
                }
            }
        }
    }
    
    private func confirmIdentification() {
        guard let result = result else { return }
        
        Task {
            do {
                // Fetch the current listing
                // (In a real app, we'd have a method to fetch by ID, but for now we'll assume we update the draft we just created)
                
                // TODO: Link to /catalog if match exists
                
                // For now, just update the UserListing with the Gemini data
                // This is a placeholder for the full catalog logic
                // try await repository.updateListingWithGeminiData(id: listingId, data: result)
                
                await MainActor.run {
                    dismiss()
                }
            } catch {
                print("Error confirming identification: \(error.localizedDescription)")
            }
        }
    }
}
