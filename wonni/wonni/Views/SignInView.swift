//
//  SignInView.swift
//  wonni
//

import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var error: Error?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Branding
            VStack(spacing: 16) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)
                VStack(spacing: 6) {
                    Text("wonni")
                        .font(.largeTitle.bold())
                    Text("Buy and sell with AI")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Sign-in buttons
            VStack(spacing: 16) {
                if let pending = authManager.pendingLink {
                    Text("You already have an account signed in with \(pending.existingProviderLabel). Sign in with \(pending.existingProviderLabel) to link it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if authManager.pendingLink == nil || authManager.pendingLink?.existingProviderID == "apple.com" {
                    SignInWithAppleButton(.continue) { request in
                        authManager.prepareAppleRequest(request)
                    } onCompletion: { result in
                        Task {
                            do {
                                try await authManager.handleAppleCompletion(result)
                                if authManager.pendingLink != nil {
                                    try await authManager.finishPendingLink()
                                }
                            } catch {
                                self.error = error
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if authManager.pendingLink == nil || authManager.pendingLink?.existingProviderID == "google.com" {
                    Button {
                        Task {
                            do {
                                try await authManager.signInWithGoogle()
                                if authManager.pendingLink != nil {
                                    try await authManager.finishPendingLink()
                                }
                            } catch {
                                self.error = error
                            }
                        }
                    } label: {
                        Text("Continue with Google")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if authManager.isLoading {
                    ProgressView()
                        .padding(.top, 4)
                }

                if let err = error {
                    Text(err.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 64)
        }
    }
}
