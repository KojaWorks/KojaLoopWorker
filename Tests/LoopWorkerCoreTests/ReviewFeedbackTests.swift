import Foundation
import Testing
@testable import LoopWorkerCore

@Suite struct ReviewFeedbackTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_157_600)
    static func at(_ minutes: Int) -> Date { t0.addingTimeInterval(Double(minutes) * 60) }

    /// A note whose body is its id.
    func note(_ id: String, by author: String = "alice", at minutes: Int, body: String? = nil,
              edit: ReviewFeedback.Edit = .never) -> ReviewFeedback.RawNote {
        .init(id: id, author: author, byOwner: author == "me", createdAt: Self.at(minutes), body: body ?? id, edit: edit)
    }

    func thread(_ id: String, resolvable: Bool = true, resolved: Bool = false, _ notes: [ReviewFeedback.RawNote]) -> ReviewFeedback.RawThread {
        .init(id: id, position: nil, resolvable: resolvable, resolved: resolved, notes: notes)
    }

    func build(_ threads: [ReviewFeedback.RawThread], vouchedAt: Date? = at(10)) -> ReviewFeedback {
        ReviewFeedback.build(threads, owner: "me", openedAt: Self.at(0), vouchedAt: vouchedAt)
    }

    @Test("B203: the owner's notes, and others' from before the vouch and unedited since, are trusted")
    func trustDecisions() {
        let f = build([thread("T", [
            note("1", by: "me", at: 20),
            note("2", at: 5),
            note("3", at: 15),
            note("4", at: 5, edit: .edited(by: "mallory", owner: false, at: Self.at(12))),
            note("5", at: 5, edit: .edited(by: "me", owner: true, at: Self.at(12))),
            note("6", at: 5, edit: .edited(by: "bob", owner: false, at: Self.at(8))),
            note("7", by: "me", at: 6, edit: .edited(by: "mallory", owner: false, at: Self.at(12))),
            note("8", at: 5, edit: .unknown),
        ])])
        #expect(Set(f.threads[0].notes.map(\.body)) == ["1", "2", "5", "6"])
        let iso = { (m: Int) in Self.at(m).formatted(.iso8601) }
        #expect(Set(f.withheld) == [
            "note 7 by @me in thread T: edited by @mallory at \(iso(12)), after the card was vouched for at \(iso(10))",
            "note 3 by @alice in thread T: posted at \(iso(15)), after the card was vouched for at \(iso(10))",
            "note 4 by @alice in thread T: edited by @mallory at \(iso(12)), after the card was vouched for at \(iso(10))",
            "note 8 by @alice in thread T: its edit history couldn't be read",
        ])
    }

    @Test("B203: without a vouch time only the owner's unedited notes are trusted")
    func noVouchTrustsOnlyTheOwner() {
        let f = build([thread("T", [
            note("1", by: "me", at: 1),
            note("2", at: 2),
            note("3", by: "me", at: 3, edit: .edited(by: "bob", owner: false, at: Self.at(4))),
        ])], vouchedAt: nil)
        #expect(f.threads[0].notes.map(\.author) == ["me"])
        #expect(f.withheld.count == 2)
        #expect(f.withheld[0] == "note 2 by @alice in thread T: only @me's notes are trusted, because the backlog records no time when the card was vouched for")
    }

    @Test("B203: resolved threads are skipped and a thread without a trusted note is dropped")
    func resolvedSkipped() {
        let f = build([
            thread("done", resolved: true, [note("1", at: 1)]),
            thread("open", [note("2", at: 1)]),
            thread("late", [note("3", at: 30)]),
        ])
        #expect(f.threads.map(\.id) == ["open"])
        #expect(f.withheld.count == 1)
    }

    @Test("B203: plain comments count only after the Manager's latest note, whose own notes stay labelled in their threads")
    func plainCommentsAfterTheManagersLatestNote() {
        let summary = ReviewMarker.note("LoopWorker pushed abc:\n\nDid it.", markers: [ReviewMarker.round("abc")])
        let reply = ReviewMarker.note("Renamed it.", markers: [ReviewMarker.reply("abc", thread: "T")])
        let f = build([
            thread("T", [note("1", at: 1), note("2", by: "me", at: 4, body: reply)]),
            thread("P1", resolvable: false, [note("3", at: 2)]),
            thread("S", resolvable: false, [note("4", by: "me", at: 5, body: summary)]),
            thread("P2", resolvable: false, [note("5", by: "me", at: 6, body: "Also the docs.")]),
        ])
        #expect(f.threads.map(\.id) == ["T", "P2"])
        #expect(f.threads[0].notes[1] == ReviewFeedback.Note(author: "me", createdAt: Self.at(4), body: "Renamed it.", byLoopWorker: true))
        #expect(!f.threads[1].notes[0].byLoopWorker)

        let first = build([thread("P1", resolvable: false, [note("3", by: "me", at: 2)])])
        #expect(first.threads.map(\.id) == ["P1"])  // no Manager note yet: since the review request opened
    }

    @Test("B203: caps keep 50 threads and cut each redacted note to 4000 characters, saying so")
    func caps() {
        let threads = (1...51).map { ReviewFeedback.Thread(id: "T\($0)", position: nil, notes: [.init(author: "me", createdAt: Self.t0, body: "x")]) }
        var f = ReviewFeedback(threads: threads)
        f.threads[0].notes[0].body = "SECRET " + String(repeating: "y", count: 5000)
        let capped = f.capped { $0.replacingOccurrences(of: "SECRET", with: "[REDACTED]") }
        #expect(capped.threads.count == 50)
        #expect(capped.threads[0].notes[0].body.hasPrefix("[REDACTED] yyy"))
        #expect(capped.threads[0].notes[0].body.count == 4000)
        #expect(capped.cut == ["1 threads after the first 50 were left out", "a note by @me in thread T1 was cut to 4000 characters"])
    }
}
