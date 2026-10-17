import Foundation

// MARK: - ImageOperations

extension CLIBackend {
    /// `container image ls --format json`.
    public func listImages() async throws -> [Image] {
        try await decode([Image].self, ["image", "ls", "--format", "json"])
    }

    /// `container image inspect REF` (one-element array).
    public func inspectImage(_ reference: String) async throws -> Image {
        try await inspectFirst(Image.self, kind: "image", id: reference, ["image", "inspect", reference])
    }

    /// `container image pull --progress plain [--platform P] REF`.
    public nonisolated func pullImage(_ reference: String, platform: Platform?) -> LineStream {
        streamCommand(Self.transferArguments("pull", reference, platform: platform))
    }

    /// `container image push --progress plain [--platform P] REF`.
    public nonisolated func pushImage(_ reference: String, platform: Platform?) -> LineStream {
        streamCommand(Self.transferArguments("push", reference, platform: platform))
    }

    /// argv for `image pull` / `image push`.
    static func transferArguments(_ verb: String, _ reference: String, platform: Platform?) -> [String] {
        ["image", verb, "--progress", "plain"] + (platform.map { ["--platform", $0.slug] } ?? []) + [reference]
    }

    /// `container image rm REF`.
    public func deleteImage(_ reference: String) async throws {
        try await execute(["image", "rm", reference], timeout: Self.actionTimeout)
    }

    /// `container image tag SRC NEW`.
    public func tagImage(_ reference: String, newReference: String) async throws {
        try await execute(["image", "tag", reference, newReference])
    }

    /// `container image prune [--all]`.
    public func pruneImages(all: Bool) async throws {
        try await execute(["image", "prune"] + (all ? ["--all"] : []), timeout: Self.actionTimeout)
    }

    /// `container image save --output TAR [--platform P] REFS…`.
    public func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws {
        let arguments = ["image", "save", "--output", tarPath] + (platform.map { ["--platform", $0.slug] } ?? []) + references
        try await execute(arguments, timeout: nil)
    }

    /// `container image load --input TAR`.
    public func loadImages(from tarPath: String) async throws {
        try await execute(["image", "load", "--input", tarPath], timeout: nil)
    }

    /// `container build -t TAG --progress plain …`. The image name is the final stdout line.
    public nonisolated func buildImage(_ spec: BuildSpec) -> LineStream {
        streamCommand(["build"] + spec.cliArguments)
    }

    /// `container builder status --format json`; `nil` when the builder has not been started.
    public func builderStatus() async throws -> Container? {
        let arguments = ["builder", "status", "--format", "json"]
        let result = try await execute(arguments)
        guard !result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try CLIJSON.decode([Container].self, from: result.stdout).first
        } catch {
            throw BackendError.decoding(command: display(arguments), underlying: String(describing: error))
        }
    }

    /// `container builder start [-c N] [-m SIZE]`.
    public func builderStart(cpus: Int?, memory: MemorySize?) async throws {
        var arguments = ["builder", "start"]
        if let cpus { arguments += ["-c", String(cpus)] }
        if let memory { arguments += ["-m", memory.cliArgument] }
        try await execute(arguments, timeout: .seconds(600))
    }

    /// `container builder stop`.
    public func builderStop() async throws {
        try await execute(["builder", "stop"], timeout: Self.actionTimeout)
    }

    /// `container builder delete`.
    public func builderDelete() async throws {
        try await execute(["builder", "delete"], timeout: Self.actionTimeout)
    }
}
