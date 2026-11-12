import Foundation
import Testing

@testable import ContainerKit

@Suite("Compose health checks and restart policies")
struct ComposeHealthcheckTests {
    private func service(_ body: String) throws -> (ComposeService, [ComposeWarning]) {
        let file = try ComposeParser.parse("services:\n  db:\n    image: x\n" + body)
        return (try #require(file.service(named: "db")), file.warnings)
    }

    @Test(arguments: [
        ("30s", Duration.seconds(30)), ("1m30s", .seconds(90)), ("500ms", .milliseconds(500)),
        ("1h", .seconds(3600)), ("1.5s", .milliseconds(1500)), ("2h3m4s5ms", .milliseconds(7_384_005)),
        ("45", .seconds(45)), ("0s", .zero), ("250us", .microseconds(250)), (" 10s ", .seconds(10)),
    ])
    func durations(text: String, expected: Duration) {
        #expect(ComposeDuration.parse(text) == expected)
    }

    @Test(arguments: ["", "abc", "10x", "s", "-5s", "1m30", "1 m"])
    func notDurations(text: String) {
        #expect(ComposeDuration.parse(text) == nil)
    }

    @Test func durationsFormatBack() {
        #expect(ComposeDuration.format(.seconds(90)) == "1m30s")
        #expect(ComposeDuration.format(.milliseconds(500)) == "500ms")
        #expect(ComposeDuration.format(.seconds(3600)) == "1h")
        #expect(ComposeDuration.format(.zero) == "0s")
        #expect(ComposeDuration.format(.milliseconds(1500)) == "1s500ms")
    }

    @Test func execFormWithEveryTiming() throws {
        let (db, warnings) = try service(
            """
                healthcheck:
                  test: ["CMD", "pg_isready", "-U", "app"]
                  interval: 1m30s
                  timeout: 500ms
                  retries: 5
                  start_period: 10s
                  start_interval: 2s
            """)
        var expected = ComposeHealthcheck(command: ["pg_isready", "-U", "app"])
        expected.interval = .seconds(90)
        expected.timeout = .milliseconds(500)
        expected.retries = 5
        expected.startPeriod = .seconds(10)
        expected.startInterval = .seconds(2)
        #expect(db.healthcheck == .check(expected))
        #expect(warnings.isEmpty)
    }

    @Test func shellFormsAndDefaults() throws {
        let (list, _) = try service("    healthcheck:\n      test: [\"CMD-SHELL\", \"redis-cli ping | grep PONG\"]\n")
        let (text, warnings) = try service("    healthcheck:\n      test: redis-cli ping | grep PONG\n")
        let expected = ComposeHealthcheck(command: ["/bin/sh", "-c", "redis-cli ping | grep PONG"])
        #expect(list.healthcheck == .check(expected))
        #expect(text.healthcheck == .check(expected))
        #expect(warnings.isEmpty)
        // Compose's defaults: 30 s interval, 30 s timeout, 3 retries, no start period, 5 s start interval.
        #expect(expected.interval == .seconds(30))
        #expect(expected.timeout == .seconds(30))
        #expect(expected.retries == 3)
        #expect(expected.startPeriod == .zero)
        #expect(expected.startInterval == .seconds(5))
        #expect(expected.timingSummary == "every 30s, timeout 30s, 3 retries")
    }

    @Test func dollarDollarReachesTheShellAsOneDollar() throws {
        let (db, _) = try service("    healthcheck:\n      test: pg_isready -U $$POSTGRES_USER\n")
        #expect(
            db.healthcheck == .check(ComposeHealthcheck(command: ["/bin/sh", "-c", "pg_isready -U $POSTGRES_USER"])))
    }

    @Test func noneAndDisableSwitchTheCheckOff() throws {
        let (none, noneWarnings) = try service("    healthcheck:\n      test: [\"NONE\"]\n")
        let (disabled, _) = try service(
            "    healthcheck:\n      disable: true\n      test: [\"CMD\", \"true\"]\n")
        #expect(none.healthcheck == .disabled)
        #expect(disabled.healthcheck == .disabled)
        #expect(noneWarnings.isEmpty)
    }

