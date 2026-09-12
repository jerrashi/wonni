//
//  SalesBoardView.swift
//  wonni
//
//  Tap-to-move (no drag) version of web's Sales.jsx board view — one column
//  per saleStages entry, horizontally scrollable. iOS step of
//  docs/specs/2026-09-11-stage-board-and-revenue-accounting.md §6.
//
//  Self-contained: takes sales/stages as input and reports taps/moves via
//  callbacks, so it doesn't need to know about SalesDashboardView's syncing,
//  filtering, or Firestore listeners.
//

import SwiftUI

struct SalesBoardView: View {
    let sales: [Sale]
    let stages: [SaleStage]
    var onTapSale: (Sale) -> Void
    var onMove: (Sale, SaleStage) -> Void

    @State private var movingSaleId: String?

    /// `stages` plus one extra column per orphan status found among `sales`
    /// (a status that doesn't match any current bucket key — a deleted
    /// custom bucket, or stages not loaded yet) — so a sale never silently
    /// disappears from the board. Mirrors web's per-row fallback, just
    /// applied once for the whole column set instead of per-card.
    private var columns: [SaleStage] {
        let orphanKeys = Set(sales.map { $0.status.rawValue }).subtracting(stages.map { $0.key })
        guard !orphanKeys.isEmpty else { return stages }
        return stages + orphanKeys.sorted().map { SaleStage(key: $0, label: $0.capitalized, builtIn: false) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns) { stage in
                    column(for: stage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func column(for stage: SaleStage) -> some View {
        let stageSales = sales.filter { $0.status.rawValue == stage.key }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stage.label.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(stageSales.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if stageSales.isEmpty {
                Text("No sales")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(stageSales) { sale in
                        card(for: sale)
                    }
                }
            }
        }
        .frame(width: 220, alignment: .top)
    }

    private func card(for sale: Sale) -> some View {
        Button {
            onTapSale(sale)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(sale.listingTitle ?? "Manual sale")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack {
                    Text(Sale.platformDisplayName(sale.platform))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "$%.2f", sale.priceSoldFor * Double(sale.quantity ?? 1)))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(movingSaleId == sale.id ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(columns) { target in
                if target.key != sale.status.rawValue {
                    Button(target.label) {
                        movingSaleId = sale.id
                        onMove(sale, target)
                    }
                }
            }
        }
    }
}
