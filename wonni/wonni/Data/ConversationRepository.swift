//
//  ConversationRepository.swift
//  wonni
//

import Foundation
import FirebaseFirestore
import FirebaseAuth

// MARK: - Models

enum MessageType: String, Codable {
    case text
    case offer
}

enum ConversationType: String, Codable {
    case listing
    case general
}

struct Message: Identifiable, Codable {
    @DocumentID var id: String?
    var senderId: String
    var text: String?
    var sentAt: Timestamp
    var type: MessageType
    var offerAmount: Double?

    init(senderId: String, text: String? = nil, sentAt: Timestamp,
         type: MessageType, offerAmount: Double? = nil) {
        self.senderId = senderId
        self.text = text
        self.sentAt = sentAt
        self.type = type
        self.offerAmount = offerAmount
    }
}

struct Conversation: Identifiable, Codable {
    @DocumentID var id: String?
    var participants: [String]
    var buyerId: String
    var sellerId: String
    var listingId: String?
    var snapshotTitle: String?
    var snapshotCoverPath: String?
    var snapshotPrice: Double?
    var lastMessage: String?
    var lastMessageAt: Timestamp?
    var lastMessageSenderId: String?
    var hasActiveOffer: Bool
    var activeOfferAmount: Double?
    var buyerUnread: Int
    var sellerUnread: Int
    var conversationType: ConversationType?
    var participantDisplayNames: [String: String]?
    var deletedBy: [String]?

    init(participants: [String], buyerId: String, sellerId: String, listingId: String? = nil,
         snapshotTitle: String? = nil, snapshotCoverPath: String? = nil,
         snapshotPrice: Double? = nil, hasActiveOffer: Bool = false,
         activeOfferAmount: Double? = nil, buyerUnread: Int = 0, sellerUnread: Int = 0,
         conversationType: ConversationType? = nil,
         participantDisplayNames: [String: String]? = nil) {
        self.participants = participants
        self.buyerId = buyerId
        self.sellerId = sellerId
        self.listingId = listingId
        self.snapshotTitle = snapshotTitle
        self.snapshotCoverPath = snapshotCoverPath
        self.snapshotPrice = snapshotPrice
        self.hasActiveOffer = hasActiveOffer
        self.activeOfferAmount = activeOfferAmount
        self.buyerUnread = buyerUnread
        self.sellerUnread = sellerUnread
        self.conversationType = conversationType
        self.participantDisplayNames = participantDisplayNames
        self.deletedBy = []
    }

    func unreadCount(for userId: String) -> Int {
        userId == buyerId ? buyerUnread : sellerUnread
    }

    var isGeneralConversation: Bool { conversationType == .general }
}

// MARK: - ConversationRepository

class ConversationRepository {
    static let shared = ConversationRepository()
    private let db = Firestore.firestore()
    private let col = "conversations"

    private func listingConversationId(buyerId: String, listingId: String) -> String {
        "\(buyerId)_\(listingId)"
    }

    // Sorted UIDs + dm_ prefix distinguishes from listing conversation IDs
    private func directConversationId(uid1: String, uid2: String) -> String {
        let sorted = [uid1, uid2].sorted()
        return "dm_\(sorted[0])_\(sorted[1])"
    }

    func observeConversations(
        completion: @escaping (Result<[Conversation], Error>) -> Void
    ) -> ListenerRegistration? {
        guard let uid = Auth.auth().currentUser?.uid else {
            completion(.failure(NSError(domain: "ConversationRepository", code: 401)))
            return nil
        }
        return db.collection(col)
            .whereField("participants", arrayContains: uid)
            .addSnapshotListener { snapshot, error in
                if let error { completion(.failure(error)); return }
                let items = (snapshot?.documents.compactMap { try? $0.data(as: Conversation.self) } ?? [])
                    .sorted { ($0.lastMessageAt?.dateValue() ?? .distantPast) > ($1.lastMessageAt?.dateValue() ?? .distantPast) }
                completion(.success(items))
            }
    }

    func observeMessages(
        conversationId: String,
        completion: @escaping (Result<[Message], Error>) -> Void
    ) -> ListenerRegistration? {
        db.collection(col).document(conversationId)
            .collection("messages")
            .order(by: "sentAt")
            .addSnapshotListener { snapshot, error in
                if let error { completion(.failure(error)); return }
                let items = snapshot?.documents.compactMap { try? $0.data(as: Message.self) } ?? []
                completion(.success(items))
            }
    }

