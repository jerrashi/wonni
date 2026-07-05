//
//  SearchBarView.swift
//  wonni
//

import SwiftUI

/// Non-editable entry point that hands off to the Search tab's own text field —
/// avoids re-implementing autocomplete/trending/history here.
struct SearchBarView: View {
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15, weight: .medium))
                    Text("Search")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                // TODO: reverse image search
            } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
    }
}

#Preview {
    SearchBarView()
        .padding(.vertical)
}
