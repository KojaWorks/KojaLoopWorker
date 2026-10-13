import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct FileLogSinkTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "lw-log-\(UUID().uuidString)")

    func contents(_ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }

    @Test("B112, B114: timestamped, levelled, redacted lines in a created directory")
    func writesRedactedLines() throws {
        let sink = FileLogSink(file: directory.appending(path: "state/manager.log"), echo: false, secrets: ["s3cr3t-value"])
        sink.info("token glpat-AbC123 and s3cr3t-value")
        sink.error("two\nlines")
        let lines = try contents("state/manager.log").split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].wholeMatch(of: #/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ INFO token \[REDACTED\] and \[REDACTED\]/#) != nil)
        #expect(lines[1].hasSuffix(" ERROR two"))
        #expect(lines[2].hasSuffix(" ERROR lines"))
        #expect(sink.recentLines() == lines)
    }

    @Test func recentLinesKeepsTheLast200() {
        let sink = FileLogSink(file: directory.appending(path: "manager.log"), echo: false)
        for n in 0..<250 { sink.info("line \(n)") }
        let recent = sink.recentLines()
        #expect(recent.count == 200)
        #expect(recent.first?.hasSuffix("line 50") == true)
        #expect(recent.last?.hasSuffix("line 249") == true)
    }

    @Test("B114: rotates past the size limit and keeps the configured backups")
    func rotates() throws {
        let sink = FileLogSink(file: directory.appending(path: "manager.log"), echo: false, maxBytes: 200, backups: 2)
        for n in 0..<40 { sink.info("line \(n)") }
        let manager = FileManager.default
        for name in ["manager.log", "manager.log.1", "manager.log.2"] {
            let size = try #require(try manager.attributesOfItem(atPath: directory.appending(path: name).path)[.size] as? Int)
            #expect(size <= 200)
        }
        #expect(!manager.fileExists(atPath: directory.appending(path: "manager.log.3").path))
        #expect(try contents("manager.log").hasSuffix("line 39\n"))
    }

    @Test func writeFailureNeverThrows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appending(path: "not-a-directory")
        try Data().write(to: blocker)
        let sink = FileLogSink(file: blocker.appending(path: "manager.log"), echo: false)
        sink.info("first")
        sink.info("second")
        #expect(sink.recentLines().count == 2)
    }
}
