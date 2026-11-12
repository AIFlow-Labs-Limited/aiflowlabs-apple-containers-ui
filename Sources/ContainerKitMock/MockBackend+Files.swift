import ContainerKit
import Foundation

// MARK: - ContainerFileOperations

extension MockBackend {
    /// Replaces the fake filesystem of a container (tests and previews, e.g. a shell-less image).
    public func setFileSystem(_ fileSystem: MockFileSystem, for id: String) { fileSystems[id] = fileSystem }

    /// The fake filesystem of a container, built from its image on first use.
    public func fileSystem(for id: String) throws -> MockFileSystem {
        if let existing = fileSystems[id] { return existing }
        guard let container = containers.first(where: { $0.id == id }) else {
            throw BackendError.notFound(kind: "container", id: id)
        }
        let made = MockFileSystem.sample(for: container)
        fileSystems[id] = made
        return made
    }

    /// The same failure the CLI reports, with the command it would have run.
    private func failed(_ id: String, _ command: [String], code: Int32 = 1, _ message: String) -> BackendError {
        .commandFailed(
            command: ShellQuote.join(["container", "exec", "--", id] + command), exitCode: code, message: message)
    }

    /// Latency, engine state, container existence and running state, then the filesystem.
    private func runningFileSystem(_ id: String, _ command: [String]) async throws -> MockFileSystem {
        if !systemRunning { throw BackendError.systemNotRunning }
        try? await Task.sleep(for: latency)
        let fs = try fileSystem(for: id)
        guard containers.first(where: { $0.id == id })?.isRunning == true else {
            throw failed(id, command, "container \(id) is not running")
        }
        return fs
    }

    /// Like `runningFileSystem`, for commands that need a program inside the image.
    private func shellFileSystem(_ id: String, _ command: [String]) async throws -> MockFileSystem {
        let fs = try await runningFileSystem(id, command)
        guard fs.hasShell else {
            throw failed(id, command, code: 127, "failed to find target executable \(command[0])")
        }
        return fs
    }

    public func listDirectory(_ id: String, path: String, limit: Int) async throws -> ContainerDirectoryListing {
        let path = ContainerPath.normalize(path)
        let command = ["sh", "-c", "…", "sh", path]
        let fs = try await runningFileSystem(id, command)
        guard fs.hasShell else { return ContainerDirectoryListing(path: path, method: nil, unavailable: .noShell) }
        guard fs.exists(fs.resolve(path)) else {
            throw failed(id, command, code: FileListing.missingExitCode, "“\(path)” does not exist.")
        }
        guard fs.isDirectory(path) else {
            throw failed(id, command, code: FileListing.notADirectoryExitCode, "“\(path)” is not a directory.")
        }
        let children = fs.children(of: path)
        return ContainerDirectoryListing(
            path: path, entries: Array(children.prefix(max(1, limit))), isTruncated: children.count > max(1, limit))
    }

    public func readFile(_ id: String, path: String, maxBytes: Int) async throws -> Data {
        let path = ContainerPath.normalize(path)
        let command = ["head", "-c", String(maxBytes), "--", path]
        let fs = try await shellFileSystem(id, command)
        guard let node = fs.nodes[fs.resolve(path)] else {
            throw failed(id, command, "head: \(path): No such file or directory")
        }
        guard node.entry.kind == .file else { throw failed(id, command, "head: \(path): Is a directory") }
        // Files that only pretend to have a size read as zero bytes (binary).
        let data = node.content ?? Data(count: Int(min(node.entry.size, 4096)))
        return data.prefix(max(0, maxBytes))
    }

    public func makeDirectory(_ id: String, path: String) async throws {
        let path = ContainerPath.normalize(path)
        let command = ["mkdir", "--", path]
        var fs = try await shellFileSystem(id, command)
        guard !fs.exists(path) else {
            throw failed(id, command, "mkdir: can't create directory '\(path)': File exists")
        }
        guard fs.isDirectory(ContainerPath.parent(of: path)) else {
            throw failed(id, command, "mkdir: can't create directory '\(path)': No such file or directory")
        }
        fs.directory(path, daysOld: 0)
        fileSystems[id] = fs
    }

    public func moveItem(_ id: String, from source: String, to destination: String) async throws {
        let source = ContainerPath.normalize(source)
        let destination = ContainerPath.normalize(destination)
        let command = ["mv", "--", source, destination]
        var fs = try await shellFileSystem(id, command)
        guard source != "/", fs.exists(source) else {
            throw failed(id, command, "mv: can't rename '\(source)': No such file or directory")
        }
        guard !fs.exists(destination) else {
            throw failed(id, command, "mv: can't rename '\(source)': File exists")
        }
        fs.move(source, to: destination)
        fileSystems[id] = fs
    }

    public func deleteItem(_ id: String, path: String) async throws {
        let path = ContainerPath.normalize(path)
        if let refusal = ContainerPath.deletionRefusal(path) { throw BackendError.other(refusal) }
        var fs = try await shellFileSystem(id, ["rm", "-rf", "--", path])
        fs.remove(path)
        fileSystems[id] = fs
    }

