import ContainerKit
import Foundation
import Testing

@testable import AppCore

/// `env_file:` handling. `container run --env-file` on CLI 1.5.0 takes lines literally (observed on a live
/// engine), so files that rely on Compose's reading are turned into `-e` options.
@Suite("Compose env files")
struct ComposeEnvFileTests {
    @Test func literalFilesAreRecognised() {
        #expect(DotEnv.isLiteral("# comment\n\nA=1\nB=two words\nC=caf\u{E9}\nD=a=b\nE=\n"))
        #expect(!DotEnv.isLiteral("A=\"quoted\""))
        #expect(!DotEnv.isLiteral("A='quoted'"))
        #expect(!DotEnv.isLiteral("A=value # comment"))
        #expect(!DotEnv.isLiteral("export A=1"))
        #expect(!DotEnv.isLiteral("A = 1"))
        #expect(!DotEnv.isLiteral("A=1 "))
        #expect(!DotEnv.isLiteral("  A=1"))
        #expect(!DotEnv.isLiteral("JUSTAKEY"))
        #expect(DotEnv.isLiteral("A=it's fine\nB=a#b"))
    }

    @Test func inlineCommentsAreStrippedOnlyOnRequestAndOnlyOutsideQuotes() {
        let text = "A=value # note\nB=\"kept # inside\"\nC=a#b\n"
        #expect(DotEnv.parse(text).map(\.value) == ["value # note", "kept # inside", "a#b"])
        #expect(DotEnv.parse(text, stripInlineComments: true).map(\.value) == ["value", "kept # inside", "a#b"])
    }

    private func plan(_ files: [String: String]) throws -> ComposePlan {
        let yaml = """
            name: demo
            services:
              app:
                image: alpine
                env_file: [one.env, two.env]
                environment:
                  OVERRIDDEN: from environment
                  ADDED: "yes"
            """
        let project = ComposeProject(file: try ComposeParser.parse(yaml, variables: [:]), directory: "/proj")
        return ComposePlanner.plan(project, home: "/Users/me", pathExists: { _ in true }) { path in
            files[(path as NSString).lastPathComponent]
        }
    }

    @Test func literalFilesStayOnTheCommandLineAsFiles() throws {
        let plan = try plan(["one.env": "A=1\nOVERRIDDEN=from file\n", "two.env": "# only\nB=two words\n"])
        let spec = try #require(plan.runSpec("app"))
        #expect(spec.envFiles == ["/proj/one.env", "/proj/two.env"])
        #expect(spec.environment == ["OVERRIDDEN=from environment", "ADDED=yes"])
        #expect(!plan.warnings.contains { $0.key == "env_file" })
    }

    @Test func filesTheCLIWouldMisreadBecomeEnvironmentOptions() throws {
        let plan = try plan([
            "one.env": "A=1\nSECRET=\"p w\"\nOVERRIDDEN=from file\nexport EXPORTED=yes\nINHERIT\n",
            "two.env": "A=from two\nNOTE=value # trailing\n",
        ])
        let spec = try #require(plan.runSpec("app"))
        #expect(spec.envFiles.isEmpty)
        // File order, a later file wins, `environment:` wins over both and keeps its own entries.
        #expect(
            spec.environment == [
                "A=from two", "SECRET=p w", "EXPORTED=yes", "INHERIT", "NOTE=value",
                "OVERRIDDEN=from environment", "ADDED=yes",
            ])
        let note = try #require(plan.warnings.first { $0.key == "env_file" })
        #expect(note.message.contains("one.env"))
        #expect(note.message.contains("6 variable(s)"))
    }
}
