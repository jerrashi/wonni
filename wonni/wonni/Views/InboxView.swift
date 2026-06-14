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
    case general  = "General"
    case unread   = "Unread"
    case offers   = "Offers"
}

enum InboxSort: String, CaseIterable {
    case recent = "Recent"
    case item   = "Item"
    case user   = "User"
}

struct InboxView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var conversations: [Conversation] = []
    @State private var selectedFilter: InboxFilter = .all
    @State private var selectedSort: InboxSort = .recent
    @State private var listener: ListenerRegistration?

    private var currentUserId: String { authManager.currentUser?.uid ?? "" }

    private var filtered: [Conversation] {
        let uid = currentUserId
        let base = conversations.filter { !($0.deletedBy ?? []).contains(uid) }

        let byFilter: [Conversation]
        switch selectedFilter {
        case .all:     byFilter = base
        case .buying:  byFilter = base.filter { $0.buyerId == uid && !$0.isGeneralConversation }
        case .selling: byFilter = base.filter { $0.sellerId == uid && !$0.isGeneralConversation }
        case .general: byFilter = base.filter { $0.isGeneralConversation }
        case .unread:  byFilter = base.filter { $0.unreadCount(for: uid) > 0 }
        case .offers:  byFilter = base.filter { $0.hasActiveOffer }
        }

        switch selectedSort {
        case .recent:
            return byFilter.sorted {
                ($0.lastMessageAt?.dateValue() ?? .distantPast) > ($1.lastMessageAt?.dateValue() ?? .distantPast)
            }
        case .item:
            return byFilter.sorted { ($0.snapshotTitle ?? "") < ($1.snapshotTitle ?? "") }
        case .user:
            return byFilter.sorted {
                let nameA = $0.participantDisplayNames?[$0.buyerId == uid ? $0.sellerId : $0.buyerId] ?? ""
                let nameB = $1.participantDisplayNames?[$1.buyerId == uid ? $1.sellerId : $1.buyerId] ?? ""
                return nameA < nameB
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { startListening() }
        .onDisappear { listener?.remove() }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 0) {
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

            Menu {
                ForEach(InboxSort.allCases, id: \.self) { sort in
                    Button {
                        selectedSort = sort
                    } label: {
                        if selectedSort == sort {
                            Label(sort.rawValue, systemImage: "checkmark")
                        } else {
                            Text(sort.rawValue)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .padding(.trailing, 4)
        }
    }

    // MARK: Conversation list

    private var conversationList: some View {
        List(filtered) { conversation in
            NavigationLink(destination: ConversationView(conversation: conversation)) {
                ConversationRow(conversation: conversation, currentUserId: currentUserId)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    Task {
                        try? await ConversationRepository.shared.deleteConversation(
                            conversationId: conversation.id ?? "", userId: currentUserId)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if conversation.unreadCount(for: currentUserId) > 0 {
                    Button {
                        Task {
                            try? await ConversationRepository.shared.markAsRead(
                                conversationId: conversation.id ?? "", userId: currentUserId)
                        }
                    } label: {
                        Label("Mark Read", systemImage: "envelope.open")
                    }
                    .tint(.blue)
                } else {
                    Button {
                        Task {
                            try? await ConversationRepository.shared.markAsUnread(
                                conversationId: conversation.id ?? "", userId: currentUserId)
                        }
                    } label: {
                        Label("Mark Unread", systemImage: "envelope.badge")
                    }
                    .tint(.blue)
                }
            }
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
    private var isBuyer: Bool { conversation.buyerId == currentUserId }

    private var roleBadge: (label: String, color: Color) {
        if conversation.isGeneralConversation { return ("General", .purple) }
        return isBuyer ? ("Buying", .blue) : ("Selling", .green)
    }

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
                HStack(spacing: 5) {
                    Text(conversation.snapshotTitle ?? "Listing")
                        .font(.subheadline.weight(unread > 0 ? .semibold : .medium))
                        .lineLimit(1)
                    Text(roleBadge.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(roleBadge.color)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(roleBadge.color.opacity(0.1), in: Capsule())
                        .layoutPriority(1)
                }
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
