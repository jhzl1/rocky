import Foundation
import Testing
@testable import RockyKit

struct CILogsTests {
    /// AGT-03: the last 1000 lines, read from the end of a log larger than one read chunk (64 KB).
    @Test func keepsTheLastThousandLines() throws {
        let folder = try Fixtures.temporaryDirectory("ci-logs")
        let log = folder.appendingPathComponent("job.log")
        let lines = (1...1500).map { "2026-09-23T10:00:00.0000000Z line \($0) of the e2e job's output" }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: log)
        #expect(try Data(contentsOf: log).count > 64 * 1024)

        let tail = try CILogs.tail(of: log, lines: 1000)
        let kept = tail.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(kept.count == 1001)
        #expect(kept.first.map(String.init) == lines[500])
        #expect(kept.dropLast().last.map(String.init) == lines[1499])
        #expect(tail.hasSuffix("\n"))

        // Fewer lines than asked: the whole file, whether or not it ends with a newline.
        let short = folder.appendingPathComponent("short.log")
        try Data("one\ntwo".utf8).write(to: short)
        #expect(try CILogs.tail(of: short, lines: 1000) == "one\ntwo")
        #expect(try CILogs.tail(of: short, lines: 1) == "two")
    }

    @Test func fileNameIsSafe() {
        #expect(CILogs.fileName(checkName: "e2e / chromium") == "e2e-chromium.log")
        #expect(CILogs.fileName(checkName: "../../etc/passwd") == "etc-passwd.log")
        #expect(CILogs.fileName(checkName: ".hidden") == "hidden.log")
        #expect(CILogs.fileName(checkName: "Vercel – celes-web") == "Vercel-celes-web.log")
        #expect(CILogs.fileName(checkName: "") == "check.log")
        #expect(CILogs.fileName(checkName: "/ /") == "check.log")
    }

    /// AGT-03: a new Fix errors deletes the workspace's earlier logs; two checks with one name keep both logs.
    @Test func oldLogsAreDeletedFirst() throws {
        let root = try Fixtures.temporaryDirectory("ci-logs")
        let old = CILogs.folder(for: "ws-1", in: root)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("unit.log"))
        let other = CILogs.folder(for: "ws-2", in: root)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: other.appendingPathComponent("unit.log"))

        let folder = try CILogs.freshFolder(for: "ws-1", in: root)
        #expect(folder == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("unit.log").path))

        let download = root.appendingPathComponent("download.log")
        try Data("a\nb\nc\n".utf8).write(to: download)
        let first = try CILogs.save(tailOf: download, checkName: "unit", in: folder, lines: 2)
        let second = try CILogs.save(tailOf: download, checkName: "unit", in: folder, lines: 2)
        #expect(first.lastPathComponent == "unit.log")
        #expect(second.lastPathComponent == "unit-2.log")
        #expect(try String(contentsOf: first, encoding: .utf8) == "b\nc\n")
    }
}
