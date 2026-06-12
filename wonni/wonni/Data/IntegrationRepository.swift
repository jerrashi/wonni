//
//  IntegrationRepository.swift
//  wonni
//
//  Manages API integration states (Etsy, eBay, etc.) in Firestore.
//

import Foundation
import FirebaseFirestore
import FirebaseAuth
import FirebaseFunctions

public struct PlatformIntegration: Codable, Identifiable {
    public var id: String { platform }
    public var platform: String          // "ebay", "etsy", "mercari", "facebook"
    public var isConnected: Bool
    public var connectedUsername: String?
    public var connectedAt: Date?
    public var oauthCode: String?
    
    public init(platform: String, isConnected: Bool, connectedUsername: String? = nil, connectedAt: Date? = nil, oauthCode: String? = nil) {
        self.platform = platform
        self.isConnected = isConnected
        self.connectedUsername = connectedUsername
        self.connectedAt = connectedAt
        self.oauthCode = oauthCode
    }
}

@MainActor
public class IntegrationRepository: ObservableObject {
    public static let shared = IntegrationRepository()
    private let db = Firestore.firestore()
    private let usersCollection = "users"
    private let integrationsSubcollection = "integrations"
    
    @Published public var integrations: [PlatformIntegration] = []
    @Published public var isLoading = false
    
    private init() {}
    
    private var userId: String? {
        Auth.auth().currentUser?.uid
    }
    
    /// Loads all integrations for the current user from Firestore.
    /// If documents don't exist, returns default disconnected states.
    public func loadIntegrations() async {
        guard let uid = userId else {
            let platforms = ["ebay", "etsy", "mercari", "facebook"]
            self.integrations = platforms.map { PlatformIntegration(platform: $0, isConnected: false) }
            return
        }
        
        self.isLoading = true
        
        do {
            let snapshot = try await db.collection(usersCollection)
                .document(uid)
                .collection(integrationsSubcollection)
                .getDocuments()
            
            var loaded: [String: PlatformIntegration] = [:]
            for doc in snapshot.documents {
                if let platform = doc.data()["platform"] as? String {
                    let isConnected = doc.data()["isConnected"] as? Bool ?? false
                    let username = doc.data()["connectedUsername"] as? String
                    let date = (doc.data()["connectedAt"] as? Timestamp)?.dateValue()
                    let oauthCode = doc.data()["oauthCode"] as? String
                    
                    loaded[platform] = PlatformIntegration(
                        platform: platform,
                        isConnected: isConnected,
                        connectedUsername: username,
                        connectedAt: date,
                        oauthCode: oauthCode
                    )
                }
            }
            
            // Build full list with defaults for missing integrations
            let platforms = ["ebay", "etsy", "mercari", "facebook"]
            let finalIntegrations = platforms.map { p in
                loaded[p] ?? PlatformIntegration(platform: p, isConnected: false)
            }
            
            self.integrations = finalIntegrations
            self.isLoading = false
        } catch {
            print("[IntegrationRepository] Error loading integrations: \(error)")
            let platforms = ["ebay", "etsy", "mercari", "facebook"]
            self.integrations = platforms.map { PlatformIntegration(platform: $0, isConnected: false) }
            self.isLoading = false
        }
    }
    
    /// Unlinks an active platform connection.
    public func unlinkPlatform(platform: String) async throws {
        guard let uid = userId else { return }
        
        try await db.collection(usersCollection)
            .document(uid)
            .collection(integrationsSubcollection)
            .document(platform)
            .delete()
        
        await loadIntegrations()
    }
    
    /// Stub function to link a platform by writing a connection state document directly to Firestore.
    /// In production, this would call your Firebase Cloud Function backend to perform OAuth exchange.
    public func linkPlatformWithMock(platform: String, username: String, oauthCode: String? = nil) async throws {
        print("[IntegrationRepository] linkPlatformWithMock platform: \(platform), username: \(username)")
        guard let uid = userId else {
            print("[IntegrationRepository] linkPlatformWithMock failed: userId is nil")
            return
        }
        
        var data: [String: Any] = [
            "platform": platform,
            "isConnected": true,
            "connectedUsername": username,
            "connectedAt": FieldValue.serverTimestamp()
        ]
        
        if let code = oauthCode {
            data["oauthCode"] = code
        }
        
        do {
            try await db.collection(usersCollection)
                .document(uid)
                .collection(integrationsSubcollection)
                .document(platform)
                .setData(data, merge: true)
            print("[IntegrationRepository] linkPlatformWithMock successfully wrote to Firestore")
        } catch {
            print("[IntegrationRepository] linkPlatformWithMock write error: \(error)")
            throw error
        }
        
        await loadIntegrations()
    }
    
