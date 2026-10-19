import AppCore
import DesignSystem
import SwiftUI

/// Activity window: long-running tasks (pull/push/build/create) with live output and cancel.
struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: LongRunningTask.ID?

    private var selected: LongRunningTask? {
        model.taskCenter.tasks.first { $0.id == selection } ?? model.taskCenter.tasks.first
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(model.taskCenter.tasks) { task in
                    TaskRow(task: task).tag(task.id)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .overlay {
                if model.taskCenter.tasks.isEmpty {
                    EmptyStateView(
                        symbol: "list.bullet.rectangle", title: "No activity",
                        message: "Pulls, pushes, builds and machine/cluster creation show up here with live output.")
                }
            }
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button("Clear finished") { model.taskCenter.clearFinished() }
                    .disabled(!model.taskCenter.tasks.contains { $0.state.isFinished })
            }
        }
        .navigationTitle("Activity")
    }

    @ViewBuilder
    private var detail: some View {
        if let task = selected {
            VStack(spacing: 0) {
                HStack(spacing: Spacing.m) {
                    Image(systemName: task.kind.symbol).font(.title2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(task.title).font(.headline)
                        Text(
                            "\(task.state.label) · \(RelativeDate.duration(task.duration)) · started \(RelativeDate.format(task.startedAt))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if task.state == .running {
                        Button("Cancel", role: .destructive) { task.cancel() }
                    }
                    CopyButton(task.buffer.text(), label: "Copy output")
                }
                .padding(Spacing.m)
                if case .failed(let error) = task.state {
                    ErrorBanner(error).padding(.horizontal, Spacing.m).padding(.bottom, Spacing.s)
                }
                Divider()
                OutputLogView(buffer: task.buffer, follow: task.state == .running, showsTimestamps: true)
            }
        } else {
            EmptyStateView(symbol: "text.alignleft", title: "Select a task", message: "Its output appears here.")
        }
    }
}

private struct TaskRow: View {
    let task: LongRunningTask

    var body: some View {
        HStack(spacing: Spacing.s) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).lineLimit(1)
                Text(task.buffer.lines.last?.text ?? task.state.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch task.state {
        case .running: ProgressView().controlSize(.small).frame(width: 16)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.statusRunning)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.statusError)
        case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(.statusStopped)
        }
    }
}
