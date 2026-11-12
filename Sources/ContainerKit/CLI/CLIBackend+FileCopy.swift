import Foundation

// MARK: - ContainerFileOperations: copying in and out

// What `container cp` really does on CLI 1.5.0 (observed on a live engine, 2026-11-12), and what this file does
// about it so that both calls copy to or from *exactly* the path they are given:
//
// 1. It only sees the container's root filesystem. Copying out of a volume, a bind mount or a tmpfs fails with
//    "path not found"; copying in "succeeds" but the file lands in the hidden folder underneath the mount, where
//    nothing inside the container can see it. Such paths go through a temporary item in `/` and `cp -a` / `mv`
//    inside the container.
// 2. An existing directory as destination receives the source *inside* it (`cp a ID:/x` → `/x/a`). Uploads to
//    a path that already exists go to a temporary name and are swapped in.
// 3. The container path is sent in decomposed Unicode form. A name stored precomposed (how Linux tools write
//    "é") is "not found" when copied out, and an upload creates a second, decomposed "é". Such paths are
//    reached through an ASCII alias (a symbolic link for downloads, a temporary name plus `mv` for uploads).
// 4. Uploading a folder replaces every non-ASCII character in the names inside it with `*`. Such folders are
//    uploaded with ASCII placeholder names, which are renamed inside the container afterwards.
// 5. A missing parent directory of the destination is created.
//
// The workarounds need `test`, `ln`, `cp`, `mv`, `rm` (and `sh` for 3 and 4) inside the container. A plain
// ASCII path on the root filesystem that does not exist yet takes the direct route, which needs none of them.
extension CLIBackend {
    /// Copies a file or folder out of the container to exactly `localPath`.
    ///
    /// The CLI appends the source name when the destination is an existing directory and cannot address a
    /// local path containing `:`, so the copy goes to a fresh staging directory first and is then moved into
    /// place (replacing an existing item only after the copy succeeded).
    public func copyOut(_ id: String, path: String, to localPath: String) async throws {
        try Self.validateOperand(id, "Container")
        let path = try Self.copyPath(id, path)
        let stage = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let staged = stage.appending(path: "payload")
        let stagedPath = staged.path(percentEncoded: false)
        let arguments = ["copy", "--", "\(id):\(path)", stagedPath]

        if Self.isCopyAddressable(path) {
            do {
                try await execute(arguments, timeout: nil)
            } catch {
                // A failed copy of something that is there: it is on a mount `container cp` cannot see. The
                // CLI usually says "path not found", but for some mounts (seen with /dev/shm on 1.5.0) it
                // says "no metadata received", so the wording is not relied on.
                guard Self.mayRetryCopy(error), try await containerPathExists(id, path) else { throw error }
                try await copyOutThroughRootFilesystem(id, path, to: stagedPath, tryLink: false)
            }
        } else {
            try await copyOutThroughRootFilesystem(id, path, to: stagedPath, tryLink: true)
        }

        let files = FileManager.default
        guard files.fileExists(atPath: stagedPath) else {
            throw BackendError.commandFailed(
                command: display(arguments), exitCode: 0, message: "The copy finished but produced no file.")
        }
        let destination = URL(filePath: localPath)
        do {
            if files.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try files.replaceItemAt(destination, withItemAt: staged)
            } else {
                try files.moveItem(at: staged, to: destination)
            }
        } catch {
            throw BackendError.commandFailed(
                command: display(arguments), exitCode: 0,
                message: "Copied, but could not move the result to \(localPath): \(error.localizedDescription)")
        }
    }

    /// Copies a file or folder from the Mac to exactly `path` inside the container: an existing file or folder
    /// there is replaced (system directories are refused), names keep their characters, and a destination on
    /// a volume or bind mount really ends up there.
    public func copyIn(_ id: String, localPath: String, to path: String) async throws {
        try Self.validateOperand(id, "Container")
        let path = try Self.copyPath(id, path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory) else {
            throw BackendError.other("“\(localPath)” does not exist.")
        }
        var source = URL(filePath: localPath).standardizedFileURL.path(percentEncoded: false)
        while source.count > 1, source.hasSuffix("/") { source.removeLast() }

        let hasAwkwardNames = isDirectory.boolValue && Self.containsNonASCIIName(below: source)
        var stage: URL?
        defer { if let stage { try? FileManager.default.removeItem(at: stage) } }
        var renames: [(staged: String, name: String)] = []
        if source.contains(":") || hasAwkwardNames {
            let directory = try Self.makeStagingDirectory()
            stage = directory
            let staged = directory.appending(path: "payload").path(percentEncoded: false)
            do {
                try FileManager.default.copyItem(atPath: source, toPath: staged)
                if hasAwkwardNames { renames = try Self.replaceNonASCIINames(below: staged) }
            } catch {
                throw BackendError.other("Could not prepare “\(localPath)” for copying: \(error.localizedDescription)")
            }
            source = staged
        }

        let exists = try await containerPathExists(id, path)
        let mounts = (try? await inspectContainer(id))?.configuration.mounts.map(\.destination) ?? []
        let onMount = Self.isOutsideRootFilesystem(path, mounts: mounts)
        guard exists || onMount || !renames.isEmpty || !Self.isCopyAddressable(path) else {
            let arguments = ["copy", "--", source, "\(id):\(path)"]
            try await execute(arguments, timeout: nil)
            try await verifyArrival(id, path, arguments)
            return
        }
        if exists, let refusal = ContainerPath.deletionRefusal(path, mountPoints: mounts) {
            throw BackendError.other("“\(path)” already exists and cannot be replaced. \(refusal)")
        }

        // Upload under a temporary ASCII name on the root filesystem (next to the destination when `cp` can
        // reach that folder, so the swap is a rename), fix the names inside, then move it into place.
        let parent = ContainerPath.parent(of: path)
        let nonce = FileListing.makeNonce()
        let besideDestination = !onMount && Self.isCopyAddressable(parent)
        let temporary = ContainerPath.join(besideDestination ? parent : "/", ".cd-upload-\(nonce)")
        try await execute(["copy", "--", source, "\(id):\(temporary)"], timeout: nil)
        do {
            try await renameInside(id, renames, below: temporary)
            if exists {
                let replaced = path + ".cd-replaced-\(nonce)"
                try await move(id, path, replaced)
                do { try await move(id, temporary, path) } catch {
                    try? await move(id, replaced, path)
                    throw error
                }
                await removeQuietly(id, replaced)
            } else {
                try await move(id, temporary, path)
            }
        } catch {
            await removeQuietly(id, temporary)
            throw error
        }
    }

    // MARK: - Helpers

    /// `true` when `container cp` reaches exactly this container path: the CLI sends paths in decomposed
    /// Unicode form, so only a path that is already in that form survives unchanged.
    static func isCopyAddressable(_ path: String) -> Bool {
        path.decomposedStringWithCanonicalMapping.utf8.elementsEqual(path.utf8)
    }

    /// Whether `path` is on (or is) one of the container's mounts or a kernel filesystem, which
    /// `container cp` cannot reach.
    static func isOutsideRootFilesystem(_ path: String, mounts: [String]) -> Bool {
        (["/dev", "/proc", "/sys"] + mounts.map { ContainerPath.normalize($0) }).contains {
            $0 != "/" && ContainerPath.isSameOrInside(path, $0)
        }
    }

    /// Whether a failed `container cp` out is worth retrying through the root filesystem: any failure the CLI
    /// itself reported (not a cancellation, timeout or launch problem).
    static func mayRetryCopy(_ error: any Error) -> Bool {
        if case BackendError.commandFailed = error { return true }
        return false
    }

    /// The normalized absolute container path for `container cp`, which splits its operands on `:` and so
    /// cannot address a container path (or id) that contains one.
    static func copyPath(_ id: String, _ path: String) throws -> String {
        let path = try validatedContainerPath(path)
        guard !path.contains(":"), !id.contains(":") else {
            throw BackendError.unsupported(
                feature: "Copying “\(path)”",
                reason: "`container cp` cannot address paths that contain a colon. Rename it first.")
        }
        return path
    }

    /// A new empty directory under the user's temporary directory.
    static func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ContainerDesktop-cp-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw BackendError.other("Could not create a temporary folder: \(error.localizedDescription)")
        }
        return url
    }

    /// `test -e PATH -o -L PATH` inside the container. `false` when it cannot be determined (no `test` in the
    /// image, container not running): the copy itself then reports what is wrong.
    func containerPathExists(_ id: String, _ path: String) async throws -> Bool {
        try await execRaw(id, ["test", "-e", path, "-o", "-L", path], timeout: Self.queryTimeout).exitCode == 0
    }

    /// After a direct upload: fails when the container can tell that nothing arrived at `path`, which is what
    /// happens for a destination on a filesystem the container mounted itself (the copy goes underneath it).
    private func verifyArrival(_ id: String, _ path: String, _ arguments: [String]) async throws {
        let command = ["test", "-e", path, "-o", "-L", path]
        guard let result = try? await execRaw(id, command, timeout: Self.queryTimeout), result.exitCode != 0,
            result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }  // it is there, or the image has no `test` to ask
        throw BackendError.commandFailed(
            command: display(arguments), exitCode: 0,
            message: "The copy reported success, but “\(path)” is not there. `container cp` cannot write to "
                + "filesystems mounted inside the container.")
    }

    /// Copies out something `container cp` cannot address directly, through a temporary ASCII name in `/`:
    /// a symbolic link when only the name is the problem (`tryLink`), otherwise a real copy made inside the
    /// container (`cp -a`), which is what reaches volumes, bind mounts and tmpfs.
    private func copyOutThroughRootFilesystem(
        _ id: String, _ path: String, to stagedPath: String, tryLink: Bool
    ) async throws {
        let temporary = "/.cd-copy-\(FileListing.makeNonce())"
        let pull = ["copy", "--", "\(id):\(temporary)", stagedPath]
        if tryLink {
            guard try await containerPathExists(id, path) else {
                throw BackendError.commandFailed(
                    command: display(["copy", "--", "\(id):\(path)", stagedPath]), exitCode: 1,
                    message: "copy: path not found '\(path)'")
            }
            let link = try await execRaw(id, ["ln", "-s", "--", path, temporary], timeout: Self.actionTimeout)
            if link.exitCode == 0 {
                do {
                    try await execute(pull, timeout: nil)
                    await removeQuietly(id, temporary)
                    return
                } catch {
                    await removeQuietly(id, temporary)
                    guard Self.mayRetryCopy(error), try await containerPathExists(id, path) else { throw error }
                }
            }
        }
        let duplicate = ["cp", "-a", "--", path, temporary]
        do {
            try checkExec(id, duplicate, try await execRaw(id, duplicate, timeout: nil))
            try await execute(pull, timeout: nil)
        } catch {
            await removeQuietly(id, temporary)
            throw error
        }
        await removeQuietly(id, temporary)
    }

    /// `mv -- SOURCE DESTINATION` inside the container.
    private func move(_ id: String, _ source: String, _ destination: String) async throws {
        let command = ["mv", "--", source, destination]
        try checkExec(id, command, try await execRaw(id, command, timeout: nil))
    }

    /// `rm -rf -- PATH` inside the container for something this file created; failures are ignored.
    private func removeQuietly(_ id: String, _ path: String) async {
        _ = try? await execRaw(id, ["rm", "-rf", "--", path], timeout: Self.pruneTimeout)
    }

    /// Gives the uploaded placeholders below `root` their real names again, deepest first, a batch per exec.
    private func renameInside(
        _ id: String, _ renames: [(staged: String, name: String)], below root: String
    ) async throws {
        let script = #"while [ $# -gt 1 ]; do mv -- "$1" "$2" || exit 1; shift 2; done"#
        var remaining = renames.reversed()[...]
        while !remaining.isEmpty {
            let batch = remaining.prefix(100)
            remaining = remaining.dropFirst(batch.count)
            let pairs = batch.flatMap { rename -> [String] in
                let from = ContainerPath.join(root, rename.staged)
                return [from, ContainerPath.join(ContainerPath.parent(of: from), rename.name)]
            }
            let result = try await execRaw(id, ["sh", "-c", script, "sh"] + pairs, timeout: Self.pruneTimeout)
            guard result.exitCode == 0 else {
                throw BackendError.commandFailed(
                    command: display(Self.execArguments(id, ["sh", "-c", script, "sh", "…"])),
                    exitCode: result.exitCode,
                    message: "The folder contains names with non-ASCII characters, which `container cp` cannot "
                        + "upload; restoring them inside the container failed: "
                        + CLIErrorMapper.cleanMessage(result.stderrText))
            }
        }
    }

    /// Whether any file or folder below `directory` has a name with a non-ASCII character.
    static func containsNonASCIIName(below directory: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return false }
        while let relative = enumerator.nextObject() as? String {
            if !relative.unicodeScalars.allSatisfy(\.isASCII) { return true }
        }
        return false
    }

    /// Renames every entry below `root` whose name has a non-ASCII character to an ASCII placeholder.
    /// - Returns: placeholder path relative to `root` and the real name (precomposed, as Linux tools write
    ///   it), parents before their contents.
    static func replaceNonASCIINames(below root: String) throws -> [(staged: String, name: String)] {
        let files = FileManager.default
        var renames: [(staged: String, name: String)] = []
        var pending = [""]  // directories still to visit, relative to `root` and already renamed
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
            for name in try files.contentsOfDirectory(atPath: directory) {
                var staged = name
                if !name.unicodeScalars.allSatisfy(\.isASCII) {
                    staged = ".cd-name-\(renames.count)-\(FileListing.makeNonce())"
                    try files.moveItem(
                        atPath: (directory as NSString).appendingPathComponent(name),
                        toPath: (directory as NSString).appendingPathComponent(staged))
                    let stagedPath = relative.isEmpty ? staged : relative + "/" + staged
                    renames.append((stagedPath, name.precomposedStringWithCanonicalMapping))
                }
                let child = (directory as NSString).appendingPathComponent(staged)
                // `attributesOfItem` does not follow links, so a link to a folder is not descended into.
                if try files.attributesOfItem(atPath: child)[.type] as? FileAttributeType == .typeDirectory {
                    pending.append(relative.isEmpty ? staged : relative + "/" + staged)
                }
            }
        }
        return renames
    }
}
