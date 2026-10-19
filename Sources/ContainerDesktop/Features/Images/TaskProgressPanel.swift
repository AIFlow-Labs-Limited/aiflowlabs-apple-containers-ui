import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Live status + output of one or more `LongRunningTask`s, embedded in Pull / Push / Build sheets. The same tasks
/// also appear in the Activity window.
struct TaskProgressPanel: View {
    let tasks: [LongRunningTask]

    /// Several tasks are merged into one list with a header per task (each already capped at `maxLines`).
    private var mergedLines: [OutputLine] {
        tasks.flatMap { [OutputLine("── \($0.title) ──")] + $0.buffer.lines }
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
            Group {
                if tasks.count == 1 {
                    OutputLogView(buffer: tasks[0].buffer, follow: true, showsSearchField: false)
                } else {
                    OutputLogView(lines: mergedLines, follow: true, showsSearchField: false)
                }
            }
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

extension OutputLogView {
    /// Feeds the view from a ring buffer (e.g. `LongRunningTask.buffer`): stable row ids while old lines are
    /// trimmed, and following keyed on `totalAppended` so it keeps working once the buffer is full.
    init(buffer: LogRingBuffer, follow: Bool = true, filter: String = "", showsSearchField: Bool = true,
         showsTimestamps: Bool = false) {
        self.init(lines: buffer.lines, firstLineNumber: buffer.droppedCount, totalAppended: buffer.totalAppended,
                  follow: follow, filter: filter, showsSearchField: showsSearchField, showsTimestamps: showsTimestamps)
    }
}
