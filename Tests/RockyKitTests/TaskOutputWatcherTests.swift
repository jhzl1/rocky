import Foundation
import Testing
@testable import RockyKit

/// KIT-17, Decision 8: a background task's output read line by line, without its ANSI escapes.
struct TaskOutputWatcherTests {
    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    @Test func anEndsPatternMatchesAColoredLine() throws {
        var watcher = try TaskOutputWatcher(beginsPattern: "ROLLDOWN-VITE|vite v", endsPattern: #"ready in \d+"#)
        #expect(watcher.feed(bytes("\u{1B}[36mROLLDOWN-VITE v7.1.2\u{1B}[39m dev server\r\n")) == [.begins])
        #expect(watcher.feed(bytes("  \u{1B}[32m\u{1B}[1mready\u{1B}[22m in \u{1B}[1m812\u{1B}[22m ms\u{1B}[39m\r\n")) == [.ends])
        #expect(watcher.feed(bytes("  ➜  Local:   http://localhost:5173/\r\n")) == [])
    }

    /// A line split over chunks, and a line with no newline yet, which a server may leave on screen while it waits.
    @Test func aLineMatchesAcrossChunksAndBeforeItsNewline() throws {
        var watcher = try TaskOutputWatcher(beginsPattern: nil, endsPattern: "Application startup complete")
        #expect(watcher.feed(bytes("INFO:     Application sta")) == [])
        #expect(watcher.feed(bytes("rtup complete.")) == [.ends])
        // The same line, finished: it has reported already.
        #expect(watcher.feed(bytes("\n")) == [])
        #expect(watcher.feed(bytes("Application startup complete\n")) == [.ends])
    }

    /// TSK-03's echo line is Rocky's, not the task's: a command that names its own pattern does not end its wait.
    @Test func theEchoLineIsNotTheTasksOutput() throws {
        let echo = "> echo 'ready in 5 ms'; sleep 30"
        var watcher = try TaskOutputWatcher(beginsPattern: nil, endsPattern: #"ready in \d+"#, ignoringFirstLine: echo)
        #expect(watcher.feed(bytes("\u{1B}[90m> echo 'ready in 5")) == [])
        #expect(watcher.feed(bytes(" ms'; sleep 30\u{1B}[0m\r\n")) == [])
        #expect(watcher.feed(bytes("ready in 5 ms\r\n")) == [.ends])

        // Only the first line: the same text later is the task's.
        var other = try TaskOutputWatcher(beginsPattern: nil, endsPattern: "ready", ignoringFirstLine: "> go")
        #expect(other.feed(bytes("ready\n")) == [.ends])
    }

    @Test func escapesAreRemoved() {
        #expect(TaskOutputWatcher.stripANSI("\u{1B}[1;32mgreen\u{1B}[0m \u{1B}]0;title\u{07}text \u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\ \u{1B}(Bdone") == "green text link done")
        #expect(TaskOutputWatcher.stripANSI("plain") == "plain")
    }

    @Test func aLineWithoutANewlineKeepsOnlyItsEnd() throws {
        var watcher = try TaskOutputWatcher(beginsPattern: nil, endsPattern: "^x+ready$")
        _ = watcher.feed(bytes(String(repeating: "x", count: TaskOutputWatcher.maxLineBytes + 10)))
        #expect(watcher.feed(bytes("ready")) == [.ends])
    }

    @Test func aPatternThatIsNotARegularExpressionThrows() {
        #expect(throws: (any Error).self) { try TaskOutputWatcher(beginsPattern: nil, endsPattern: "([") }
    }
}
