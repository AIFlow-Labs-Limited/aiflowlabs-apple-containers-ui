import Foundation
import Synchronization
@testable import ContainerKit

/// A `CommandRunning` fake that records every argv and answers from a handler.
final class RecordingRunner: CommandRunning {
    struct Call: Sendable, Equatable {
        var arguments: [String]
        var stdin: Data?
        var streamed: Bool
    }

    typealias Handler = @Sendable (_ arguments: [String]) -> ProcessResult

    private let state = Mutex<[Call]>([])
    private let handler: Handler
    private let streamLines: [OutputLine]
    private let streamError: (any Error & Sendable)?

    init(streamLines: [OutputLine] = [], streamError: (any Error & Sendable)? = nil,
         handler: @escaping Handler = { _ in ProcessResult(stdout: "[]") }) {
        self.handler = handler
        self.streamLines = streamLines
        self.streamError = streamError
    }

    var calls: [Call] { state.withLock { $0 } }
    /// argv of every call with the executable dropped.
    var commands: [[String]] { calls.map { Array($0.arguments.dropFirst()) } }

    func run(_ arguments: [String], stdin: Data?, timeout: Duration?, environment: [String: String]) async throws -> ProcessResult {
        state.withLock { $0.append(Call(arguments: arguments, stdin: stdin, streamed: false)) }
        return handler(arguments)
    }

    func stream(_ arguments: [String], environment: [String: String]) -> LineStream {
        state.withLock { $0.append(Call(arguments: arguments, stdin: nil, streamed: true)) }
        let lines = streamLines
        let error = streamError
        return AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }
}

extension CLIBackend {
    /// A backend over a recording runner with a fixed executable path.
    static func recording(_ runner: RecordingRunner, configPath: String? = nil) throws -> CLIBackend {
        try CLIBackend(executable: "/usr/local/bin/container", runner: runner, configPath: configPath)
    }
}

/// Drains a stream, returning its lines and the error it finished with (if any).
func drain(_ stream: LineStream) async -> (lines: [OutputLine], error: (any Error)?) {
    var lines: [OutputLine] = []
    do {
        for try await line in stream { lines.append(line) }
        return (lines, nil)
    } catch {
        return (lines, error)
    }
}