    func fetchConversation(id: String) async throws -> Conversation? {
        let doc = try await db.collection(col).document(id).getDocument()
        return try? doc.data(as: Conversation.self)
    }

    @discardableResult
    func getOrCreateConversation(listing: UserListing, buyerId: String,
                                 buyerDisplayName: String? = nil,
                                 sellerDisplayName: String? = nil) async throws -> String {
        guard let listingId = listing.id else {
            throw NSError(domain: "ConversationRepository", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Listing has no ID"])
        }
        let convId = listingConversationId(buyerId: buyerId, listingId: listingId)
        let ref = db.collection(col).document(convId)
        let doc = try await ref.getDocument()
        if !doc.exists {
            var names: [String: String] = [:]
            if let n = buyerDisplayName { names[buyerId] = n }
            if let n = sellerDisplayName { names[listing.userId] = n }
            let conv = Conversation(
                participants: [buyerId, listing.userId],
                buyerId: buyerId,
                sellerId: listing.userId,
                listingId: listingId,
                snapshotTitle: listing.customTitle,
                snapshotCoverPath: listing.coverPhotoPath,
                snapshotPrice: listing.price,
                conversationType: .listing,
                participantDisplayNames: names.isEmpty ? nil : names
            )
            try ref.setData(from: conv)
        }
        return convId
    }

    @discardableResult
    func getOrCreateDirectConversation(currentUserId: String, currentDisplayName: String?,
                                       otherUserId: String, otherDisplayName: String?) async throws -> String {
        let convId = directConversationId(uid1: currentUserId, uid2: otherUserId)
        let ref = db.collection(col).document(convId)
        let doc = try await ref.getDocument()
        if !doc.exists {
            var names: [String: String] = [:]
            if let n = currentDisplayName { names[currentUserId] = n }
            if let n = otherDisplayName { names[otherUserId] = n }
            let conv = Conversation(
                participants: [currentUserId, otherUserId],
                buyerId: currentUserId,
                sellerId: otherUserId,
                listingId: nil,
                snapshotTitle: otherDisplayName,
                conversationType: .general,
                participantDisplayNames: names.isEmpty ? nil : names
            )
            try ref.setData(from: conv)
        }
        return convId
    }

    func sendMessage(conversationId: String, text: String,
                     senderId: String, isBuyer: Bool) async throws {
        let convRef = db.collection(col).document(conversationId)
        let msg = Message(senderId: senderId, text: text,
                          sentAt: Timestamp(date: Date()), type: .text)
        try convRef.collection("messages").document().setData(from: msg)
        try await convRef.updateData([
            "lastMessage": text,
            "lastMessageAt": Timestamp(date: Date()),
            "lastMessageSenderId": senderId,
            isBuyer ? "sellerUnread" : "buyerUnread": FieldValue.increment(Int64(1))
        ])
    }

    func sendOffer(conversationId: String, amount: Double, senderId: String) async throws {
        let convRef = db.collection(col).document(conversationId)
        let lastText = String(format: "Offer: $%.2f", amount)
        let msg = Message(senderId: senderId, text: lastText,
                          sentAt: Timestamp(date: Date()), type: .offer, offerAmount: amount)
        try convRef.collection("messages").document().setData(from: msg)
        try await convRef.updateData([
            "lastMessage": lastText,
            "lastMessageAt": Timestamp(date: Date()),
            "lastMessageSenderId": senderId,
            "hasActiveOffer": true,
            "activeOfferAmount": amount,
            "sellerUnread": FieldValue.increment(Int64(1))
        ])
    }

    func markAsRead(conversationId: String, userId: String) async throws {
        let ref = db.collection(col).document(conversationId)
        let doc = try await ref.getDocument()
        guard let conv = try? doc.data(as: Conversation.self) else { return }
        let field = conv.buyerId == userId ? "buyerUnread" : "sellerUnread"
        try await ref.updateData([field: 0])
    }

    func markAsUnread(conversationId: String, userId: String) async throws {
        let ref = db.collection(col).document(conversationId)
        let doc = try await ref.getDocument()
        guard let conv = try? doc.data(as: Conversation.self) else { return }
        let field = conv.buyerId == userId ? "buyerUnread" : "sellerUnread"
        try await ref.updateData([field: 1])
    }

    func deleteConversation(conversationId: String, userId: String) async throws {
        let ref = db.collection(col).document(conversationId)
        try await ref.updateData(["deletedBy": FieldValue.arrayUnion([userId])])
    }
}
