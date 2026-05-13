//
//  InboxView.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore

enum InboxFilter: String, CaseIterable {
    case all      = "All"
    case buying   = "Buying"
    case selling  = "Selling"
    case unread   = "Unread"
    case offers   = "Offers"
}

struct InboxView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var conversations: [Conversation] = []
    @State private var selectedFilter: InboxFilter = .all
    @State private var listener: ListenerRegistration?

    private var currentUserId: String { authManager.currentUser?.uid ?? "" }

    private var filtered: [Conversation] {
        switch selectedFilter {
        case .all:     return conversations
        case .buying:  return conversations.filter { $0.buyerId == currentUserId }
        case .selling: return conversations.filter { $0.sellerId == currentUserId }
        case .unread:  return conversations.filter { $0.unreadCount(for: currentUserId) > 0 }
        case .offers:  return conversations.filter { $0.hasActiveOffer }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if filtered.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { startListening() }
        .onDisappear { listener?.remove() }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InboxFilter.allCases, id: \.self) { filter in
                    Button(filter.rawValue) { selectedFilter = filter }
                        .font(.subheadline.weight(selectedFilter == filter ? .semibold : .regular))
                        .foregroundStyle(selectedFilter == filter ? .white : .primary)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(
                            selectedFilter == filter ? Color.primary : Color.secondary.opacity(0.1),
                            in: Capsule()
                        )
                        .animation(.easeInOut(duration: 0.15), value: selectedFilter)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    // MARK: Conversation list

    private var conversationList: some View {
        List(filtered) { conversation in
            NavigationLink(destination: ConversationView(conversation: conversation)) {
                ConversationRow(conversation: conversation, currentUserId: currentUserId)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
        .listStyle(.plain)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "message")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No messages").font(.headline)
            Text("Your conversations with buyers and sellers will appear here.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    private func startListening() {
        listener = ConversationRepository.shared.observeConversations { result in
            if case .success(let items) = result { conversations = items }
        }
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let conversation: Conversation
    let currentUserId: String

    private var unread: Int { conversation.unreadCount(for: currentUserId) }

    private var timeText: String {
        guard let date = conversation.lastMessageAt?.dateValue() else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let path = conversation.snapshotCoverPath {
                    StorageImage(path: path).scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.snapshotTitle ?? "Listing")
                    .font(.subheadline.weight(unread > 0 ? .semibold : .medium))
                    .lineLimit(1)
                if let last = conversation.lastMessage {
                    Text(last)
                        .font(.caption)
                        .foregroundStyle(unread > 0 ? .primary : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(timeText).font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if conversation.hasActiveOffer {
                        Text("Offer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                    }
                    if unread > 0 {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                    }
                }
            }
        }
    }
}
