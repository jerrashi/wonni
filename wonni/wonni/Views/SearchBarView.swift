//
//  SearchBarView.swift
//  wonni
//

import SwiftUI

struct SearchBarView: View {
    @State private var searchText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // ── Rounded pill ──────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15, weight: .medium))

                TextField("Search", text: $searchText)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit { isFocused = false }

                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())

            // ── Right-side button: camera (idle) or Cancel (active) ───────
            if isFocused || !searchText.isEmpty {
                Button("Cancel") {
                    searchText = ""
                    isFocused = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button {
                    // TODO: reverse image search
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: searchText.isEmpty)
    }
}

#Preview {
    SearchBarView()
        .padding(.vertical)
}
