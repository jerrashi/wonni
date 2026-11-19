//
//  TaskBarView.swift
//  wonni
//
//  The app's one background-task indicator (2026-11-19, replaces the floating
//  capsule "pill"). Every background job registers with `AppTaskQueue`; this file
//  is the only place that draws it, so a redesign is a change here and nowhere else.
//
//  Placement rule: `MainView` stacks `AppTaskBarHost` UNDER the TabView in a VStack,
//  so the TabView itself gets shorter while a task runs. Its tab bar, every pushed
//  screen's bottom toolbar (Photos › Proceed) and every safe-area inset end above
//  the bar, so the bar can never cover a control. The old per-tab
//  `.safeAreaInset` pill did not compose with pushed screens' system toolbars and
//  covered the Photos screen's Proceed button.
//

import SwiftUI
import UIKit

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
        .overlay(alignment: .top) { Divider() }
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

// MARK: - Host (mounted once, in MainView)

/// Shows the queue's current task. Tap: a single task opens its own screen, several
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
                .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom))
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
