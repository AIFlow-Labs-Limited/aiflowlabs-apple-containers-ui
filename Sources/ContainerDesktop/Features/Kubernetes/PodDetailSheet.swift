import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Tabs of the pod detail sheet.
enum PodDetailTab: String, CaseIterable, Identifiable {
    case overview, logs

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// One pod: its containers (image, state, restarts), recent events and logs. The pod is looked up in the store
/// on every render, so the sheet follows the polls and says so when the pod is gone.
struct PodDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let route: PodRoute
    let onDelete: (KubePod) -> Void

    @State private var tab: PodDetailTab
    @State private var events: [KubeEvent] = []
    @State private var eventsError: BackendError?
    @State private var eventsLoaded = false

    init(route: PodRoute, onDelete: @escaping (KubePod) -> Void) {
        self.route = route
        self.onDelete = onDelete
        _tab = State(initialValue: route.tab)
    }

    private var store: ClusterWorkloadsStore { model.workloads }

    var body: some View {
        VStack(spacing: 0) {
            if let pod = store.pod(id: route.id) {
                titleBar(pod)
                Divider()
                switch tab {
                case .overview: overview(pod)
                case .logs: PodLogsView(pod: pod)
                }
            } else {
                ContentUnavailableView {
                    Label("This pod is gone", systemImage: "shippingbox")
                } description: {
                    Text(
                        "“\(route.id)” no longer exists in the cluster. A deployment's pods get a new name when they are replaced."
                    )
                } actions: {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 600)
    }

    private func titleBar(_ pod: KubePod) -> some View {
        HStack(spacing: Spacing.s) {
            StatusDot(pod.health.tint, size: 10, label: pod.statusText)
            Text(pod.name).font(.title3.bold()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            TagBadge(pod.namespace)
            Text(pod.statusText)
                .font(.callout)
                .foregroundStyle(pod.health == .failing ? AnyShapeStyle(.statusError) : AnyShapeStyle(.secondary))
            Spacer(minLength: Spacing.m)
            Picker("Tab", selection: $tab) {
                ForEach(PodDetailTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("Delete…", systemImage: "trash", role: .destructive) { onDelete(pod) }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.m)
    }

    // MARK: Overview

    private func overview(_ pod: KubePod) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if pod.health == .failing, let message = pod.statusMessage {
                    InfoCard(title: pod.statusText, symbol: "exclamationmark.triangle", tint: .statusError) {
                        Text(message).textSelection(.enabled)
                    }
                }
                InspectorSection("Pod") { KeyValueGrid(summary(pod)) }
                InspectorSection("Containers") { containers(pod) }
                InspectorSection("Events") { eventList }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A restart or a new status means new events.
        .task(id: "\(pod.id)|\(pod.statusText)|\(pod.restartCount)") { await loadEvents(pod) }
    }

    private func summary(_ pod: KubePod) -> [(String, String)] {
        var rows: [(String, String)] = [("Namespace", pod.namespace), ("Node", pod.nodeName ?? emDash)]
        if let ip = pod.status?.podIP { rows.append(("Pod IP", ip)) }
        rows.append(("Controlled by", pod.ownerName ?? "nothing (a bare pod)"))
        rows.append(("Ready", pod.readyText))
        rows.append(("Restarts", pod.restartsText()))
        if let created = pod.metadata.creationTimestamp {
            rows.append(("Created", "\(RelativeDate.absolute(created)) (\(KubeAge.format(since: created) ?? ""))"))
        }
        return rows
    }

    private func containers(_ pod: KubePod) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
            GridRow {
                ForEach(["Container", "Image", "State", "Restarts", "Last instance"], id: \.self) {
                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(containerRows(pod)) { row in
                GridRow {
                    HStack(spacing: Spacing.xs) {
                        StatusDot(row.tint, size: 6)
                        Text(row.name).font(.callout.monospaced()).lineLimit(1)
                    }
                    Text(row.image).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .help(row.image)
                    Text(row.state).font(.callout).lineLimit(1)
                    Text(row.restarts).font(.callout).monospacedDigit()
                    Text(row.last).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private struct ContainerRow: Identifiable {
        let id: String
        let name: String
        let image: String
        let state: String
        let restarts: String
        let last: String
        let tint: Color
    }

    /// One row per declared container, with its status when the kubelet has reported one.
    private func containerRows(_ pod: KubePod) -> [ContainerRow] {
        let statuses = Dictionary(pod.containerStatuses.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let names = (pod.spec?.containers ?? []).map(\.name)
        let all = names + pod.containerStatuses.map(\.name).filter { !names.contains($0) }
        return all.map { name in
            let status = statuses[name]
            let image = status?.image ?? pod.spec?.containers?.first { $0.name == name }?.image ?? emDash
            let tint: Color =
                status?.ready == true
                ? .statusRunning : (status?.state?.running != nil ? .statusWarning : pod.health.tint)
            return ContainerRow(
                id: name, name: name, image: image, state: status?.stateText ?? "Not started",
                restarts: "\(status?.restartCount ?? 0)", last: status?.lastStateText ?? emDash, tint: tint)
        }
    }

    // MARK: Events

    @ViewBuilder
    private var eventList: some View {
        if let eventsError {
            ErrorBanner(eventsError)
        } else if !eventsLoaded {
            ProgressView().controlSize(.small)
        } else if events.isEmpty {
            Text("No recent events. Kubernetes keeps events for about an hour.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(events.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        SwiftUI.Image(systemName: event.isWarning ? "exclamationmark.triangle.fill" : "circle.fill")
                            .font(event.isWarning ? .caption : .system(size: 5))
                            .foregroundStyle(event.isWarning ? AnyShapeStyle(.statusWarning) : AnyShapeStyle(.tertiary))
                            .frame(width: 14)
                            .accessibilityLabel(event.isWarning ? "Warning" : "Normal")
                        Text(event.reasonText).font(.callout.weight(.medium)).frame(width: 110, alignment: .leading)
                        AgeText(date: event.lastSeen).font(.callout).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(event.message ?? "").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func loadEvents(_ pod: KubePod) async {
        do {
            events = try await store.events(for: pod)
            eventsError = nil
        } catch {
            let wrapped = BackendError(wrapping: error)
            if wrapped != .cancelled { eventsError = wrapped }
        }
        eventsLoaded = true
    }
}

#Preview("Pod detail") {
    @Previewable @State var model = AppModel(backend: MockBackend(kubernetes: .modern), observeAppActivation: false)
    PodDetailSheet(route: PodRoute(id: "shop/worker", tab: .overview)) { _ in }
        .appModelEnvironment(model)
        .task {
            await model.clusters.refresh()
            model.workloads.show(model.clusters.items.first { $0.isRunning })
        }
}
