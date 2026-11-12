import Foundation
import Testing

@testable import ContainerKit

/// Upload, download, export and commit against the real `container` CLI, in a BusyBox container (`alpine`) and
/// a GNU coreutils one (`python:3.11-slim`). Creates only `cd-it-…` containers, volumes and temporary folders,
/// and removes them again.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite("CLIBackend File Copy Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct CLIBackendFileCopyIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    static let images = CLIBackendFilesIntegrationTests.images

    // MARK: Copying

    /// A local tree with awkward names, used for upload and round-trip checks.
    private func makeLocalTree(in folder: URL) throws -> URL {
        let tree = folder.appending(path: "local tree")
        let nested = tree.appending(path: "nested dir/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("top\n".utf8).write(to: tree.appending(path: "top file.txt"))
        try Data(0...255).write(to: tree.appending(path: "binary.bin"))
        try Data("ü\n".utf8).write(to: nested.appending(path: "ünï-日本.txt"))
        try Data().write(to: tree.appending(path: "nested dir/empty"))
        return tree
    }

    /// Relative path → contents, for every regular file below `root`.
    private func contents(of root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = root.resolvingSymlinksInPath().path(percentEncoded: false)
        let enumerator = try #require(FileManager.default.enumerator(atPath: base))
        while let relative = enumerator.nextObject() as? String {
            var isDirectory: ObjCBool = false
            let full = (base as NSString).appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            result[relative.precomposedStringWithCanonicalMapping] = try Data(contentsOf: URL(filePath: full))
        }
        return result
    }

    @Test(arguments: images)
    func copiesFilesAndFoldersInAndOut(image: String) async throws {
        let folder = try Integration.makeTemporaryFolder("cp")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tree = try makeLocalTree(in: folder)
        let expected = try contents(of: tree)
        #expect(expected.count == 4)

        try await Integration.withContainer(backend, image: image) { id in
            try await backend.makeDirectory(id, path: "/up")

            // A file, to exactly the given path (the local name does not matter).
            let localFile = tree.appending(path: "top file.txt").path(percentEncoded: false)
            try await backend.copyIn(id, localPath: localFile, to: "/up/uploaded file.txt")
            #expect(try await backend.readFile(id, path: "/up/uploaded file.txt", maxBytes: 100) == Data("top\n".utf8))
            try await backend.copyIn(
                id, localPath: tree.appending(path: "binary.bin").path(percentEncoded: false), to: "/up/b.bin")
            #expect(try await backend.readFile(id, path: "/up/b.bin", maxBytes: 1000) == Data(0...255))

            // A folder, to exactly the given path.
            try await backend.copyIn(id, localPath: tree.path(percentEncoded: false) + "/", to: "/up/tree copy")
            let found = try await Integration.shell(backend, id, "cd '/up/tree copy' && find . -type f | sort")
            #expect(
                Set(found.split(separator: "\n").map { String($0.dropFirst(2)).precomposedStringWithCanonicalMapping })
                    == Set(expected.keys))

            // Replacing: a second upload to the same path replaces the file or folder, it does not nest.
            try Data("changed\n".utf8).write(to: tree.appending(path: "top file.txt"))
            try await backend.copyIn(id, localPath: localFile, to: "/up/uploaded file.txt")
            #expect(
                try await backend.readFile(id, path: "/up/uploaded file.txt", maxBytes: 100) == Data("changed\n".utf8))
            try FileManager.default.removeItem(at: tree.appending(path: "binary.bin"))
            try await backend.copyIn(id, localPath: tree.path(percentEncoded: false), to: "/up/tree copy")
            let again = try await Integration.shell(backend, id, "cd '/up/tree copy' && find . | sort")
            #expect(!again.contains("local tree"), "the folder was nested inside the existing one:\n\(again)")
            #expect(!again.contains("binary.bin"), "the old folder was merged instead of replaced:\n\(again)")
            #expect(again.contains("./top file.txt"))
            #expect(
                try await backend.readFile(id, path: "/up/tree copy/top file.txt", maxBytes: 100)
                    == Data("changed\n".utf8))

            // A file uploaded to a path where a folder is replaces the folder (same contract).
            try await backend.makeDirectory(id, path: "/up/was-a-folder")
            try await backend.copyIn(id, localPath: localFile, to: "/up/was-a-folder")
            let kind = try await backend.listDirectory(id, path: "/up", limit: 100).entries.first {
                $0.name == "was-a-folder"
            }?.kind
            #expect(kind == .file)

            // A local path with a colon goes through a staging folder.
            let colon = folder.appending(path: "with:colon.txt")
            try Data("colon\n".utf8).write(to: colon)
            try await backend.copyIn(id, localPath: colon.path(percentEncoded: false), to: "/up/colon.txt")
            #expect(try await backend.readFile(id, path: "/up/colon.txt", maxBytes: 100) == Data("colon\n".utf8))

            // Out: a file, replacing an existing local file; a folder, replacing an existing local folder.
            let out = folder.appending(path: "out dir")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let savedFile = out.appending(path: "saved file.txt")
            try await backend.copyOut(id, path: "/up/uploaded file.txt", to: savedFile.path(percentEncoded: false))
            #expect(try Data(contentsOf: savedFile) == Data("changed\n".utf8))
            try await backend.copyOut(id, path: "/up/b.bin", to: savedFile.path(percentEncoded: false))
            #expect(try Data(contentsOf: savedFile) == Data(0...255))

            let savedTree = out.appending(path: "saved tree")
            try await backend.copyOut(id, path: "/up/tree copy", to: savedTree.path(percentEncoded: false))
            #expect(try contents(of: savedTree) == (try contents(of: tree)))
            try await Integration.shell(backend, id, "rm '/up/tree copy/top file.txt'")
            try await backend.copyOut(id, path: "/up/tree copy", to: savedTree.path(percentEncoded: false))
            #expect(try contents(of: savedTree).keys.contains("top file.txt") == false)
            #expect(try contents(of: savedTree).count == 2)

            // Names that need care on the container side.
            try await Integration.shell(backend, id, CLIBackendFilesIntegrationTests.awkwardScript)
            let dash = out.appending(path: "dash")
            try await backend.copyOut(id, path: "/work/-dash", to: dash.path(percentEncoded: false))
            #expect(try Data(contentsOf: dash) == Data("x".utf8))
            let newline = out.appending(path: "newline")
            try await backend.copyOut(id, path: "/work/new\nline", to: newline.path(percentEncoded: false))
            #expect(try Data(contentsOf: newline) == Data("n".utf8))

            // Failures name the command and leave nothing half-written behind.
            let ghost = out.appending(path: "ghost")
            let missing = await Integration.backendError {
                try await backend.copyOut(id, path: "/up/nope", to: ghost.path(percentEncoded: false))
            }
            guard case .commandFailed(let command, 1, let message) = missing else {
                Issue.record("expected commandFailed, got \(String(describing: missing))")
                return
            }
            #expect(command.contains(" copy -- \(id):/up/nope "))
            #expect(message.contains("path not found"))
            #expect(!FileManager.default.fileExists(atPath: ghost.path(percentEncoded: false)))

            let colonPath = await Integration.backendError {
                try await backend.copyOut(id, path: "/up/a:b", to: ghost.path(percentEncoded: false))
            }
            guard case .unsupported = colonPath else {
                Issue.record("expected unsupported, got \(String(describing: colonPath))")
                return
            }
            let noSource = await Integration.backendError {
                try await backend.copyIn(
                    id, localPath: folder.appending(path: "nope").path(percentEncoded: false), to: "/up/x")
            }
            guard case .other = noSource else {
                Issue.record("expected a refusal, got \(String(describing: noSource))")
                return
            }
            // CLI 1.5.0 creates a missing parent folder rather than failing.
            try await backend.copyIn(id, localPath: localFile, to: "/cd-it-new-dir/deeper/x.txt")
            #expect(
                try await backend.readFile(id, path: "/cd-it-new-dir/deeper/x.txt", maxBytes: 100)
                    == Data("changed\n".utf8))

            // An upload never replaces a system directory.
            let system = await Integration.backendError {
                try await backend.copyIn(id, localPath: localFile, to: "/etc")
            }
            guard case .other(let refusal) = system else {
                Issue.record("expected a refusal, got \(String(describing: system))")
                return
            }
            #expect(refusal.contains("system directory"))
            #expect(
                try await backend.listDirectory(id, path: "/etc", limit: 1000).entries.contains { $0.name == "passwd" })
        }
    }

    /// `container cp` 1.5.0 decomposes accented characters in container paths and mangles non-ASCII names
    /// inside uploaded folders; the backend has to deliver the exact bytes anyway.
    @Test(arguments: images)
    func copiesKeepUnicodeNamesByteForByte(image: String) async throws {
        let folder = try Integration.makeTemporaryFolder("unicode")
        defer { try? FileManager.default.removeItem(at: folder) }
        let precomposed = "caf\u{E9}"  // how Linux tools write it
        let decomposed = "cafe\u{301}"
        let umlauts = "\u{FC}n\u{EF} dir"
        /// Names in `path`, as raw bytes (Swift compares strings by canonical equivalence, which would hide
        /// exactly the difference under test).
        func rawNames(_ id: String, _ path: String) async throws -> Set<[UInt8]> {
            Set(try await backend.listDirectory(id, path: path, limit: 1000).entries.map { Array($0.name.utf8) })
        }
        try await Integration.withContainer(backend, image: image) { id in
            // Written as printf escapes: `Process` would decompose a precomposed character in an argument.
            try await Integration.shell(
                backend, id,
                #"""
                n=$(printf 'caf\303\251') j=$(printf '\346\227\245\346\234\254')
                mkdir -p "/u/$n dir" && printf nfc > "/u/$n.txt" && printf deep > "/u/$n dir/$n $j.txt"
                """#)
            #expect(try await rawNames(id, "/u").contains(Array("\(precomposed).txt".utf8)))

            // Out: a precomposed file name, and a precomposed folder with unicode names inside.
            let file = folder.appending(path: "file out")
            try await backend.copyOut(id, path: "/u/\(precomposed).txt", to: file.path(percentEncoded: false))
            #expect(try Data(contentsOf: file) == Data("nfc".utf8))
            let tree = folder.appending(path: "tree out")
            try await backend.copyOut(id, path: "/u/\(precomposed) dir", to: tree.path(percentEncoded: false))
            #expect(try contents(of: tree) == ["\(precomposed) 日本.txt": Data("deep".utf8)])
            // The temporary link is gone again.
            let leftovers = try await Integration.shell(backend, id, "ls -A /")
            #expect(!leftovers.contains(".cd-copy-"))

            // The exec-based calls reach precomposed names too.
            #expect(try await backend.readFile(id, path: "/u/\(precomposed).txt", maxBytes: 10) == Data("nfc".utf8))
            #expect(
                try await backend.listDirectory(id, path: "/u/\(precomposed) dir", limit: 10).entries.map(\.name)
                    == ["\(precomposed) 日本.txt"])
            try await backend.makeDirectory(id, path: "/u/\(precomposed) made")
            try await backend.moveItem(id, from: "/u/\(precomposed) made", to: "/u/\(precomposed) moved")
            #expect(try await rawNames(id, "/u").contains(Array("\(precomposed) moved".utf8)))
            try await backend.deleteItem(id, path: "/u/\(precomposed) moved")
            #expect(try await rawNames(id, "/u").count == 2)
            let ghost = await Integration.backendError {
                try await backend.copyOut(id, path: "/u/\(precomposed) ghost", to: file.path(percentEncoded: false))
            }
            guard case .commandFailed(_, _, let ghostMessage) = ghost else {
                Issue.record("expected commandFailed, got \(String(describing: ghost))")
                return
            }
            #expect(ghostMessage.contains("/u/\(precomposed) ghost"))

            // In: a file to a precomposed name keeps the precomposed bytes (plain `cp` would decompose them).
            try await backend.makeDirectory(id, path: "/in")
            try await backend.copyIn(id, localPath: file.path(percentEncoded: false), to: "/in/\(precomposed).txt")
            #expect(try await rawNames(id, "/in") == [Array("\(precomposed).txt".utf8)])
            #expect(try await backend.readFile(id, path: "/in/\(precomposed).txt", maxBytes: 10) == Data("nfc".utf8))
            // …and replaces it rather than adding a look-alike.
            try Data("second".utf8).write(to: file)
            try await backend.copyIn(id, localPath: file.path(percentEncoded: false), to: "/in/\(precomposed).txt")
            #expect(try await rawNames(id, "/in") == [Array("\(precomposed).txt".utf8)])
            #expect(try await backend.readFile(id, path: "/in/\(precomposed).txt", maxBytes: 10) == Data("second".utf8))
            // A decomposed destination is delivered decomposed.
            try await backend.copyIn(id, localPath: file.path(percentEncoded: false), to: "/in/\(decomposed).md")
            #expect(try await rawNames(id, "/in").contains(Array("\(decomposed).md".utf8)))

            // In: a folder whose contents have non-ASCII names (plain `cp` turns them into `*`).
            let local = folder.appending(path: "local \(precomposed)")
            let nested = local.appending(path: "\(umlauts)/日本語")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("1".utf8).write(to: local.appending(path: "plain.txt"))
            try Data("2".utf8).write(to: local.appending(path: "\(umlauts)/\(precomposed).txt"))
            try Data("3".utf8).write(to: nested.appending(path: "ファイル.txt"))
            try await backend.copyIn(id, localPath: local.path(percentEncoded: false), to: "/in/tree \(precomposed)")
            let found = try await Integration.shell(backend, id, "cd /in/tree* && find . | sort")
            #expect(!found.contains("*"), "names were mangled:\n\(found)")
            #expect(!found.contains(".cd-"), "placeholders were left behind:\n\(found)")
            #expect(try await rawNames(id, "/in").contains(Array("tree \(precomposed)".utf8)))
            #expect(
                try await rawNames(id, "/in/tree \(precomposed)")
                    == [Array("plain.txt".utf8), Array(umlauts.utf8)])
            #expect(
                try await backend.readFile(id, path: "/in/tree \(precomposed)/\(umlauts)/日本語/ファイル.txt", maxBytes: 10)
                    == Data("3".utf8))
            #expect(
                try await backend.readFile(
                    id, path: "/in/tree \(precomposed)/\(umlauts)/\(precomposed).txt", maxBytes: 10)
                    == Data("2".utf8))
            // Nothing temporary is left next to the uploads.
            let stray = try await Integration.shell(backend, id, "ls -A /in /")
            #expect(!stray.contains(".cd-"))

            // Round trip.
            let back = folder.appending(path: "back")
            try await backend.copyOut(id, path: "/in/tree \(precomposed)", to: back.path(percentEncoded: false))
            #expect(try contents(of: back) == (try contents(of: local)))
        }
    }

    /// `container cp` 1.5.0 only sees the root filesystem: it cannot read from a volume, a bind mount or a
    /// tmpfs, and what it "writes" there lands underneath the mount. The backend has to reach them anyway.
    @Test func copiesToAndFromVolumesBindMountsAndTmpfs() async throws {
        let folder = try Integration.makeTemporaryFolder("mounts")
        defer { try? FileManager.default.removeItem(at: folder) }
        let shared = folder.appending(path: "shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("from the mac".utf8).write(to: shared.appending(path: "host.txt"))
        let upload = folder.appending(path: "upload.txt")
        try Data("uploaded".utf8).write(to: upload)
        let tree = folder.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("leaf".utf8).write(to: tree.appending(path: "sub/leaf.txt"))

        let volume = Integration.uniqueName("vol")
        try await backend.createVolume(name: volume, size: nil, journal: nil, labels: [:])
        do {
            try await Integration.withContainer(backend) { spec in
                spec.mounts = [
                    .init(kind: .volume(name: volume), target: "/vol"),
                    .init(kind: .bind(hostPath: shared.path(percentEncoded: false)), target: "/bind"),
                ]
                spec.tmpfs = ["/scratch"]
            } _: { id in
                try await Integration.shell(
                    backend, id, "printf v > /vol/inside.txt && printf t > /scratch/inside.txt && printf s > /dev/shm/s"
                )
                for (directory, inside) in [("/vol", "v"), ("/scratch", "t"), ("/bind", "from the mac")] {
                    // In: the file is visible inside the container, where a plain `cp` would have hidden it.
                    try await backend.copyIn(
                        id, localPath: upload.path(percentEncoded: false), to: "\(directory)/up.txt")
                    #expect(
                        try await backend.readFile(id, path: "\(directory)/up.txt", maxBytes: 100)
                            == Data("uploaded".utf8),
                        "\(directory)")
                    try await backend.copyIn(id, localPath: tree.path(percentEncoded: false), to: "\(directory)/tree")
                    #expect(
                        try await backend.readFile(id, path: "\(directory)/tree/sub/leaf.txt", maxBytes: 100)
                            == Data("leaf".utf8), "\(directory)")
                    // …and replaces on a second upload.
                    try await backend.copyIn(
                        id, localPath: upload.path(percentEncoded: false), to: "\(directory)/up.txt")
                    #expect(
                        try await backend.listDirectory(id, path: directory, limit: 100).entries.count {
                            $0.name.hasPrefix("up")
                        }
                            == 1, "\(directory)")

                    // Out: a file and a folder.
                    let name = directory == "/bind" ? "host.txt" : "inside.txt"
                    let out = folder.appending(path: "out\(directory.replacingOccurrences(of: "/", with: "-"))")
                    try await backend.copyOut(id, path: "\(directory)/\(name)", to: out.path(percentEncoded: false))
                    #expect(try Data(contentsOf: out) == Data(inside.utf8), "\(directory)")
                    let outTree = folder.appending(path: "tree\(directory.replacingOccurrences(of: "/", with: "-"))")
                    try await backend.copyOut(id, path: "\(directory)/tree", to: outTree.path(percentEncoded: false))
                    #expect(try contents(of: outTree) == ["sub/leaf.txt": Data("leaf".utf8)], "\(directory)")
                }
                // The bind mount shows the upload on the Mac side too.
                #expect(try Data(contentsOf: shared.appending(path: "up.txt")) == Data("uploaded".utf8))
                let shm = folder.appending(path: "shm")
                try await backend.copyOut(id, path: "/dev/shm/s", to: shm.path(percentEncoded: false))
                #expect(try Data(contentsOf: shm) == Data("s".utf8))

                // A mount point itself is never replaced by an upload.
                let refused = await Integration.backendError {
                    try await backend.copyIn(id, localPath: tree.path(percentEncoded: false), to: "/vol")
                }
                guard case .other(let reason) = refused else {
                    Issue.record("expected a refusal, got \(String(describing: refused))")
                    return
                }
                #expect(reason.contains("mount point"))
                // Nothing temporary is left in the root filesystem.
                #expect(!(try await Integration.shell(backend, id, "ls -A /")).contains(".cd-"))
            }
            try? await backend.deleteVolume(volume)
        } catch {
            try? await backend.deleteVolume(volume)
            throw error
        }
        #expect(try await !backend.listVolumes().contains { $0.name == volume })
    }
}
