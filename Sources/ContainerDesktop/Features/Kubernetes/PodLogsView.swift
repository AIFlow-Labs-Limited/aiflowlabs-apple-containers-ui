import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// A pod's logs: per container, the current or the previous instance, followed while the container runs.
/// The stream and the console are the ones the container Logs tab uses (`ContainerLogsModel`, `LogConsole`).
struct PodLogsView: View {
    let pod: KubePod
    @Environment(AppModel.self) private var model
    @State private var logs = ContainerLogsModel()
    @State private var container: String?
    @State private var previous = false
    @State private var query = ""
    @State private var currentMatch = 0
    @AppStorage("kubernetes.logs.follow") private var follow = true
    @AppStorage("kubernetes.logs.wrap") private var wrap = true
    @AppStorage("kubernetes.logs.timestamps") private var timestamps = false

    private var store: ClusterWorkloadsStore { model.workloads }
    private var containerNames: [String] { (pod.spec?.containers ?? []).map(\.name) }
    private var selectedContainer: String? { container ?? containerNames.first }
    private var selectedStatus: KubePod.ContainerStatus? {
        pod.containerStatuses.first { $0.name == selectedContainer }
    }
    /// `kubectl logs --follow` only makes sense while the container runs.
    private var streams: Bool { !previous && selectedStatus?.state?.running != nil }
    private var options: PodLogOptions {
        PodLogOptions(container: selectedContainer, follow: streams, previous: previous)
    }
    private var command: String {
        store.command(for: .logs(namespace: pod.namespace, pod: pod.name, options: options)) ?? ""
    }

    var body: some View {
        let matches = logs.matches
        VStack(spacing: 0) {
            controls(matches: matches)
            Divider()
            if let error = logs.error {
                ErrorBanner(error, retry: restart).padding(Spacing.s)
            }
            if logs.buffer.isEmpty {
                EmptyStateView(
                    symbol: "text.alignleft", title: logs.isStreaming ? "Waiting for output…" : "No output",
                    message: previous
                        ? "The previous instance of this container left no log."
                        : "This container has not written anything to stdout or stderr."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            } else {
                LogConsole(
                    logs: logs, wrap: wrap, timestamps: timestamps, follow: follow && query.isEmpty,
                    current: matches.isEmpty ? nil : matches[min(currentMatch, matches.count - 1)])
            }
        }
        // A restarted container is a new log; so is another container or the previous instance.
        .task(id: "\(pod.id)|\(selectedContainer ?? "")|\(previous)|\(selectedStatus?.restartCount ?? 0)|\(streams)") {
            restart()
        }
        .onDisappear { logs.stop() }
        .onChange(of: query) {
            logs.setQuery(query); currentMatch = 0
        }
    }

    private func restart() {
        logs.start(stream: store.logs(for: pod, options: options))
    }

    private func controls(matches: [Int]) -> some View {
        HStack(spacing: Spacing.s) {
            if containerNames.count > 1 {
                Picker("Container", selection: Binding(get: { selectedContainer ?? "" }, set: { container = $0 })) {
                    ForEach(containerNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Container")
            } else if let name = selectedContainer {
                Text(name).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Toggle(isOn: $previous) { Label("Previous", systemImage: "clock.arrow.circlepath") }
                .labelStyle(.titleAndIcon)
                .help("Show the previous instance of the container (the one that crashed) instead of the current one")
                .disabled(selectedStatus?.hasPreviousInstance != true && !previous)
            Divider().frame(height: 16)
            Toggle(isOn: $follow) { Label("Follow", systemImage: "arrow.down.to.line") }
                .help("Keep scrolled to the newest line")
            Toggle(isOn: $wrap) { Label("Wrap", systemImage: "text.word.spacing") }
                .help("Wrap long lines")
            Toggle(isOn: $timestamps) { Label("Timestamps", systemImage: "clock") }
                .help("Prefix each line with the local time the app received it")
            SearchField(text: $query, prompt: "Search logs").frame(maxWidth: 200)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(currentMatch, matches.count - 1) + 1) of \(matches.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                Button {
                    step(1, matches: matches)
                } label: {
                    SwiftUI.Image(systemName: "chevron.down")
                }
                .help("Next match (⌘G)").accessibilityLabel("Next match")
                .keyboardShortcut("g", modifiers: .command)
                .disabled(matches.isEmpty)
            }
            Spacer(minLength: 0)
            if logs.isStreaming { ProgressView().controlSize(.small).help("Streaming") }
            Text("\(logs.buffer.count) lines").font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            Button(action: restart) { SwiftUI.Image(systemName: "arrow.clockwise") }
                .help("Read the log again").accessibilityLabel("Reload log")
            Button {
                copyToPasteboard(logs.buffer.text(timestamps: timestamps))
            } label: {
                SwiftUI.Image(systemName: "doc.on.doc")
            }
            .help("Copy the \(logs.buffer.count) lines in view").accessibilityLabel("Copy lines")
            Button {
                copyToPasteboard(command)
                model.toasts.info("Copied command", message: command)
            } label: {
                SwiftUI.Image(systemName: "terminal")
            }
            .help("Copy the command: \(command)").accessibilityLabel("Copy logs command")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs + 2)
    }

    private func step(_ delta: Int, matches: [Int]) {
        guard !matches.isEmpty else { return }
        currentMatch = (min(currentMatch, matches.count - 1) + delta + matches.count) % matches.count
    }
}
