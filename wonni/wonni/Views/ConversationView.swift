//
//  ConversationView.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore

// MARK: - Conversation View

struct ConversationView: View {
    let conversation: Conversation

    @EnvironmentObject private var authManager: AuthManager
    @State private var messages: [Message] = []
    @State private var messageText = ""
    @State private var showOfferSheet = false
    @State private var showRoleActionAlert = false
    @State private var listener: ListenerRegistration?

    private var currentUserId: String { authManager.currentUser?.uid ?? "" }
    private var isBuyer: Bool { conversation.buyerId == currentUserId }
    private var conversationId: String { conversation.id ?? "" }
    private var otherUserId: String { isBuyer ? conversation.sellerId : conversation.buyerId }
    
    @State private var otherProfile: UserPublicProfile?

    var body: some View {
        VStack(spacing: 0) {
            listingHeader
            Divider()
            messageList
            Divider()
            inputBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack {
                    ZStack {
                        Circle().fill(Color.blue.opacity(0.12)).frame(width: 28, height: 28)
                        Text(otherProfile?.displayName?.prefix(1).uppercased() ?? String(otherUserId.prefix(1)).uppercased())
                            .font(.caption2.bold()).foregroundStyle(.blue)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(otherProfile?.displayName ?? "User")
                            .font(.subheadline.bold())
                        Text(conversation.snapshotTitle ?? "Listing")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { startListening() }
        .task {
            otherProfile = try? await UserRepository.shared.fetchProfile(uid: otherUserId)
        }
        .onDisappear { listener?.remove() }
        .alert("Coming Soon", isPresented: $showRoleActionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This feature is coming soon.")
        }
        .sheet(isPresented: $showOfferSheet) {
            MakeOfferSheet(currentPrice: conversation.snapshotPrice) { amount in
                Task { try? await ConversationRepository.shared.sendOffer(
                    conversationId: conversationId, amount: amount, senderId: currentUserId
                )}
            }
        }
    }

    // MARK: Listing header

    private var listingHeader: some View {
        HStack(spacing: 10) {
            Group {
                if let path = conversation.snapshotCoverPath {
                    StorageImage(path: path).scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 40, height: 40)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.snapshotTitle ?? "Listing")
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                if let price = conversation.snapshotPrice {
                    Text(String(format: "$%.2f", price))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
                        if message.type == .offer {
                            OfferCard(message: message, conversation: conversation,
                                      currentUserId: currentUserId)
                        } else {
                            MessageBubble(message: message,
                                          isOwn: message.senderId == currentUserId)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            if isBuyer {
                Button { showOfferSheet = true } label: {
                    Text("Offer")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button { showRoleActionAlert = true } label: {
                    Text("Received")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button { showRoleActionAlert = true } label: {
                    Text("Shipped")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            TextField("Message...", text: $messageText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))

            Button { Task { await sendMessage() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(
                        messageText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.blue
                    )
            }
            .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Helpers

    private func startListening() {
        guard !conversationId.isEmpty else { return }
        Task { try? await ConversationRepository.shared.markAsRead(
            conversationId: conversationId, userId: currentUserId) }
        listener = ConversationRepository.shared.observeMessages(conversationId: conversationId) { result in
            if case .success(let items) = result { messages = items }
        }
    }

    private func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        try? await ConversationRepository.shared.sendMessage(
            conversationId: conversationId, text: text,
            senderId: currentUserId, isBuyer: isBuyer
        )
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    let isOwn: Bool

    var body: some View {
        HStack {
            if isOwn { Spacer(minLength: 60) }
            Text(message.text ?? "")
                .font(.subheadline)
                .foregroundStyle(isOwn ? .white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    isOwn ? Color.blue : Color(.systemGray5),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            if !isOwn { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Offer Card

struct OfferCard: View {
    let message: Message
    let conversation: Conversation
    let currentUserId: String

    private var isSeller: Bool { conversation.sellerId == currentUserId }
    private var isLatestActiveOffer: Bool {
        conversation.hasActiveOffer && conversation.activeOfferAmount == message.offerAmount
    }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("Offer").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                if let amount = message.offerAmount {
                    Text(String(format: "$%.2f", amount)).font(.title2.bold())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color.orange.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
            )

            if isSeller && isLatestActiveOffer {
                HStack(spacing: 10) {
                    Button("Decline") {
                        // offer decline — future
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 10))
                    .buttonStyle(.plain)

                    Button("Accept") {
                        // offer accept — future
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 10))
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Make Offer Sheet

struct MakeOfferSheet: View {
    let currentPrice: Double?
    let onSubmit: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""

    private var parsedAmount: Double? {
        let cleaned = amountText.filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, let val = Double(cleaned), val > 0 else { return nil }
        return val
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let price = currentPrice {
                    Text(String(format: "Listed at $%.2f", price))
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("$").font(.title.bold()).foregroundStyle(.secondary)
                    TextField("0.00", text: $amountText)
                        .font(.system(size: 52, weight: .bold))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding(.horizontal, 32).padding(.top, 32)
            .navigationTitle("Make an Offer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        if let amount = parsedAmount {
                            onSubmit(amount)
                            dismiss()
                        }
                    }
                    .disabled(parsedAmount == nil)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

