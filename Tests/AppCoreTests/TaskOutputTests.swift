import Foundation
import Testing
import ContainerKit
@testable import AppCore

@MainActor
@Suite struct TaskOutputTests {
    private func stream(_ count: Int) -> LineStream {
        AsyncThrowingStream { c in
            for i in 0..<count { c.yield(OutputLine("line \(i)")) }
            c.finish()
        }
    }

    @Test func outputIsCappedButTotalKeepsGrowing() async {
        let center = TaskCenter()
        let n = LongRunningTask.maxLines + 1_234
        let task = center.run(title: "Chatty", kind: .build, stream: stream(n))
        await task.wait()
        #expect(task.buffer.count == LongRunningTask.maxLines)
        #expect(task.buffer.totalAppended == n)              // follow token keeps moving past the cap
        #expect(task.buffer.droppedCount == 1_234)           // stable row ids: droppedCount + offset
        #expect(task.lines.first?.text == "line 1234")
        #expect(task.lines.last?.text == "line \(n - 1)")
    }

    @Test func appendsAreBatched() async throws {
        let center = TaskCenter()
        let (s, c) = AsyncThrowingStream<OutputLine, any Error>.makeStream()
        let task = center.run(title: "Slow", kind: .pull, stream: s)
        for i in 0..<20 { c.yield(OutputLine("l\(i)")) }
        // Published by the batch timer while the stream is still open (not only at finish).
        #expect(await eventually { task.buffer.count == 20 })
        #expect(task.state == .running)
        c.finish()
        await task.wait()
        #expect(task.state == .succeeded)
    }
}