    @Test func timingsWithoutATestAreReportedAsInherited() throws {
        let (db, warnings) = try service("    healthcheck:\n      interval: 5s\n")
        #expect(db.healthcheck == .inheritedFromImage)
        #expect(warnings.map(\.key) == ["healthcheck"])
        #expect(warnings[0].message.contains("HEALTHCHECK"))
    }

    @Test func unreadablePartsWarnAndFallBackToDefaults() throws {
        let (db, warnings) = try service(
            """
                healthcheck:
                  test: ["CMD", "true"]
                  interval: soon
                  retries: many
                  future_key: 1
            """)
        #expect(db.healthcheck == .check(ComposeHealthcheck(command: ["true"])))
        #expect(
            Set(warnings.map(\.key)) == ["healthcheck.interval", "healthcheck.retries", "healthcheck.future_key"])
        let (bad, badWarnings) = try service("    healthcheck:\n      test: [\"RUN\", \"x\"]\n")
        #expect(bad.healthcheck == nil)
        #expect(badWarnings.map(\.key) == ["healthcheck.test"])
        let (zero, _) = try service(
            "    healthcheck:\n      test: [\"CMD\", \"true\"]\n      interval: 0s\n      retries: 0\n")
        #expect(zero.healthcheck == .check(ComposeHealthcheck(command: ["true"])))
    }

    @Test(arguments: [
        ("no", RestartPolicy.no), ("always", .always), ("unless-stopped", .unlessStopped),
        ("on-failure", .onFailure(maxRetries: nil)), ("on-failure:5", .onFailure(maxRetries: 5)),
        ("Always", .always),
    ])
    func restartPolicies(text: String, expected: RestartPolicy) {
        #expect(RestartPolicy(text) == expected)
        #expect(RestartPolicy(expected.rawValue) == expected)
    }

    @Test func restartPolicyLabelsAndLaunchRules() {
        #expect(RestartPolicy("sometimes") == nil)
        #expect(RestartPolicy("on-failure:0") == nil)
        #expect(RestartPolicy("on-failure:x") == nil)
        #expect(RestartPolicy.no.labelValue == nil)
        #expect(RestartPolicy.onFailure(maxRetries: 3).labelValue == "on-failure:3")
        #expect(RestartPolicy.always.startsOnLaunch(intentionallyStopped: true))
        #expect(RestartPolicy.unlessStopped.startsOnLaunch(intentionallyStopped: false))
        #expect(!RestartPolicy.unlessStopped.startsOnLaunch(intentionallyStopped: true))
        #expect(!RestartPolicy.onFailure(maxRetries: nil).startsOnLaunch(intentionallyStopped: false))
        #expect(!RestartPolicy.no.startsOnLaunch(intentionallyStopped: false))
        #expect(AppLabel.restart == "io.aiflowlabs.containerdesktop.restart")
    }

    @Test func restartInAComposeFile() throws {
        let (always, notes) = try service("    restart: always\n")
        #expect(always.restart == .always)
        #expect(notes.map(\.severity) == [.note])
        #expect(notes[0].message.contains("while the app or its menu bar item is running"))
        let (limited, _) = try service("    restart: on-failure:3\n")
        #expect(limited.restart == .onFailure(maxRetries: 3))
        let (off, offWarnings) = try service("    restart: \"no\"\n")
        #expect(off.restart == .no)
        #expect(offWarnings.isEmpty)
        let (bad, badWarnings) = try service("    restart: sometimes\n")
        #expect(bad.restart == .no)
        #expect(badWarnings.map(\.severity) == [.unsupported])
    }

    @Test func unknownDependencyConditionFallsBackToStarted() throws {
        let file = try ComposeParser.parse(
            """
            services:
              web: {image: x, depends_on: {db: {condition: service_ready}}}
              db: {image: x}
            """)
        #expect(file.service(named: "web")?.dependsOn == [ComposeDependency(service: "db")])
        #expect(file.warnings.map(\.key) == ["depends_on.db.condition"])
    }
}
