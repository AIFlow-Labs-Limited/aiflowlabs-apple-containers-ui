import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// The preview step: project settings, services, variables, what will differ from Docker, and the commands.
struct ComposePreviewView: View {
    @Bindable var session: ComposeImport

    var body: some View {
        // One form whether or not the file can be planned, so the variable fields keep their focus while a
        // value that fixes (or breaks) the file is being typed.
        Form {
            if let plan = session.plan {
                projectSection(plan)
                servicesSection(plan)
            } else {
                Section {
                    Label(session.error ?? "This file could not be read.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.statusError)
                        .textSelection(.enabled)
                }
            }
            ComposeVariablesSection(session: session)
            if let plan = session.plan {
                ComposeWarningsSection(plan: plan)
                ComposeCommandsSection(plan: plan)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Project

    private func projectSection(_ plan: ComposePlan) -> some View {
        Section {
            TextField(
                "Project name",
                text: Binding(
                    get: { session.options.projectName ?? "" },
                    set: { session.options.projectName = $0.isEmpty ? nil : $0 }),
                prompt: Text(session.defaultProjectName)
            )
            .help("Groups the containers in the Containers list and prefixes the volumes it creates.")
            Picker("Container names", selection: $session.options.naming) {
                Text("Service names (db)").tag(ComposeOptions.Naming.serviceName)
                Text("Project and service (\(plan.projectName)-db)").tag(ComposeOptions.Naming.projectPrefixed)
            }
            .help(
                "A container's name is also its hostname. Service names keep the file's own references working; "
                    + "project-prefixed names never clash with another project.")
            Picker("Networks", selection: $session.options.networking) {
                Text("Built-in default network").tag(ComposeOptions.Networking.sharedDefault)
                Text("Networks from the file").tag(ComposeOptions.Networking.asDeclared)
            }
            if !(session.project?.file.profiles.isEmpty ?? true) {
                LabeledContent("Profiles") {
                    HStack(spacing: Spacing.m) {
                        ForEach(session.project?.file.profiles ?? [], id: \.self) { profile in
                            Toggle(profile, isOn: profileBinding(profile)).toggleStyle(.checkbox)
                        }
                    }
                }
            }
            let resolves = namesResolve(plan)
            Label(plan.namingSummary, systemImage: resolves ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(resolves ? Color.secondary : Color.statusWarning)
                .textSelection(.enabled)
        } header: {
            Text("Project")
        } footer: {
            Text(summaryLine(plan)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Whether the plan can promise that containers find each other by name.
    private func namesResolve(_ plan: ComposePlan) -> Bool {
        plan.services.contains { $0.isEnabled && !$0.hostnames.isEmpty }
    }

    private func profileBinding(_ profile: String) -> Binding<Bool> {
        Binding(
            get: { session.options.enabledProfiles.contains(profile) },
            set: { enabled in
                if enabled {
                    session.options.enabledProfiles.insert(profile)
                } else {
                    session.options.enabledProfiles.remove(profile)
                }
            })
    }

    /// "Creates 2 volumes, pulls 3 images and starts 3 containers. Already there and reused: volume shop_pgdata."
    private func summaryLine(_ plan: ComposePlan) -> String {
        func count(_ noun: String, _ match: (ComposeStep.Action) -> Bool) -> String? {
            let n = plan.steps.count { match($0.action) }
            return n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")"
        }
        let creates = [
            count("network") { if case .createNetwork = $0 { true } else { false } },
            count("volume") { if case .createVolume = $0 { true } else { false } },
        ].compactMap { $0 }
        let pulls = count("image") { if case .pullImage = $0 { true } else { false } }
        let builds = count("image") { if case .buildImage = $0 { true } else { false } }
        let runs = count("container") { if case .runContainer = $0 { true } else { false } }
        var parts: [String] = []
        if !creates.isEmpty { parts.append("creates \(creates.joined(separator: " and "))") }
        if let pulls { parts.append("pulls \(pulls)") }
        if let builds { parts.append("builds \(builds)") }
        if let runs { parts.append("starts \(runs)") }
        var text = parts.isEmpty ? "Nothing to do." : parts.joined(separator: ", ").capitalizedFirst + "."
        if !plan.reused.isEmpty { text += " Already there and reused: \(plan.reused.joined(separator: ", "))." }
        return text
    }

    // MARK: Services

    private func servicesSection(_ plan: ComposePlan) -> some View {
        Section("Services (\(plan.services.count { $0.isEnabled }) of \(plan.services.count))") {
            ForEach(plan.services) { service in
                ComposeServiceRow(service: service)
            }
        }
    }
}

/// One service: what runs, under which name, and how the others reach it.
private struct ComposeServiceRow: View {
    let service: ComposeServiceSummary

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            SwiftUI.Image(systemName: service.isBuilt ? "hammer" : "shippingbox")
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.s) {
                    Text(service.name).fontWeight(.medium)
                    if service.containerName != service.name {
                        Text("container \(service.containerName)").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(service.profiles, id: \.self) { TagBadge("profile \($0)") }
                }
                Text(service.isBuilt ? "built as \(service.image)" : service.image)
                    .font(.monoCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if service.isEnabled {
                    Text(reachability).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not started: its profile is switched off.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !service.ports.isEmpty {
                Text(service.ports.joined(separator: "  ")).font(.monoCaption).foregroundStyle(.secondary)
            }
        }
        .opacity(service.isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }

    private var reachability: String {
        service.hostnames.isEmpty
            ? "Other containers reach it by IP address only."
            : "Other containers reach it at \(service.hostnames.joined(separator: " or "))."
    }
}

/// Bottom bar of the sheet: blocking problems, the "replace existing" choice, and Cancel / Run (or the run's
/// own buttons once it has started).
struct ComposeImportFooter: View {
    @Bindable var session: ComposeImport
    let engineRunning: Bool
    let run: () -> Void
    let close: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if session.run == nil, let plan = session.plan {
                problems(plan)
            }
            HStack {
                if let composeRun = session.run {
                    runButtons(composeRun)
                } else {
                    Spacer()
                    Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                    Button("Run", action: run)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!(session.plan?.canRun ?? false) || !engineRunning)
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.m)
    }

    @ViewBuilder
    private func problems(_ plan: ComposePlan) -> some View {
        let collisions = collisionNames(plan)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if !engineRunning {
                Label("The engine is not running. Start it to run this project.", systemImage: "power")
                    .font(.caption).foregroundStyle(.statusWarning)
            }
            ForEach(plan.problems) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.statusError)
            }
            if !collisions.isEmpty {
                Toggle(
                    "Replace existing container\(collisions.count == 1 ? "" : "s") \(listed(collisions)) "
                        + "(deleted and created again; asks before running)",
                    isOn: Binding(
                        get: { session.options.replaceExisting.isSuperset(of: collisions) },
                        set: { session.options.replaceExisting = $0 ? Set(collisions) : [] })
                )
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
        .textSelection(.enabled)
    }

    /// Existing containers in the way: the ones still blocking plus the ones already marked for replacement.
    private func collisionNames(_ plan: ComposePlan) -> [String] {
        let blocking = plan.problems.compactMap { problem -> String? in
            if case .containerExists(let name) = problem.kind { name } else { nil }
        }
        return (blocking + plan.containersToReplace).sorted()
    }

    @ViewBuilder
    private func runButtons(_ composeRun: ComposeRun) -> some View {
        if composeRun.isRunning {
            Text("Runs in the Activity window too. Closing this sheet does not stop it.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Stop", role: .destructive) { composeRun.task?.cancel() }
                .help("Stops after the current step. What was already created stays.")
            Button("Close", action: close).keyboardShortcut(.cancelAction)
        } else {
            Spacer()
            if !composeRun.succeeded {
                Button("Back to Preview") { Task { await session.backToPreview(backend: model.backend) } }
                    .disabled(composeRun.isCleaningUp)
            }
            Button("Close", action: close).keyboardShortcut(.defaultAction)
        }
    }
}

extension String {
    /// The string with its first character uppercased (the rest untouched, unlike `capitalized`).
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
