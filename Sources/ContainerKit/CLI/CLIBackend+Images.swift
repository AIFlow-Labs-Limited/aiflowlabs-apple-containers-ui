import Foundation

// MARK: - ImageOperations

extension CLIBackend {
    /// `container image ls --format json`.
    public func listImages() async throws -> [Image] {
        try await decodeList(Image.self, ["image", "ls", "--format", "json"])
    }

    /// `container image inspect -- REF` (one-element array).
    public func inspectImage(_ reference: String) async throws -> Image {
        try Self.validateOperand(reference, "Image reference")
        return try await inspectFirst(Image.self, kind: "image", id: reference, ["image", "inspect", "--", reference])
    }

    /// `container image pull [--scheme S] --progress plain [--platform P] -- REF`.
    public nonisolated func pullImage(_ reference: String, platform: Platform?, scheme: String?) -> LineStream {
        transfer("pull", reference, platform: platform, scheme: scheme, action: .pull)
    }

    /// `container image push [--scheme S] --progress plain [--platform P] -- REF`.
    ///
    /// Without a platform the CLI pushes every platform in the image's index, which fails for an image that was
    /// pulled for this Mac only (the same `content with digest sha256:…` as `image save`).
    public nonisolated func pushImage(_ reference: String, platform: Platform?, scheme: String?) -> LineStream {
        transfer("push", reference, platform: platform, scheme: scheme, action: .push)
    }

    /// Streams a pull or push; a registry failure (wrong scheme, nothing listening, refused login) ends the
    /// stream with an explained error (`RegistryFailure`).
    private nonisolated func transfer(
        _ verb: String, _ reference: String, platform: Platform?, scheme: String?, action: RegistryFailure.Action
    ) -> LineStream {
        validatedStream {
            try Self.validateOperand(reference, "Image reference")
            if let scheme { try Self.validateScheme(scheme) }
            let stream = streamCommand(Self.transferArguments(verb, reference, platform: platform, scheme: scheme))
            let host = RegistryFailure.host(ofReference: reference)
            return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(ProcessRunner.streamBufferLimit)) {
                continuation in
                let task = Task {
                    do {
                        for try await line in stream { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(
                            throwing: RegistryFailure.explain(error, host: host, action: action, platform: platform))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// argv for `image pull` / `image push`.
    static func transferArguments(
        _ verb: String, _ reference: String, platform: Platform?, scheme: String? = nil
    ) -> [String] {
        ["image", verb] + (scheme.map { ["--scheme", $0] } ?? []) + ["--progress", "plain"]
            + (platform.map { ["--platform", $0.slug] } ?? []) + ["--", reference]
    }

    /// The CLI's `--scheme` takes `http` or `https` (1.7.1 help); anything else is refused before it runs.
    static func validateScheme(_ scheme: String) throws {
        guard ["http", "https"].contains(scheme) else {
            throw BackendError.other("The registry connection must be http or https, not “\(scheme)”.")
        }
    }

    /// `container image rm -- REF`.
    public func deleteImage(_ reference: String) async throws {
        try Self.validateOperand(reference, "Image reference")
        try await execute(["image", "rm", "--", reference], timeout: Self.actionTimeout)
    }

    /// `container image tag -- SRC NEW`.
    public func tagImage(_ reference: String, newReference: String) async throws {
        try Self.validateOperands([reference, newReference], "Image reference")
        try await execute(["image", "tag", "--", reference, newReference])
    }

    /// `container image prune [--all]`.
    public func pruneImages(all: Bool) async throws {
        try await execute(["image", "prune"] + (all ? ["--all"] : []), timeout: Self.pruneTimeout)
    }

    /// `container image save --output TAR [--platform P] -- REFS…`.
    ///
    /// Without a platform the CLI saves every platform in the image's index. For an image that was pulled for
    /// this Mac only, the other platforms' layers are not on disk and the CLI stops with nothing more than
    /// `content with digest sha256:…` (seen on container 1.7.1); that message is completed here.
    public func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws {
        try Self.validateOperands(references, "Image reference")
        let arguments =
            ["image", "save", "--output", tarPath] + (platform.map { ["--platform", $0.slug] } ?? []) + ["--"]
            + references
        do {
            try await execute(arguments, timeout: nil)
        } catch let error as BackendError {
            throw Self.saveFailure(error, platform: platform)
        }
    }

    /// Explains the CLI's bare `content with digest sha256:…` when all platforms were asked for.
    static func saveFailure(_ error: BackendError, platform: Platform?) -> BackendError {
        guard platform == nil, case .commandFailed(let command, let exitCode, let message) = error,
            message.localizedCaseInsensitiveContains("content with digest")
        else { return error }
        return .commandFailed(
            command: command, exitCode: exitCode,
            message: message
                + " is not in the local image store. The image lists platforms that were never downloaded, so "
                + "“All platforms” cannot be saved. Choose a single platform (for example linux/arm64).")
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