    /// Writes the fake file (or folder tree) to `localPath`, so Save to Mac and Quick Look work in the mock.
    public func copyOut(_ id: String, path: String, to localPath: String) async throws {
        let path = ContainerPath.normalize(path)
        let command = ["container", "copy", "--", "\(id):\(path)", localPath]
        if !systemRunning { throw BackendError.systemNotRunning }
        try? await Task.sleep(for: latency)
        let fs = try fileSystem(for: id)
        func fail(_ message: String) -> BackendError {
            .commandFailed(command: ShellQuote.join(command), exitCode: 1, message: message)
        }
        guard containers.first(where: { $0.id == id })?.isRunning == true else {
            throw fail("container \(id) is not running")
        }
        let resolved = fs.resolve(path)
        guard resolved == "/" || fs.nodes[resolved] != nil else { throw fail("source path does not exist: \(path)") }
        let files = FileManager.default
        do {
            if files.fileExists(atPath: localPath) { try files.removeItem(atPath: localPath) }
            guard fs.isDirectory(path) else {
                let node = fs.nodes[resolved]
                let data = node?.content ?? Data(count: Int(min(node?.entry.size ?? 0, 1 << 20)))
                try data.write(to: URL(filePath: localPath))
                return
            }
            try files.createDirectory(atPath: localPath, withIntermediateDirectories: true)
            for key in fs.subtree(resolved).sorted() where key != resolved {
                guard let node = fs.nodes[key] else { continue }
                let target = localPath + key.dropFirst(resolved == "/" ? 0 : resolved.count)
                switch node.entry.kind {
                case .directory: try files.createDirectory(atPath: target, withIntermediateDirectories: true)
                case .file:
                    let data = node.content ?? Data(count: Int(min(node.entry.size, 1 << 20)))
                    try data.write(to: URL(filePath: target))
                default: continue
                }
            }
        } catch {
            throw fail(error.localizedDescription)
        }
    }

    /// Adds the local file (or the top level of a local folder) to the fake filesystem.
    public func copyIn(_ id: String, localPath: String, to path: String) async throws {
        let path = ContainerPath.normalize(path)
        let command = ["container", "copy", "--", localPath, "\(id):\(path)"]
        if !systemRunning { throw BackendError.systemNotRunning }
        try? await Task.sleep(for: latency)
        var fs = try fileSystem(for: id)
        func fail(_ message: String) -> BackendError {
            .commandFailed(command: ShellQuote.join(command), exitCode: 1, message: message)
        }
        guard containers.first(where: { $0.id == id })?.isRunning == true else {
            throw fail("container \(id) is not running")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory) else {
            throw fail("source path does not exist: \(localPath)")
        }
        func add(_ local: String, at destination: String) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: local)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let content = size <= 1 << 20 ? FileManager.default.contents(atPath: local) : nil
            fs.file(destination, data: content, size: size, daysOld: 0)
        }
        if isDirectory.boolValue {
            fs.directory(path, daysOld: 0)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: localPath)) ?? []
            for name in names.prefix(200) {
                var childIsDirectory: ObjCBool = false
                let local = localPath + "/" + name
                _ = FileManager.default.fileExists(atPath: local, isDirectory: &childIsDirectory)
                if childIsDirectory.boolValue {
                    fs.directory(ContainerPath.join(path, name), daysOld: 0)
                } else {
                    add(local, at: ContainerPath.join(path, name))
                }
            }
        } else {
            add(localPath, at: path)
        }
        fileSystems[id] = fs
    }

    /// A container value matching one of the mock's samples by id (falls back to a minimal one), for
    /// `#Preview`s that need a `Container` without awaiting the actor.
    public static func previewContainer(id: String, image: String, running: Bool = true) -> Container {
        if let sample = extraContainers().first(where: { $0.id == id }) { return sample }
        let descriptor = Descriptor(
            digest: "sha256:" + fakeDigest(image), mediaType: "application/vnd.oci.image.index.v1+json", size: 1000)
        return Container(
            id: id,
            configuration: .init(
                id: id, image: ImageReference(reference: image, descriptor: descriptor), creationDate: .now,
                initProcess: .init(executable: "sh")),
            status: .init(state: running ? .running : .stopped))
    }

    public func supportsCommit() async -> Bool { commitSupported }

    /// Streams plausible `container commit` output, then adds the image to the list.
    public nonisolated func commitContainer(_ id: String, reference: String) -> LineStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.beginCommit(id)
                    for line in ["Exporting the filesystem of \(id)", "Creating image archive", "Loading \(reference)"]
                    {
                        try Task.checkCancellation()
                        continuation.yield(OutputLine(line))
                        try await Task.sleep(for: .milliseconds(120))
                    }
                    await self.finishCommit(id, reference: reference)
                    continuation.yield(OutputLine(reference))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? BackendError.cancelled : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func beginCommit(_ id: String) throws {
        if !systemRunning { throw BackendError.systemNotRunning }
        guard commitSupported else {
            throw BackendError.unsupported(
                feature: "Save as Image", reason: "container commit requires Apple container 1.6 or later.")
        }
        guard containers.contains(where: { $0.id == id }) else {
            throw BackendError.notFound(kind: "container", id: id)
        }
    }

    private func finishCommit(_ id: String, reference: String) {
        guard !images.contains(where: { $0.reference == reference }) else { return }
        let descriptor = Descriptor(
            digest: "sha256:" + MockBackend.fakeDigest(reference + id),
            mediaType: "application/vnd.oci.image.index.v1+json", size: 500)
        images.append(
            Image(
                id: MockBackend.fakeDigest(reference + id),
                configuration: .init(name: reference, creationDate: .now, descriptor: descriptor),
                variants: [.init(platform: .arm64, digest: descriptor.digest, size: 61_000_000)]))
    }
}
