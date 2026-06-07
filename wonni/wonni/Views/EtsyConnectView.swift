//
//  EtsyConnectView.swift
//  wonni
//
//  Created for Etsy API integration.
//

import SwiftUI
import AuthenticationServices
import FirebaseFunctions
import FirebaseAuth
import FirebaseFirestore
import CryptoKit

public struct EtsyConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    
    // State to hold the active web authentication session to prevent deallocation
    @State private var activeSession: ASWebAuthenticationSession?
    @State private var anchorProvider = EtsyWebAuthPresentationAnchor()
    
    // Etsy Branding Colors
    private let etsyOrange = Color(red: 226/255, green: 88/255, blue: 34/255)
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 24) {
            // Logo / Icon Header
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(etsyOrange.opacity(0.12))
                        .frame(width: 96, height: 96)
                    
                    Text("E")
                        .font(.system(size: 64, weight: .bold, design: .serif))
                        .foregroundColor(etsyOrange)
                }
                .padding(.top, 40)
                
                Text("Connect Etsy Shop")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.primary)
                
                Text("Cross-post your listings directly to your Etsy shop with one tap. Wonni manages the inventory and details automatically.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            Spacer()
            
            // Status and Messages
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding(.vertical, 8)
                }
                
                if let errorMessage = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .slide))
                }
                
                if let successMessage = successMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(successMessage)
                            .font(.subheadline)
                            .foregroundColor(.green)
                            .fontWeight(.semibold)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut, value: errorMessage)
            .animation(.easeInOut, value: successMessage)
            
            Spacer()
            
            // Action Buttons
            VStack(spacing: 14) {
                Button(action: startEtsyOAuthFlow) {
                    HStack {
                        Text(isLoading ? "Connecting..." : "Link Etsy Account")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [etsyOrange, etsyOrange.opacity(0.9)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(14)
                    .shadow(color: etsyOrange.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .disabled(isLoading)
                .padding(.horizontal, 24)
                
                Button("Cancel") {
                    dismiss()
                }
                .font(.body.weight(.medium))
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
        }
        .padding(.vertical)
        .background(Color(.systemGroupedBackground))
    }
    
    // MARK: - OAuth Flow
    
    private func startEtsyOAuthFlow() {
        isLoading = true
        errorMessage = nil
        successMessage = nil
        
        // Load Client ID
        let clientId = (Bundle.main.object(forInfoDictionaryKey: "EtsyClientId") as? String) ?? ""
        if clientId.isEmpty {
            print("[EtsyConnectView] Warning: EtsyClientId key is not set in Info.plist yet.")
        }
        
        // Generate PKCE Verifier & Challenge
        let codeVerifier = EtsyPKCEHelper.generateCodeVerifier()
        let codeChallenge = EtsyPKCEHelper.generateCodeChallenge(from: codeVerifier)
        
        // Build Auth URL
        let redirectUri = "wonni://oauth/etsy"
        let state = UUID().uuidString.prefix(8) // CSRF Token state
        
        var components = URLComponents(string: "https://www.etsy.com/oauth/connect")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId.isEmpty ? "YOUR_ETSY_CLIENT_ID" : clientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "scope", value: "listings_w listings_r shops_r"),
            URLQueryItem(name: "state", value: String(state)),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        
        guard let authURL = components.url else {
            errorMessage = "Could not construct Etsy Auth URL."
            isLoading = false
            return
        }
        
        print("[EtsyConnectView] Starting session with URL: \(authURL.absoluteString)")
        
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "wonni"
        ) { callbackURL, error in
            Task { @MainActor in
                self.activeSession = nil
                
                if let error = error {
                    print("[EtsyConnectView] Auth session error: \(error.localizedDescription)")
                    if (error as NSError).code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                    }
                    self.isLoading = false
                    return
                }
                
                guard let callbackURL = callbackURL else {
                    self.errorMessage = "Invalid redirect response."
                    self.isLoading = false
                    return
                }
                
                print("[EtsyConnectView] Redirect URL: \(callbackURL.absoluteString)")
                
                let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
                if let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value {
                    print("[EtsyConnectView] Code successfully extracted.")
                    await exchangeCode(code: code, verifier: codeVerifier, redirectUri: redirectUri)
                } else {
                    self.errorMessage = "Authorization code not returned."
                    self.isLoading = false
                }
            }
        }
        
        session.presentationContextProvider = anchorProvider
        session.prefersEphemeralWebBrowserSession = false
        self.activeSession = session
        
        session.start()
    }
    
    // Call the Firebase Cloud Function to exchange the token
    private func exchangeCode(code: String, verifier: String, redirectUri: String) async {
        do {
            let functions = Functions.functions()
            let result = try await functions.httpsCallable("etsyExchangeToken").call([
                "code": code,
                "codeVerifier": verifier,
                "redirectUri": redirectUri
            ])
            
            if let data = result.data as? [String: Any],
               let shopName = data["shopName"] as? String {
                self.successMessage = "Successfully connected to shop: \(shopName)!"
                // Delay dismissal slightly so they see the success message
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    dismiss()
                }
            } else {
                self.errorMessage = "Failed to parse connection response."
            }
        } catch {
            print("[EtsyConnectView] Cloud Function error: \(error)")
            self.errorMessage = error.localizedDescription
        }
        self.isLoading = false
    }
}

// MARK: - PKCE Helper

struct EtsyPKCEHelper {
    static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result == errSecSuccess {
            return Data(bytes).base64URLEncodedString()
        } else {
            // fallback
            let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
            return String((0..<64).map { _ in chars.randomElement()! })
        }
    }
    
    static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .ascii) else { return "" }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        return self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation Provider

class EtsyWebAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
