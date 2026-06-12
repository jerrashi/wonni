//
//  AppTaskQueue.swift
//  wonni
//

import SwiftUI

@MainActor
final class AppTaskQueue: ObservableObject {
    static let shared = AppTaskQueue()
    private init() {}

    struct AppTask: Identifiable {
        let id: UUID
        var label: String
        var detail: String?
        var progress: Double    // -1 = indeterminate spinner, 0–1 = ring
        var accentColor: Color
        var onTap: (() -> Void)?
    }

    @Published private(set) var tasks: [AppTask] = []

    var current: AppTask? { tasks.first }
    var hasActiveTasks: Bool { !tasks.isEmpty }
    var count: Int { tasks.count }

    func begin(
        id: UUID,
        label: String,
        detail: String? = nil,
        progress: Double = -1,
        accentColor: Color = Color.accentColor,
        onTap: (() -> Void)? = nil
    ) {
        guard !tasks.contains(where: { $0.id == id }) else { return }
        tasks.append(AppTask(id: id, label: label, detail: detail,
                             progress: progress, accentColor: accentColor, onTap: onTap))
    }

    func update(id: UUID, label: String? = nil, detail: String? = nil, progress: Double? = nil) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let l = label { tasks[idx].label = l }
        if let d = detail { tasks[idx].detail = d }
        if let p = progress { tasks[idx].progress = p }
    }

    func complete(id: UUID) {
        tasks.removeAll { $0.id == id }
    }
}
