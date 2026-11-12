import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// The Files tab model against `MockBackend`'s fake filesystem.
@MainActor
@Suite("Container files model")
struct ContainerFilesModelTests {
    func makeModel(
        _ id: String = "api", mounts: [Container.Mount] = []
    ) async -> (ContainerFilesModel, MockBackend, TaskCenter) {
        let backend = MockBackend()
        await backend.setLatency(.zero)
        let tasks = TaskCenter()
        let files = ContainerFilesModel(
            containerID: id, backend: backend, taskCenter: tasks, mounts: mounts, defaults: TestSupport.defaults())
        return (files, backend, tasks)
    }

    func names(_ files: ContainerFilesModel) -> [String] { files.rows.compactMap { $0.entry?.name } }

    @Test func loadsRootFoldersFirstAndHidesDotFiles() async {
        let (files, _, _) = await makeModel()
        #expect(files.currentState == nil)
        await files.start()
        guard case .loaded = files.currentState else {
            Issue.record("root did not load")
            return
        }
        let rows = files.rows
        #expect(rows.allSatisfy { $0.depth == 0 })
        #expect(!names(files).contains(".dockerenv"))
        // Folders (and links to folders) come before files.
        let firstFile = rows.firstIndex { $0.entry?.isBrowsable == false }
        let lastFolder = rows.lastIndex { $0.entry?.isBrowsable == true }
        if let firstFile, let lastFolder { #expect(lastFolder < firstFile) }
        files.showHidden = true
        #expect(names(files).contains(".dockerenv"))
    }

    @Test func showHiddenIsRemembered() async {
        let defaults = TestSupport.defaults()
        let backend = MockBackend()
        let first = ContainerFilesModel(
            containerID: "api", backend: backend, taskCenter: TaskCenter(), defaults: defaults)
        #expect(!first.showHidden)
        first.showHidden = true
        let second = ContainerFilesModel(
            containerID: "db", backend: backend, taskCenter: TaskCenter(), defaults: defaults)
        #expect(second.showHidden)
    }

    @Test func expandsLazilyAndNestsRows() async {
        let (files, _, _) = await makeModel()
        await files.start()
        #expect(files.folders["/app"] == nil)  // nothing below the root is loaded up front
        await files.toggleExpanded("/app")
        guard case .loaded = files.folders["/app"] else {
            Issue.record("/app did not load")
            return
        }
        let nested = files.rows.filter { $0.depth == 1 }
        #expect(nested.contains { $0.path == "/app/app.py" })
        #expect(nested.contains { $0.path == "/app/release notes.txt" })
        // The link /app/current → /app/static is browsable and expands through the link.
        await files.toggleExpanded("/app/current")
        #expect(files.rows.contains { $0.path == "/app/current/logo.png" && $0.depth == 2 })
        await files.toggleExpanded("/app")
        #expect(files.rows.allSatisfy { $0.depth == 0 })
    }

    @Test func placeholdersForEmptyTruncatedAndFailedFolders() async {
        let (files, backend, _) = await makeModel()
        await files.navigate(to: "/app/data")
        await files.toggleExpanded("/app/data/events")
        let truncated = files.rows.last
        #expect(truncated?.content == .truncated(shown: ContainerFilesModel.entryLimit))
        #expect(files.rows.count == ContainerFilesModel.entryLimit + 2)

        await files.navigate(to: "/")
        await files.toggleExpanded("/mnt")
        #expect(files.rows.contains { $0.content == .empty && $0.path == "/mnt" })

        // A folder that disappears between listing and expanding shows an inline error row.
        try? await backend.makeDirectory("api", path: "/gone")
        await files.refresh()
        try? await backend.deleteItem("api", path: "/gone")
        await files.toggleExpanded("/gone")
        #expect(
            files.rows.contains {
                if case .failure = $0.content { return $0.path == "/gone" }
                return false
            })
    }

    @Test func navigationHistory() async {
        let (files, _, _) = await makeModel()
        await files.start()
        #expect(!files.canGoBack && !files.canGoUp)
        await files.navigate(to: "app")  // relative to /
        #expect(files.path == "/app")
        await files.navigate(to: "docs/../static/")
        #expect(files.path == "/app/static")
        #expect(names(files) == ["logo.png"])
        await files.goUp()
        #expect(files.path == "/app")
        await files.goBack()
        #expect(files.path == "/app/static")
        await files.goBack()
        await files.goBack()
        #expect(files.path == "/")
        #expect(!files.canGoBack)

        await files.navigate(to: "/does/not/exist")
        guard case .failed(let error) = files.currentState else {
            Issue.record("expected a failure state")
            return
        }
        #expect(error.errorDescription?.contains("does not exist") == true)
        #expect(files.canGoBack)
    }

    @Test func marksMountPointsAndProtectsThem() async {
        let mount = Container.Mount(
            destination: "/var/lib/postgresql/data", source: "/vol/pgdata.img",
            type: .volume(name: "pgdata", format: "ext4"))
        let (files, _, _) = await makeModel("db", mounts: [mount])
        await files.navigate(to: "/var/lib/postgresql")
        let row = files.rows.first { $0.path == "/var/lib/postgresql/data" }
        #expect(row?.mount == mount)
        #expect(files.deletionRefusal("/var/lib/postgresql/data") != nil)
        #expect(files.deletionRefusal("/var/lib/postgresql") != nil)
        #expect(files.deletionRefusal("/") != nil)
        #expect(files.deletionRefusal("/var/lib/postgresql/data/PG_VERSION") == nil)
        await files.delete(["/var/lib/postgresql/data"])
        #expect(files.actionError != nil)
        #expect(files.rows.contains { $0.path == "/var/lib/postgresql/data" })
    }

