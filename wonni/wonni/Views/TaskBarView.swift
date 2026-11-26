//
//  TaskBarView.swift
//  wonni
//
//  The app's one background-task indicator (2026-11-19, replaces the floating
//  capsule "pill"). Every background job registers with `AppTaskQueue`; this file
//  is the only place that draws it, so a redesign is a change here and nowhere else.
//
//  Bottom chrome (2026-11-19 v2, mock https://claude.ai/artifact/E7eUWbTaJMkEKhWvkwfzUq):
//  the task row is the TOP row of the screen's bottom toolbar, on the same `.bar`
//  surface, never a separate strip. Two entry points, both `.safeAreaInset(edge: .bottom)`
//  so the content above shrinks instead of being covered:
//  - `.bottomActionBar { leading } trailing: { primary }` — screens with actions. The
//    Sell flow puts ‹ Back (or Cancel) leading and Continue (or Save) trailing, nothing
//    else; every other action lives in the top bar as (Select) · title · (⋯).
//  - `.appTaskBarInset()` — the four tab stacks without a bottom toolbar (MainView); the
//    row sits directly above the tab bar.
//  Don't use the system `.toolbar(.bottomBar)` on a screen that should show tasks: its
//  layout ignores safe-area insets and the task row ends up under it.
//

import SwiftUI
import UIKit

// MARK: - Platform mark

/// A platform's name in its letter colors, for rows about one platform
/// ("2/5 Listings failed" on eBay). Drawn as text: the app ships no logo assets.
struct PlatformMark: View {
    let platform: String

    var body: some View {
        switch platform {
        case "ebay":
            ["e", "b", "a", "y"].enumerated().reduce(Text("")) { acc, pair in
                let colors: [Color] = [
                    Color(red: 0.90, green: 0.20, blue: 0.22), Color(red: 0.0, green: 0.39, blue: 0.82),
                    Color(red: 0.96, green: 0.69, blue: 0.01), Color(red: 0.53, green: 0.72, blue: 0.09),
                ]
                return acc + Text(pair.element).foregroundColor(colors[pair.offset])
            }
            .font(.system(size: 17, weight: .heavy))
            .kerning(-0.6)
            .accessibilityLabel("eBay")
        case "etsy":
            Text("Etsy").font(.system(size: 15, weight: .heavy, design: .serif))
                .foregroundStyle(Color(red: 0.95, green: 0.33, blue: 0.0))
        default:
            Text(platform.capitalized).font(.caption.weight(.bold))
        }
    }
}

// MARK: - The bar

/// Thin, full-width row: status icon, label (+ detail), "+N" for queued tasks, chevron.
/// A determinate task also draws a 2 pt progress line along the bottom edge.
struct TaskBar: View {
    let task: AppTaskQueue.AppTask
    let queueCount: Int
    var onExpand: () -> Void = {}

    static let height: CGFloat = 32