    /// Exchanges the OAuth authorization code for a real eBay access token
    /// via the `ebayExchangeToken` Cloud Function, then reloads integrations.
    public func linkPlatformWithCode(platform: String, code: String) async throws {
        print("[IntegrationRepository] linkPlatformWithCode platform: \(platform), code: \(code.prefix(12))...")
        guard userId != nil else {
            print("[IntegrationRepository] linkPlatformWithCode failed: userId is nil")
            return
        }

        self.isLoading = true
        defer { self.isLoading = false }

        guard platform == "ebay",
              let ruName = Bundle.main.object(forInfoDictionaryKey: "EbayRuName") as? String,
              !ruName.isEmpty else {
            // Non-eBay platforms fall back to mock linking
            let mockUsername = "\(platform.capitalized)User_\(code.prefix(6))"
            try await linkPlatformWithMock(platform: platform, username: mockUsername, oauthCode: code)
            return
        }

        let isSandbox = ruName.lowercased().contains("sbx") || ruName.lowercased().contains("sandbox")

        let functions = Functions.functions()
        let result = try await functions.httpsCallable("ebayExchangeToken").call([
            "code":      code,
            "ruName":    ruName,
            "isSandbox": isSandbox,
        ])

        if let data = result.data as? [String: Any] {
            print("[IntegrationRepository] ebayExchangeToken succeeded: \(data)")
        }

        await loadIntegrations()
    }
    
    // MARK: - Mercari Shipping Preferences

    /// Loads the seller's saved Mercari shipping preferences from Firestore so they sync across
    /// devices. Returns nil if the user has never configured them (caller should collect them).
    /// Stored at `users/{uid}/settings/mercariShipping`.
    public func loadMercariShippingPreferences() async -> (acceptSuggestions: Bool, mode: String, carriers: [String])? {
        guard let uid = userId else { return nil }
        do {
            let doc = try await db.collection(usersCollection)
                .document(uid)
                .collection("settings")
                .document("mercariShipping")
                .getDocument()
            guard doc.exists, let data = doc.data() else { return nil }
            let accept = data["acceptSuggestions"] as? Bool ?? true
            let mode = data["mode"] as? String ?? "cheapestPrepaid"
            let carriers = data["carriers"] as? [String] ?? ["usps"]
            return (accept, mode, carriers)
        } catch {
            print("[IntegrationRepository] loadMercariShippingPreferences error: \(error)")
            return nil
        }
    }

    /// Persists the seller's Mercari shipping preferences to Firestore for cross-device sync.
    public func saveMercariShippingPreferences(acceptSuggestions: Bool, mode: String, carriers: [String]) async {
        guard let uid = userId else { return }
        do {
            try await db.collection(usersCollection)
                .document(uid)
                .collection("settings")
                .document("mercariShipping")
                .setData([
                    "acceptSuggestions": acceptSuggestions,
                    "mode": mode,
                    "carriers": carriers,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
        } catch {
            print("[IntegrationRepository] saveMercariShippingPreferences error: \(error)")
        }
    }

    /// Submits a cross-post event to the backend.
    public func triggerCrossPost(listingId: String, platforms: [String]) async throws {
        print("[IntegrationRepository] Triggering cross-post for listing \(listingId) to \(platforms)")
        
        let functions = Functions.functions()
        for platform in platforms {
            // Map each API-based platform to its Cloud Function. Mercari/Facebook are not
            // API-driven (they post via in-app web autofill), so they're skipped here.
            let fn: String
            switch platform {
            case "ebay": fn = "ebayCreateListing"
            case "etsy": fn = "etsyCreateListing"
            default:
                print("[IntegrationRepository] Stub trigger for platform: \(platform)")
                continue
            }
            do {
                let result = try await functions.httpsCallable(fn).call(["listingId": listingId])
                print("[IntegrationRepository] \(fn) succeeded: \(result.data)")
            } catch {
                print("[IntegrationRepository] \(fn) failed: \(error.localizedDescription)")
                throw error
            }
        }
    }
}

/// Fire-and-forget invocation of a Firebase callable function.
///
/// `HTTPSCallableResult` is not `Sendable`, so awaiting `.call(...)` and bringing
/// the result back into an actor-isolated context (e.g. a `Task {}` on the main
/// actor) is an error in Swift 6. This `nonisolated` helper consumes the result
/// locally and only ever exposes `Sendable` types (`[String: String]` in, `Bool`
/// out), so the non-Sendable value never crosses an isolation boundary.
@discardableResult
func callCloudFunction(_ name: String, _ data: [String: String] = [:]) async throws -> Bool {
    _ = try await Functions.functions().httpsCallable(name).call(data)
    return true
}

@discardableResult
func callCloudFunction(_ name: String, _ data: [String: Any]) async throws -> Bool {
    _ = try await Functions.functions().httpsCallable(name).call(data)
    return true
}