    @Test func newFolderRenameAndDelete() async {
        let (files, _, _) = await makeModel()
        await files.navigate(to: "/app")
        #expect(await files.makeFolder(named: "new folder", in: "/app"))
        #expect(names(files).contains("new folder"))
        #expect(await files.makeFolder(named: "a/b", in: "/app") == false)
        #expect(files.actionError != nil)
        // The backend's own failure keeps the exact command.
        #expect(await files.makeFolder(named: "new folder", in: "/app") == false)
        guard case .commandFailed(let command, _, _) = files.actionError else {
            Issue.record("expected commandFailed")
            return
        }
        #expect(command == "container exec -- api mkdir -- '/app/new folder'")

        #expect(files.renameProblem("/app/README.md", to: "app.py") == "“app.py” already exists in this folder.")
        #expect(files.renameProblem("/app/README.md", to: "README.md") != nil)
        #expect(files.renameProblem("/app/README.md", to: "READ ME.md") == nil)
        #expect(await files.rename("/app/README.md", to: "app.py") == false)
        #expect(await files.rename("/app/README.md", to: "READ ME.md"))
        #expect(files.actionError == nil)
        #expect(names(files).contains("READ ME.md") && !names(files).contains("README.md"))

        files.selection = ["/app/READ ME.md", "/app/new folder"]
        await files.delete(["/app/READ ME.md", "/app/new folder"])
        #expect(!names(files).contains("READ ME.md") && !names(files).contains("new folder"))
        #expect(files.selection.isEmpty)
    }

    @Test func uploadAndDownloadRunAsActivityTasks() async throws {
        let (files, _, tasks) = await makeModel()
        await files.navigate(to: "/app")
        let workspace = FileManager.default.temporaryDirectory.appending(path: "cd-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let local = workspace.appending(path: "notes from mac.txt")
        try Data("hello".utf8).write(to: local)
        let existing = workspace.appending(path: "app.py")
        try Data("x".utf8).write(to: existing)
        #expect(files.uploadConflicts([local, existing], in: "/app") == ["app.py"])

        let upload = files.upload([local], into: "/app")
        await upload.wait()
        #expect(upload.state == .succeeded)
        #expect(upload.lines.map(\.text).first?.hasPrefix("Copying ") == true)
        #expect(upload.lines.map(\.text).last == "Uploaded notes from mac.txt to api:/app")
        #expect(names(files).contains("notes from mac.txt"))  // the folder was reloaded

        let target = workspace.appending(path: "saved.txt").path(percentEncoded: false)
        let download = files.download([("/app/requirements.txt", target)])
        await download.wait()
        #expect(download.state == .succeeded)
        #expect(try String(contentsOfFile: target, encoding: .utf8).contains("uvicorn"))
        #expect(tasks.tasks.count == 2)

        let failing = files.download([("/app/missing", target)])
        await failing.wait()
        guard case .failed(.commandFailed(let command, _, _)) = failing.state else {
            Issue.record("expected a failed task")
            return
        }
        #expect(command.hasPrefix("container copy -- api:/app/missing "))
    }

    @Test func previewsTextAndDetectsBinary() async throws {
        let (files, _, _) = await makeModel()
        let text = try await files.preview(ContainerFileEntry(name: "app.py", kind: .file), at: "/app/app.py")
        guard case .text(let body, let truncated) = text else {
            Issue.record("expected text")
            return
        }
        #expect(body.contains("FastAPI") && !truncated)
        #expect(
            try await files.preview(ContainerFileEntry(name: "logo.png", kind: .file), at: "/app/static/logo.png")
                == .binary)

        #expect(FilePreview.classify(Data(), truncated: false) == .empty)
        #expect(FilePreview.classify(Data([0x61, 0x00, 0x62]), truncated: false) == .binary)
        #expect(FilePreview.classify(Data([0xFF, 0xFE, 0x41]), truncated: false) == .binary)
        #expect(FilePreview.classify(Data("héllo".utf8), truncated: false) == .text("héllo", truncated: false))
        // A read that stops in the middle of "é" still previews as text.
        #expect(FilePreview.classify(Data("hé".utf8).dropLast(), truncated: true) == .text("h", truncated: true))
        #expect(FilePreview.classify(Data("hé".utf8).dropLast(), truncated: false) == .binary)
    }

    @Test func shellLessImageIsUnavailableNotAnError() async {
        let (files, backend, _) = await makeModel()
        var distroless = MockFileSystem()
        distroless.hasShell = false
        await backend.setFileSystem(distroless, for: "api")
        await files.start()
        #expect(files.unavailable == .noShell)
        #expect(files.rows.isEmpty)
    }

    @Test func taskStepsStreamLabelsAndStopAtTheFirstFailure() async {
        let tasks = TaskCenter()
        let task = tasks.run(
            title: "Steps",
            steps: [
                TaskStep("one") {}, TaskStep("two") { throw BackendError.other("boom") }, TaskStep("three") {},
            ], summary: "done")
        await task.wait()
        #expect(task.state == .failed(.other("boom")))
        #expect(task.lines.map(\.text) == ["one", "two"])
    }
}
