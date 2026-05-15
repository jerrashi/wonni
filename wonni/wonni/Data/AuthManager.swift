//
//  AuthManager.swift
//  wonni
//

import Foundation
import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices
import CryptoKit

@MainActor
class AuthManager: ObservableObject {
    @Published var currentUser: User? = Auth.auth().currentUser
    @Published var isLoading = false

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    init() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                self?.currentUser = user
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    // MARK: - Sign in with Apple

    /// Called from SignInWithAppleButton's onRequest closure to set the nonce.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    /// Called from SignInWithAppleButton's onCompletion closure to finish Firebase sign-in.
    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) async throws {
        isLoading = true
        defer { isLoading = false }

        let authorization = try result.get()

        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8),
              let nonce = currentNonce else {
            throw AuthError.invalidCredential
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )

        let authResult = try await Auth.auth().signIn(with: credential)
        currentUser = authResult.user
        
        // Sync profile to Firestore
        try? await UserRepository.shared.syncProfile()
    }
    
    // MARK: - Update Profile
    
    func updateDisplayName(_ name: String) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthError.invalidCredential }
        let changeRequest = user.createProfileChangeRequest()
        changeRequest.displayName = name
        try await changeRequest.commitChanges()
        
        // Refresh local user state
        if let updatedUser = Auth.auth().currentUser {
            Task { @MainActor in
                self.currentUser = updatedUser
            }
        }
        
        // Sync to public profile
        try await UserRepository.shared.syncProfile()
    }

    // MARK: - Sign out

    func signOut() throws {
        try Auth.auth().signOut()
    }

    // MARK: - Nonce helpers
    // The nonce is SHA-256 hashed before sending to Apple, then verified by Firebase
    // to prevent replay attacks.

    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("SecRandomCopyBytes failed: \(errorCode)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

enum AuthError: LocalizedError {
    case invalidCredential
    var errorDescription: String? { "Invalid Apple ID credential." }
}

// MARK: - User Repository

struct UserPublicProfile: Codable {
    var displayName: String?
    var email: String?
    var username: String?
    var photoURL: String?
}

class UserRepository {
    static let shared = UserRepository()
    private let db = Firestore.firestore()
    
    private let usersCollection = "users"
    
    /// Syncs the current user's profile to Firestore.
    func syncProfile() async throws {
        guard let user = Auth.auth().currentUser else { return }
        
        // We only want to update displayName and email here, and NOT overwrite existing username/photoURL
        try await db.collection(usersCollection).document(user.uid).setData([
            "displayName": user.displayName ?? "",
            "email": user.email ?? ""
        ], merge: true)
    }
    
    /// Updates username and/or photoURL independently
    func updateCustomProfile(username: String?, photoURL: String?) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        
        let batch = db.batch()
        let userRef = db.collection(usersCollection).document(uid)
        var data: [String: Any] = [:]
        
        let currentProfile = try await fetchProfile(uid: uid)
        let oldUsername = currentProfile?.username
        
        if let newUsername = username {
            data["username"] = newUsername
            
            if oldUsername != newUsername {
                // Free up the old username if there was one
                if let old = oldUsername {
                    let oldRef = db.collection("usernames").document(old)
                    batch.deleteDocument(oldRef)
                }
                
                // Claim the new username
                let newRef = db.collection("usernames").document(newUsername)
                batch.setData(["userId": uid], forDocument: newRef)
            }
        } else if let old = oldUsername {
            // Username was cleared
            data["username"] = FieldValue.delete()
            let oldRef = db.collection("usernames").document(old)
            batch.deleteDocument(oldRef)
        }
        
        if let photoURL = photoURL { data["photoURL"] = photoURL }
        
        if !data.isEmpty {
            batch.setData(data, forDocument: userRef, merge: true)
            try await batch.commit()
        }
    }
    
    /// Fetches a user's public profile by their UID.
    func fetchProfile(uid: String) async throws -> UserPublicProfile? {
        let doc = try await db.collection(usersCollection).document(uid).getDocument()
        return try? doc.data(as: UserPublicProfile.self)
    }
}

