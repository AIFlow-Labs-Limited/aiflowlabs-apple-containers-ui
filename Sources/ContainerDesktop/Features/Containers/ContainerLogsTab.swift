import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

/// Logs tab: follow / wrap / timestamps / boot-log toggles, search with match count and next/previous,
/// save, copy, clear. The stream lives in `ContainerLogsModel` and stops when the tab disappears.
struct ContainerLogsTab: View {
    let container: Container
    @Environment(AppModel.self) private var model
    @State private var logs = ContainerLogsModel()
    @AppStorage("containers.logs.follow") private var follow = true
    @AppStorage("containers.logs.wrap") private var wrap = true
    @AppStorage("containers.logs.timestamps") private var timestamps = false
    @State private var boot = false
    @State private var query = ""
    @State private var currentMatch = 0

    private var matches: [Int] { logs.buffer.matches(query) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let error = logs.error {
                ErrorBanner(error, retry: restart).padding(Spacing.s)
            }
            if logs.buffer.isEmpty {
                EmptyStateView(symbol: "text.alignleft", title: logs.isStreaming ? "Waiting for output…" : "No output",
                               message: boot ? "The VM boot log is empty." : "This container has not written anything to stdout or stderr.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                LogConsole(buffer: logs.buffer, wrap: wrap, timestamps: timestamps, follow: follow && query.isEmpty,
                           query: query, matches: matches, currentMatch: currentMatch)
            }
        }
        .task(id: "\(container.id)|\(boot)|\(container.isRunning)") { restart() }
        .onDisappear { logs.stop() }
        .onChange(of: query) { currentMatch = 0 }
    }

    private func restart() {
        logs.start(backend: model.backend, id: container.id, follow: container.isRunning && !boot, boot: boot)
    }

    private var controls: some View {
        HStack(spacing: Spacing.s) {
            Toggle(isOn: $follow) { Label("Follow", systemImage: "arrow.down.to.line") }
                .help("Keep scrolled to the newest line")
            Toggle(isOn: $wrap) { Label("Wrap", systemImage: "text.word.spacing") }
                .help("Wrap long lines")
            Toggle(isOn: $timestamps) { Label("Timestamps", systemImage: "clock") }
                .help("Prefix each line with the local time it was received")
            Toggle(isOn: $boot) { Label("Boot log", systemImage: "power") }
                .help("Show the VM boot log instead of the process output")
            Divider().frame(height: 16)
            SearchField(text: $query, prompt: "Search logs")
                .frame(maxWidth: 220)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(currentMatch, matches.count - 1) + 1) of \(matches.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize()
                Button { step(-1) } label: { SwiftUI.Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                    .accessibilityLabel("Previous match")
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(matches.isEmpty)
                Button { step(1) } label: { SwiftUI.Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
                    .accessibilityLabel("Next match")
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(matches.isEmpty)
            }
            Spacer(minLength: 0)
            if logs.isStreaming {
                ProgressView().controlSize(.small).help("Streaming")
            }
            Text("\(logs.buffer.count) lines").font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            Button { copyToPasteboard(logs.buffer.text(timestamps: timestamps)) } label: { SwiftUI.Image(systemName: "doc.on.doc") }
                .help("Copy all").accessibilityLabel("Copy all lines")
            Button(action: save) { SwiftUI.Image(systemName: "square.and.arrow.down") }
                .help("Save log…").accessibilityLabel("Save log")
            Button { logs.clear() } label: { SwiftUI.Image(systemName: "clear") }
                .help("Clear the view").accessibilityLabel("Clear")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs + 2)
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = (min(currentMatch, matches.count - 1) + delta + matches.count) % matches.count
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = "Save Log"
        panel.nameFieldStringValue = "\(container.id)\(boot ? "-boot" : "").log"
        panel.allowedContentTypes = [.log, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(logs.buffer.text(timestamps: timestamps).utf8).write(to: url, options: .atomic)
            model.toasts.success("Saved log", message: url.lastPathComponent)
        } catch {
            model.toasts.error("Could not save log", message: error.localizedDescription)
        }
    }
}

/// Monospaced lazy log view with stable row ids, wrap on/off, match highlighting and scroll-to-match.
private struct LogConsole: View {
    let buffer: LogRingBuffer
    let wrap: Bool
    let timestamps: Bool
    let follow: Bool
    let query: String
    let matches: [Int]
    let currentMatch: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bottomID = -1

    var body: some View {
        let base = buffer.droppedCount
        let matchSet = Set(matches)
        let current = matches.isEmpty ? nil : matches[min(currentMatch, matches.count - 1)]
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(buffer.lines.enumerated()), id: \.offset) { index, line in
                        row(line, highlighted: matchSet.contains(index), current: index == current)
                            .id(base + index)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: buffer.totalAppended) {
                guard follow else { return }
                scroll(proxy, to: Self.bottomID, anchor: .bottom)
            }
            .onChange(of: current) {
                if let current { scroll(proxy, to: base + current, anchor: .center) }
            }
            .onAppear { if follow { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Container log, \(buffer.count) lines")
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: Int, anchor: UnitPoint) {
        if reduceMotion { proxy.scrollTo(id, anchor: anchor) } else {
            withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    private func row(_ line: OutputLine, highlighted: Bool, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if timestamps {
                Text(LogRingBuffer.timestamp(line.timestamp)).foregroundStyle(.tertiary)
            }
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.stream == .stderr ? AnyShapeStyle(.statusError) : AnyShapeStyle(.primary))
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: false)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        }
        .font(.monoCaption)
        .textSelection(.enabled)
        .padding(.vertical, 1)
        .background(current ? Color.accentColor.opacity(0.35) : (highlighted ? Color.yellow.opacity(0.25) : .clear))
    }
}

#Preview("Logs") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    let c = Container(id: "api", configuration: .init(
        id: "api", image: ImageReference(reference: "acdemo-api:latest", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
        creationDate: .now, initProcess: .init(executable: "uvicorn")), status: .init(state: .running, startedDate: .now))
    ContainerLogsTab(container: c)
        .appModelEnvironment(model)
        .frame(width: 900, height: 400)
}
