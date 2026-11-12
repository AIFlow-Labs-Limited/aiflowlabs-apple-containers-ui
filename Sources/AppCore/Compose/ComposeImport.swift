import ContainerKit
import Foundation
import Observation

/// State of one "Import Compose File" session: the file, the variables, the options, the resulting plan and,
/// once started, the run. The sheet only renders this.
@MainActor
@Observable
public final class ComposeImport {
    /// The file being imported; `nil` until one is chosen.
    public private(set) var source: ComposeSource?
    /// Why the chosen file could not be opened or parsed.
    public private(set) var error: String?
    /// Variables the file refers to, for the "Variables" table.
    public private(set) var references: [ComposeInterpolation.Reference] = []
    /// The parsed file with its folder; `nil` while there is an `error`.
    public private(set) var project: ComposeProject?
    /// What exists in the engine (collision checks, local images, DNS domain).
    public private(set) var environment = ComposeEnvironment()
    /// The current plan; recomputed whenever the file, a variable, an option or the environment changes.
    public private(set) var plan: ComposePlan?
    /// The run, once Run has been pressed.
    public private(set) var run: ComposeRun?

    /// Preview choices. Changing them re-plans.
    public var options = ComposeOptions() {
        didSet { if options != oldValue { replan() } }
    }
    /// Values typed in the preview; they win over the `.env` file.
    public private(set) var overrides: [String: String] = [:]

    public init() {}

    /// `.env` values with the preview's overrides on top.
    public var variables: [String: String] {
        (source?.dotEnv ?? [:]).merging(overrides) { _, override in override }
    }

    /// The project name the plan uses when `options.projectName` is empty.
    public var defaultProjectName: String { project.map(ComposePlanner.defaultProjectName) ?? "" }

    /// Opens `url`: reads it and its `.env`, parses, and plans. Any earlier session state is dropped.
    public func open(_ url: URL) {
        run = nil
        overrides = [:]
        options = ComposeOptions()
        do {
            source = try ComposeLoader.load(url)
        } catch {
            source = nil
            project = nil
            plan = nil
            references = []
            self.error = BackendError(wrapping: error).errorDescription
            return
        }
        reparse()
    }

    /// Forgets the file (back to "choose a file").
    public func close() {
        source = nil
        project = nil
        plan = nil
        run = nil
        error = nil
        references = []
    }

    /// Sets (or with `nil` clears) the preview's value for `name`, then re-parses.
    public func setVariable(_ name: String, to value: String?) {
        guard overrides[name] != value else { return }
        overrides[name] = value
        reparse()
    }

    /// Re-reads what exists in the engine and re-plans. Safe to call while the engine is stopped.
    public func refreshEnvironment(backend: any ContainerBackend) async {
        environment = await ComposeEnvironment.load(from: backend)
        replan()
    }

    /// Starts the current plan. Returns `nil` when there is nothing runnable.
    @discardableResult
    public func start(
        backend: any ContainerBackend, taskCenter: TaskCenter, onFinish: (@MainActor (Bool) async -> Void)? = nil
    ) -> ComposeRun? {
        guard run == nil, let plan, plan.canRun else { return nil }
        let run = ComposeRun(plan: plan)
        self.run = run
        run.start(backend: backend, taskCenter: taskCenter, onFinish: onFinish)
        return run
    }

    /// Drops a finished run so the preview (with a fresh look at the engine) is shown again.
    public func backToPreview(backend: any ContainerBackend) async {
        guard run?.isRunning != true else { return }
        run = nil
        options.replaceExisting = []
        await refreshEnvironment(backend: backend)
    }

    private func reparse() {
        guard let source else { return }
        references = (try? ComposeParser.variableReferences(in: source.text)) ?? []
        do {
            let file = try ComposeParser.parse(source.text, variables: variables)
            project = ComposeProject(file: file, directory: source.directory)
            error = nil
        } catch {
            project = nil
            self.error = (error as? ComposeError)?.errorDescription ?? error.localizedDescription
        }
        replan()
    }

    private func replan() {
        guard let project, let source else {
            plan = nil
            return
        }
        var plan = ComposePlanner.plan(project, options: options, environment: environment)
        if !source.overrideFiles.isEmpty {
            plan.warnings.insert(
                ComposeWarning(
                    scope: .file, key: "override files",
                    message: "\(source.overrideFiles.joined(separator: ", ")) in the same folder is not merged. "
                        + "Only \(source.fileName) is read."), at: 0)
        }
        self.plan = plan
    }
}
