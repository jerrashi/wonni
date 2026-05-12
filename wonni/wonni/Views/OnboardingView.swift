//
//  OnboardingView.swift
//  wonni
//

import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var page = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "tag.fill",
            color: .blue,
            title: "Welcome to Wonni",
            description: "The fastest way to sell what you own. AI identifies your items, suggests prices, and gets your listings live in seconds."
        ),
        OnboardingPage(
            icon: "photo.stack.fill",
            color: .indigo,
            title: "Select Your Photos",
            description: "Tap Sell, then choose photos from your library. Group multiple shots of the same item into one listing — just tap the stack icon."
        ),
        OnboardingPage(
            icon: "wand.and.sparkles",
            color: .purple,
            title: "AI Fills in the Details",
            description: "Wonni reads your photos and suggests a title and price. Tap the title to edit it. Tap the $ icon to set your own price."
        ),
        OnboardingPage(
            icon: "arrow.up.circle.fill",
            color: .green,
            title: "Upload and Track",
            description: "Tap Upload All. A pill at the bottom tracks progress — tap it anytime to see details. Your listings go live automatically."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    OnboardingPageView(page: pages[i])
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Dot indicators
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: i == page ? 20 : 7, height: 7)
                        .animation(.spring(response: 0.3), value: page)
                }
            }
            .padding(.bottom, 28)

            // Next / Get Started button
            Button {
                if page < pages.count - 1 {
                    withAnimation(.easeInOut(duration: 0.3)) { page += 1 }
                } else {
                    hasSeenOnboarding = true
                }
            } label: {
                Text(page < pages.count - 1 ? "Next" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(pages[page].color)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 52)
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let color: Color
    let title: String
    let description: String
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(page.color.opacity(0.12))
                    .frame(width: 140, height: 140)
                Image(systemName: page.icon)
                    .font(.system(size: 64))
                    .foregroundStyle(page.color)
            }
            .padding(.bottom, 36)

            Text(page.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            Text(page.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            Spacer()
        }
    }
}
