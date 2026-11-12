import Foundation

// `healthcheck:` and `restart:` — both are honoured by the app rather than by the runtime.
extension ComposeDecoder {
    /// Reads a `healthcheck:` section. `nil` when the value cannot be read at all.
    mutating func healthcheck(_ value: ComposeValue, scope: ComposeWarning.Scope) -> ComposeHealthcheckSetting? {
        guard let entries = value.mapValue else {
            unreadable(scope, "healthcheck")
            return nil
        }
        var reader = ComposeMapReader(entries)
        let disabled = reader.take("disable")?.bool ?? false
        let test = reader.take("test")
        var timings = ComposeHealthcheck(command: [])
        if let interval = duration(reader.take("interval"), key: "interval", scope: scope) {
            timings.interval = interval
        }
        if let timeout = duration(reader.take("timeout"), key: "timeout", scope: scope) { timings.timeout = timeout }
        if let startPeriod = duration(reader.take("start_period"), key: "start_period", scope: scope) {
            timings.startPeriod = startPeriod
        }
        if let startInterval = duration(reader.take("start_interval"), key: "start_interval", scope: scope) {
            timings.startInterval = startInterval
        }
        if let retries = reader.take("retries") {
            if let count = retries.int, count >= 0 {
                // Docker reads 0 as "use the default".
                timings.retries = count == 0 ? ComposeHealthcheck.Defaults.retries : count
            } else {
                unreadable(scope, "healthcheck.retries")
            }
        }
        for key in reader.unhandledKeys {
            warn(scope, "healthcheck.\(key)", "Health check option `\(key)` is not supported and is ignored.")
        }
        if disabled { return .disabled }
        guard let test, !test.isNull else {
            warn(
                scope, "healthcheck",
                "This health check has no `test:`. Docker would use the image's own HEALTHCHECK, which this runtime "
                    + "does not read, so the service has no health check here.")
            return .inheritedFromImage
        }
        guard let command = healthCommand(test, scope: scope) else { return nil }
        guard !command.isEmpty else { return .disabled }
        timings.command = command
        return .check(timings)
    }

    /// `test:` → the command to execute. An empty result means `NONE`; `nil` means unreadable.
    private mutating func healthCommand(_ test: ComposeValue, scope: ComposeWarning.Scope) -> [String]? {
        if let text = test.string {
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                unreadable(scope, "healthcheck.test")
                return nil
            }
            return ["/bin/sh", "-c", text]
        }
        guard let words = test.listValue?.compactMap(\.string), let kind = words.first else {
            unreadable(scope, "healthcheck.test")
            return nil
        }
        let arguments = Array(words.dropFirst())
        switch kind {
        case "NONE": return []
        case "CMD" where !arguments.isEmpty: return arguments
        case "CMD-SHELL" where !arguments.isEmpty: return ["/bin/sh", "-c", arguments.joined(separator: " ")]
        default:
            warn(
                scope, "healthcheck.test",
                "A health check `test:` list must start with CMD, CMD-SHELL or NONE and name a command; this one "
                    + "is ignored.")
            return nil
        }
    }

    private mutating func duration(_ value: ComposeValue?, key: String, scope: ComposeWarning.Scope) -> Duration? {
        guard let value, !value.isNull else { return nil }
        guard let text = value.string, let duration = ComposeDuration.parse(text) else {
            unreadable(scope, "healthcheck.\(key)")
            return nil
        }
        // Docker treats 0 as "not set".
        return duration == .zero && key != "start_period" ? nil : duration
    }

    /// `restart:` → the policy the app enforces, with a note saying who enforces it.
    mutating func restartPolicy(_ value: ComposeValue, scope: ComposeWarning.Scope) -> RestartPolicy {
        guard let text = value.string, let policy = RestartPolicy(text) else {
            warn(
                scope, "restart",
                "Restart policy “\(value.string ?? "…")” is not one of no, always, unless-stopped, on-failure or "
                    + "on-failure:N; the container is not restarted.")
            return .no
        }
        if policy.isEnforced {
            warn(
                scope, "restart",
                "Restart policy “\(policy.rawValue)” is enforced by Container Desktop, not by the runtime: it "
                    + "applies while the app or its menu bar item is running. A `container stop` typed in a "
                    + "terminal looks like a crash and is restarted; stop the container from the app instead.",
                severity: .note)
        }
        return policy
    }
}
