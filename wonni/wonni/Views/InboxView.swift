//
//  InboxView.swift
//  wonni
//

import SwiftUI
import FirebaseFirestore

enum InboxFilter: String, CaseIterable {
    case all      = "All"
    case buying   = "Buyers"
    case selling  = "Sellers"
    case search   = "Search"
    case unread   = "Unread"
    case offers   = "Offers"
}

/// Unifies conversations and saved-search match notifications into one recency-sorted feed.
private enum InboxItem: Identifiable {
    case conversation(Conversation)
    case searchMatch(SearchMatchNotification)

    var id: String {
        switch self {
        case .conversation(let c):  return "conv_\(c.id ?? UUID().uuidString)"
        case .searchMatch(let n):   return "note_\(n.id ?? UUID().uuidString)"
        }
    }

    var sortDate: Date {
        switch self {
        case .conversation(let c): return c.lastMessageAt?.dateValue() ?? .distantPast
        case .searchMatch(let n):  return n.createdAt.dateValue()
        }
    }
}

struct InboxView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var conversations: [Conversation] = []
    @State private var searchNotifications: [SearchMatchNotification] = []
    @State private var selectedFilter: InboxFilter = .all
    @State private var convListener: ListenerRegistration?
    @State private var notifListener: ListenerRegistration?

    private var currentUserId: String { authManager.currentUser?.uid ?? "" }

    private var merged: [InboxItem] {
        let items: [InboxItem] = conversations.map { .conversation($0) } + searchNotifications.map { .searchMatch($0) }
        return items.sorted { $0.sortDate > $1.sortDate }
    }

    private var filtered: [InboxItem] {
        switch selectedFilter {
        case .all:
            return merged
        case .buying:
            return merged.filter { if case .conversation(let c) = $0 { return c.buyerId == currentUserId }; return false }
        case .selling:
            return merged.filter { if case .conversation(let c) = $0 { return c.sellerId == currentUserId }; return false }
        case .search:
            return merged.filter { if case .searchMatch = $0 { return true }; return false }
        case .unread:
            return merged.filter {
                switch $0 {
                case .conversation(let c): return c.unreadCount(for: currentUserId) > 0
                case .searchMatch(let n):  return !n.isRead
                }
            }
        case .offers:
            return merged.filter { if case .conversation(let c) = $0 { return c.hasActiveOffer }; return false }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                inboxList
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { startListening() }
        .onDisappear {
            convListener?.remove()
            notifListener?.remove()
        }
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

    // MARK: Inbox list

    private var inboxList: some View {
        List(filtered) { item in
            Group {
                switch item {
                case .conversation(let conversation):
                    NavigationLink(destination: ConversationView(conversation: conversation)) {
                        ConversationRow(conversation: conversation, currentUserId: currentUserId)
                    }
                case .searchMatch(let notification):
                    Button {
                        openSearchMatch(notification)
                    } label: {
                        SearchMatchRow(notification: notification)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        }
        .listStyle(.plain)
    }

    private func openSearchMatch(_ notification: SearchMatchNotification) {
        Task { try? await SearchRepository.shared.markNotificationRead(notification) }
        uploadManager.pendingSearchQuery = notification.savedQuery
        uploadManager.selectedTab = 1
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedFilter == .search ? "bell" : "message")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text(selectedFilter == .search ? "No search alerts" : "No messages").font(.headline)
            Text(selectedFilter == .search
                 ? "You'll see an alert here when a new listing matches one of your saved searches."
                 : "Your conversations with buyers and sellers will appear here.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    private func startListening() {
        convListener = ConversationRepository.shared.observeConversations { result in
            if case .success(let items) = result { conversations = items }
        }
        notifListener = SearchRepository.shared.observeSearchNotifications { result in
            if case .success(let items) = result { searchNotifications = items }
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

// MARK: - Search Match Row

private struct SearchMatchRow: View {
    let notification: SearchMatchNotification

    private var timeText: String {
        let date = notification.createdAt.dateValue()
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
                if let path = notification.listingPhotoPath {
                    StorageImage(path: path).scaledToFill()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 56, height: 56)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("New match for \u{201C}\(notification.savedQuery)\u{201D}")
                    .font(.subheadline.weight(notification.isRead ? .medium : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(notification.listingTitle ?? "Listing")
                    .font(.caption)
                    .foregroundStyle(notification.isRead ? .secondary : .primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(timeText).font(.caption2).foregroundStyle(.secondary)
                if !notification.isRead {
                    Circle().fill(Color.blue).frame(width: 8, height: 8)
                }
            }
        }
    }
}
