import Foundation
import Testing
import ContainerKit
@testable import AppCore
@testable import DesignSystem

@Suite struct SecretMaskingParityTests {
    /// (key, value, should be masked)
    static let table: [(String, String, Bool)] = [
        ("POSTGRES_PASSWORD", "hunter2", true),
        ("DB_PASS", "hunter2", true),
        ("REDIS_PASS", "hunter2", true),
        ("MYSQL_PWD", "hunter2", true),
        ("GITHUB_PAT", "ghp_abc", true),
        ("GITHUB_TOKEN", "ghp_abc", true),
        ("AWS_SECRET_ACCESS_KEY", "abc", true),
        ("API_KEY", "abc", true),
        ("X_AUTH", "abc", true),
        ("BASIC_AUTHORIZATION", "abc", true),
        ("GCP_CREDENTIALS", "abc", true),
        ("TLS_PRIVATE", "abc", true),
        ("TLS_CERT", "abc", true),
        ("DATABASE_URL", "postgres://app:s3cr3t@db:5432/app", true),
        ("PATH", "/usr/bin", false),
        ("PWD", "/home/app", false),
        ("OLDPWD", "/", false),
        ("GIT_AUTHOR_NAME", "Ada", false),
        ("PYTHON_VERSION", "3.15.0", false),
        ("LANG", "C.UTF-8", false),
        ("PUBLIC_URL", "https://example.com/x", false),
    ]

    @Test(arguments: table.indices)
    func everySurfaceAgrees(_ index: Int) {
        let (key, value, secret) = Self.table[index]
        let entry = "\(key)=\(value)"
        // 1. Environment tab
        let variable = EnvironmentVariable(parsing: entry)
        #expect(variable.isSensitive == secret, "\(key)")
        #expect(variable.displayValue(reveal: false).contains(passwordPart(value)) == !secret, "\(key)")
        #expect(variable.displayValue(reveal: true) == value)
        // 2. Image config (EnvironmentMasking shim)
        #expect(EnvironmentMasking.split(entry).secret == secret)
        #expect(EnvironmentMasking.masked(entry).contains(passwordPart(value)) == !secret, "\(key)")
        // 3. Run sheet preview / "Copy container run" (commandLineString)
        var spec = RunSpec(image: "alpine")
        spec.environment = [entry]
        #expect(spec.commandLineString.contains(passwordPart(value)) == !secret, "\(key)")
        #expect(spec.commandLineString(maskSecrets: false).contains(passwordPart(value)))
        // 4. Recreate copy
        // (RunSpec(recreating:) feeds the same commandLineString; covered by 3.)
        // 5. ErrorBanner failedCommand: masks every -e value, secret or not.
        let failed = BackendError.commandFailed(command: spec.commandLineString(maskSecrets: false), exitCode: 1, message: "x")
        if secret { #expect(!(failed.maskedFailedCommand ?? "").contains(passwordPart(value)), "\(key)") }
        #expect(failed.maskedFailedCommand?.contains(key) == true)
    }

    /// The part of `value` that must disappear when masked (the password for credential URLs).
    private func passwordPart(_ value: String) -> String {
        if value.contains("://"), let range = EnvironmentVariable.urlCredentialRange(in: value) { return String(value[range]) }
        return value
    }

    @Test func credentialURLKeepsHost() {
        let v = EnvironmentVariable(key: "DATABASE_URL", value: "postgres://app:s3cr3t@db:5432/app")
        #expect(v.displayValue(reveal: false) == "postgres://app:••••@db:5432/app")
        #expect(v.maskedEntry == "DATABASE_URL=postgres://app:••••@db:5432/app")
    }

    @Test func failedCommandMasksQuotedForms() {
        let cmd = #"container run -d -e 'A_TOKEN=x y' -e "B=two words" --env C=plain -e D='q v' alpine"#
        let masked = BackendError.commandFailed(command: cmd, exitCode: 1, message: "").maskedFailedCommand ?? ""
        #expect(masked == #"container run -d -e 'A_TOKEN=…' -e "B=…" --env C=… -e D=… alpine"#)
        let login = BackendError.commandFailed(command: "container image pull https://u:pw@reg/x", exitCode: 1, message: "")
        #expect(login.maskedFailedCommand == "container image pull https://u:••••@reg/x")
    }

    @Test func environmentRowsHaveUniqueIDs() {
        let vars = EnvironmentVariable.parse(["A=1", "B=2", "A=3"])
        #expect(vars.map(\.ordinal) == [0, 1, 2])
        #expect(Set(vars.map(\.id)).count == 3)
        #expect(vars[0].id == "A")          // first occurrence keeps the plain key
        #expect(vars[2].id == "A#2")
    }

    @Test func dotEnvAcceptsExportTab() {
        #expect(DotEnv.parse("export\tA=1\nexported=2").map(\.entry) == ["A=1", "exported=2"])
    }
}

@Suite struct ShellWordsPOSIXTests {
    @Test func backslashInsideDoubleQuotesIsKeptUnlessSpecial() {
        #expect(ShellWords.split(#"sh -c "grep \d+ C:\path""#) == ["sh", "-c", #"grep \d+ C:\path"#])
        #expect(ShellWords.split(#"echo "a \"b\" \\ \$HOME \`x\`""#) == ["echo", #"a "b" \ $HOME `x`"#])
        #expect(ShellWords.split(#"echo 'no \escapes'"#) == ["echo", #"no \escapes"#])
        #expect(ShellWords.split(#"a\ b c"#) == ["a b", "c"])
    }

    @Test func unterminatedQuoteIsReported() {
        #expect(ShellWords.splitIfValid("echo 'oops") == nil)
        #expect(throws: ShellWords.ParseError.unterminatedQuote("\"")) { try ShellWords.parse(#"echo "oops"#) }
        #expect(ShellWords.splitIfValid("echo 'fine'") == ["echo", "fine"])
        #expect(ShellWords.split("echo 'oops") == ["echo", "oops"])     // lenient form still splits
    }

    @Test func joinQuotesEveryMetacharacterAndRoundTrips() {
        for word in ["|", ";", "&", "<", ">", "*", "?", "~", "#", "(", ")", "'", "a b", "$HOME", "`id`", "[x]", "{a,b}",
                     "!", "^", "sh|id", "sh>~/.zshrc", "/bin/a*", "it's", "", "plain-word_1.2/x:y=z@w%"] {
            let joined = ShellWords.join([word])
            #expect(ShellWords.split(joined) == [word], "\(word) → \(joined)")
            if word == "plain-word_1.2/x:y=z@w%" { #expect(joined == word) } else { #expect(joined.hasPrefix("'"), "\(word)") }
        }
    }
}
