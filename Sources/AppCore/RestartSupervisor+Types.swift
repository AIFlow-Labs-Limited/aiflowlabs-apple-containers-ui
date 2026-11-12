import Foundation

extension RestartSupervisor {
    /// The backoff schedule.
    public struct Timing: Sendable, Equatable {
        /// Delay before the first restart attempt.
        public var initialDelay: TimeInterval = 1
        /// Longest delay between two attempts.
        public var maxDelay: TimeInterval = 60
        /// Uptime after which a container counts as healthy again and the attempt count starts over.
        public var stableAfter: TimeInterval = 30

        /// 1 s doubling to 60 s, reset after 30 s of uptime.
        public init() {}

        /// Delay before attempt number `attempt` (1-based): `initialDelay × 2^(attempt − 1)`, capped at `maxDelay`.
        public func delay(beforeAttempt attempt: Int) -> TimeInterval {
            min(initialDelay * pow(2, Double(max(0, min(attempt, 32) - 1))), maxDelay)
        }
    }

    /// What the supervisor knows about one container, for the inspector.
    public struct Status: Equatable, Sendable {
        /// Restarts since the app was launched.
        public var restartCount = 0
        /// Attempts in a row without the container staying up for `Timing.stableAfter`.
        public var consecutiveAttempts = 0
        /// When the next attempt is due, while one is scheduled.
        public var nextAttempt: Date?
        /// `on-failure:N` reached its limit; nothing more happens until the container is started by hand.
        public var gaveUp = false

        /// Nothing has happened yet.
        public init() {}
    }
}
