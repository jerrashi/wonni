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
                SignInWithAppleButton(.continue) { request in
                    authManager.prepareAppleRequest(request)
                } onCompletion: { result in
                    Task {
                        do {
                            try await authManager.handleAppleCompletion(result)
                        } catch {
                            self.error = error
                        }
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12))

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
