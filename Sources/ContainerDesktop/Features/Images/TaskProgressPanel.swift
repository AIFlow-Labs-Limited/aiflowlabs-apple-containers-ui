import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Live status + output of one or more `LongRunningTask`s, embedded in Pull / Push / Build sheets. The same tasks
/// also appear in the Activity window.
struct TaskProgressPanel: View {
    let tasks: [LongRunningTask]

    private var lines: [OutputLine] {
        if tasks.count == 1 { return tasks[0].lines }
        return tasks.flatMap { [OutputLine("── \($0.title) ──")] + $0.lines }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(tasks) { task in
                HStack(spacing: Spacing.s) {
                    TaskStateIcon(state: task.state)
                    Text(task.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(task.state.label).font(.caption).foregroundStyle(.secondary)
                    if task.state == .running {
                        Button("Cancel") { task.cancel() }
                            .controlSize(.small)
                            .accessibilityLabel("Cancel \(task.title)")
                    }
                }
                .accessibilityElement(children: .combine)
                if case .failed(let error) = task.state, let message = error.errorDescription {
                    Text(message).font(.caption).foregroundStyle(.statusError).textSelection(.enabled).lineLimit(4)
                }
            }
            OutputLogView(lines: lines, follow: true, showsSearchField: false)
                .frame(minHeight: 160, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(.separator))
            Text("Also shown in the Activity window — closing this sheet does not stop the task.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Spinner / check / cross for a task state.
struct TaskStateIcon: View {
    let state: LongRunningTask.State

    var body: some View {
        switch state {
        case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.statusRunning).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.statusError).accessibilityLabel("Failed")
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.statusStopped).accessibilityLabel("Cancelled")
        }
    }
}