    private var tint: Color { task.isError ? .red : task.accentColor }

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 14, height: 14)
                Text(task.label)
                    .foregroundStyle(task.isError ? Color.red : Color.primary)
                    .layoutPriority(1)
                if let detail = task.detail, !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if queueCount > 1 {
                    Text("+\(queueCount - 1)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { progressLine }
        .accessibilityElement(children: .combine)
        .accessibilityHint(queueCount > 1 ? "Shows all \(queueCount) tasks" : "Opens this task")
        .accessibilityIdentifier("appTaskBar")
        .animation(.easeInOut(duration: 0.2), value: task.label)
        .animation(.easeInOut(duration: 0.2), value: task.isError)
    }

    @ViewBuilder private var statusIcon: some View {
        if task.isError {
            Image(systemName: "exclamationmark.circle.fill")
                .resizable()
                .foregroundStyle(.red)
        } else if task.progress < 0 {
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
        } else {
            ZStack {
                Circle().stroke(tint.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: task.progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .animation(.linear(duration: 0.3), value: task.progress)
        }
    }

    @ViewBuilder private var progressLine: some View {
        if !task.isError, task.progress >= 0 {
            GeometryReader { geo in
                Rectangle()
                    .fill(tint)
                    .frame(width: geo.size.width * min(max(task.progress, 0), 1), height: 2)
                    .animation(.linear(duration: 0.3), value: task.progress)
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Host (the task row inside every bottom bar)

/// Shows the queue's current task, with no background of its own (the bar it sits in
/// owns the surface). Tap: a single task opens its own screen, several
/// open the activity list. Hidden while the keyboard is up, so it never rides above
/// the keyboard and steals height from the field being typed into.
struct AppTaskBarHost: View {
    @ObservedObject private var queue = AppTaskQueue.shared
    @EnvironmentObject private var uploadManager: UploadManager
    @State private var showActivity = false
    @State private var keyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if queue.hasActiveTasks, !keyboardVisible, let task = queue.current {
                TaskBar(task: task, queueCount: queue.count) {
                    if queue.count == 1 {
                        task.onTap?()
                    } else {
                        showActivity = true
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: queue.hasActiveTasks)
        .animation(.easeInOut(duration: 0.2), value: keyboardVisible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .sheet(isPresented: $showActivity) {
            NavigationStack { AppTaskActivityView() }
                .environmentObject(uploadManager)
        }
    }
}

// MARK: - Bottom toolbar

/// The app's one bottom toolbar: the task row (only while a task runs) above one row of
/// actions, on a single `.bar` surface with one divider on top.
struct BottomActionBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            AppTaskBarHost()
            HStack(spacing: 12) {
                leading
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Capsule buttons for `BottomActionBar`. `.primary` is the screen's one forward action.
/// iOS 26: Liquid Glass (user 2026-11-20), tinted with the accent color for `.primary`,
/// matching the system's own glass toolbar buttons in the top bar. Earlier iOS keeps
/// the filled capsules.
struct BottomBarButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, destructive }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.body.weight(kind == .primary ? .semibold : .regular))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(minHeight: 40)
        if #available(iOS 26.0, *) {
            label
                .glassEffect(kind == .primary ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                             in: Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
        } else {
            label
                .background(Capsule().fill(background))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .contentShape(Capsule())
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .destructive: return .red
        case .secondary: return .accentColor
        }
    }

    private var background: Color {
        kind == .primary ? .accentColor : Color(.tertiarySystemFill)
    }
}

/// ‹ Back — leading slot of every Sell-flow bottom bar.
struct BackBarButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
                Text("Back")
            }
        }
        .buttonStyle(BottomBarButtonStyle(kind: .secondary))
    }
}

/// The trailing primary action. One word across the Sell flow ("Continue", user
/// 2026-11-19); `isBusy` shows a spinner in place of nothing else changing.
struct PrimaryBarButton: View {
    var title: String = "Continue"
    var isBusy: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy { ProgressView().tint(.white).controlSize(.small) }
                Text(title)
            }
        }
        .buttonStyle(BottomBarButtonStyle(kind: .primary))
    }
}

extension View {
    /// Pins the app's bottom toolbar (task row + actions) under this screen.
    func bottomActionBar<L: View, T: View>(
        @ViewBuilder leading: () -> L,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            BottomActionBar(leading: leading, trailing: trailing)
        }
    }

    /// Task row only, for a tab's NavigationStack: it sits directly above the tab bar on
    /// the same bar material, and appears only while a task runs.
    func appTaskBarInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            TaskRowSurface()
        }
    }
}

/// The task row on its own bar surface; collapses to nothing when no task runs.
private struct TaskRowSurface: View {
    @ObservedObject private var queue = AppTaskQueue.shared
    var body: some View {
        AppTaskBarHost()
            .background(.bar)
            .overlay(alignment: .top) {
                if queue.hasActiveTasks { Divider() }
            }
    }
}
