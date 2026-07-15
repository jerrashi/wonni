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
        /// When true, the pill renders in an error/red state and the activity row
        /// shows a "Retry" button instead of "View". The task stays in `tasks`
        /// (not moved to `recentlyCompleted`) until dismissed via `dismiss(id:)`.
        var isError: Bool = false
        var onTap: (() -> Void)?
        /// For queued-but-not-yet-running tasks: tapping opens a cancel confirmation.
        /// Nil for active tasks.
        var onCancel: (() -> Void)?
    }

    @Published private(set) var tasks: [AppTask] = []
    // Screens that render the pill inline in their own bottom stack (e.g. alongside a
    // local toast) set this so MainView's global per-tab pill doesn't also render and
    // overlap it — pushed navigationDestination content doesn't compose safe-area-wise
    // with the tab's outer .safeAreaInset, so without this the two pills stack as a ZStack.
    @Published var suppressGlobalPill = false
    // Short history the activity view (Q3) shows below the live queue, so a job that just
    // finished doesn't just vanish with no confirmation. Capped small — this is a glance
    // list, not a log.
    @Published private(set) var recentlyCompleted: [AppTask] = []
    private let recentlyCompletedLimit = 5

    var current: AppTask? { tasks.first }
    var hasActiveTasks: Bool { !tasks.isEmpty }
    var count: Int { tasks.count }

    func begin(
        id: UUID,
        label: String,
        detail: String? = nil,
        progress: Double = -1,
        accentColor: Color = Color.accentColor,
        onTap: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        guard !tasks.contains(where: { $0.id == id }) else { return }
        tasks.append(AppTask(id: id, label: label, detail: detail,
                             progress: progress, accentColor: accentColor,
                             onTap: onTap, onCancel: onCancel))
    }

    func update(id: UUID, label: String? = nil, detail: String? = nil, progress: Double? = nil, isError: Bool? = nil) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let l = label { tasks[idx].label = l }
        if let d = detail { tasks[idx].detail = d }
        if let p = progress { tasks[idx].progress = p }
        if let e = isError { tasks[idx].isError = e }
    }

    func complete(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        // Error tasks stay in the active queue so the pill keeps showing the retry
        // affordance. They are only removed via dismiss(id:) after the user acts.
        guard !tasks[idx].isError else { return }
        var finished = tasks[idx]
        finished.progress = 1
        finished.onTap = nil
        recentlyCompleted.insert(finished, at: 0)
        if recentlyCompleted.count > recentlyCompletedLimit {
            recentlyCompleted.removeLast(recentlyCompleted.count - recentlyCompletedLimit)
        }
        tasks.remove(at: idx)
    }

    /// Removes an error task from the active queue without adding it to recentlyCompleted.
    /// Call this after the user taps "Retry" or explicitly dismisses a failed task.
    func dismiss(id: UUID) {
        tasks.removeAll { $0.id == id }
    }
}
