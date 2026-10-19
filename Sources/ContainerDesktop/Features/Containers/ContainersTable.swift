import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// The containers `Table`: sortable columns, persisted column visibility/order, project groups as
/// disclosure rows, context menus, Return/double-click opens the detail pane.
struct ContainersTable: View {
    @Environment(AppModel.self) private var model
    @Bindable var ui: ContainersUIState
    let rows: [ContainerRow]
    let actions: ContainerActions

    /// `TableColumnCustomization` is Codable; persisted as JSON in `@AppStorage` (visibility, order, widths).
    @AppStorage("containers.table.columns") private var columnsData = Data()
    @State private var columns = TableColumnCustomization<ContainerRow>()
    @State private var didLoadColumns = false

    var body: some View {
        Table(of: ContainerRow.self, selection: $ui.selection, sortOrder: $ui.sortOrder, columnCustomization: $columns)
        {
            TableColumn("Name", value: \.name) { ContainerNameCell(row: $0) }
                .width(min: 120, ideal: 150)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Image", value: \.imageShort) { row in
                Text(row.imageShort).foregroundStyle(.secondary).lineLimit(1).help(row.imageFull)
            }
            .width(min: 100, ideal: 160)
            .customizationID("image")
            TableColumn("Status", value: \.statusRank) { row in
                Text(row.statusText).lineLimit(1).foregroundStyle(row.state == .running ? .primary : .secondary)
            }
            .width(min: 80, ideal: 115)
            .customizationID("status")
            TableColumn("CPU %", value: \.cpu) { row in
                Text(row.cpu >= 0 ? Percent.format(row.cpu) : emDash).monospacedDigit()
                    .foregroundStyle(row.cpu >= 0 ? .primary : .secondary)
            }
            .width(min: 48, ideal: 56)
            .customizationID("cpu")
            TableColumn("Memory", value: \.memory) { MemoryCell(row: $0) }
                .width(min: 100, ideal: 130)
                .customizationID("memory")
            TableColumn("Ports", value: \.portsSort) { PortChips(ports: $0.ports, limit: $0.isProject ? 2 : 3) }
                .width(min: 70, ideal: 100)
                .customizationID("ports")
            TableColumn("IP", value: \.ip) { row in
                Text(row.ip.isEmpty ? emDash : row.ip).font(.monoCaption).foregroundStyle(
                    row.ip.isEmpty ? .secondary : .primary)
            }
            .width(min: 85, ideal: 100)
            .customizationID("ip")
            TableColumn("Started", value: \.started) { row in
                Text(row.hasStarted ? RelativeDate.uptime(since: row.started) + " ago" : emDash)
                    .foregroundStyle(.secondary)
                    .help(row.hasStarted ? RelativeDate.absolute(row.started) : "")
            }
            .width(min: 70, ideal: 95)
            .customizationID("started")
            TableColumn("Actions") { ContainerActionsCell(row: $0, actions: actions) }
                .width(56)
                .customizationID("actions")
        } rows: {
            ForEach(rows) { row in
                if let children = row.children {
                    DisclosureTableRow(row, isExpanded: expandedBinding(row.name)) {
                        ForEach(children) { TableRow($0) }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
        .contextMenu(forSelectionType: ContainerRow.ID.self) { ids in
            if !ids.isEmpty { ContainerMenuItems(ids: Array(ids), actions: actions) }
        } primaryAction: { ids in
            ui.selection = ids
            ui.showDetail = true
        }
        // ⌘⌫ deletes the selection only while the table has focus (never while typing in a search field).
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers == .command, !ui.selection.isEmpty else { return .ignored }
            actions.requestDelete(Array(ui.selection))
            return .handled
        }
        .alternatingRowBackgrounds(.disabled)  // no striped "rows" below the content
        .onAppear(perform: loadColumns)
        .onChange(of: columns) { saveColumns() }
        .accessibilityLabel("Containers")
    }

    private func expandedBinding(_ project: String) -> Binding<Bool> {
        Binding(
            get: { !ui.collapsedProjects.contains(project) },
            set: { expanded in
                if expanded { ui.collapsedProjects.remove(project) } else { ui.collapsedProjects.insert(project) }
            })
    }

    private func loadColumns() {
        guard !didLoadColumns else { return }
        didLoadColumns = true
        if !columnsData.isEmpty,
            let decoded = try? JSONDecoder().decode(TableColumnCustomization<ContainerRow>.self, from: columnsData)
        {
            columns = decoded
        }
    }

    private func saveColumns() {
        guard didLoadColumns, let data = try? JSONEncoder().encode(columns) else { return }
        columnsData = data
    }
}
