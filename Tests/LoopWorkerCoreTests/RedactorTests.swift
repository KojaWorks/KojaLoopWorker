import Testing
@testable import LoopWorkerCore

@Suite struct RedactorTests {
    // Every value here is fabricated.
    @Test("B113: each secret shape is scrubbed", arguments: [
        ("anon key eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.c2lnbmF0dXJl ok", "anon key [REDACTED] ok"),
        ("key sb_secret_AbC123xyz end", "key [REDACTED] end"),
        ("key sb_publishable_AbC123xyz end", "key [REDACTED] end"),
        ("S3 secret 0123456789abcdef0123456789ABCDEF", "S3 secret [REDACTED]"),
        ("DB postgresql://postgres:hunter2@127.0.0.1:54322/postgres", "DB postgresql://postgres:[REDACTED]@127.0.0.1:54322/postgres"),
        ("remote https://oauth2:s3cret@gitlab.example.com/a/b.git", "remote https://oauth2:[REDACTED]@gitlab.example.com/a/b.git"),
        ("token glpat-AbCdEf_123-xyz.01.abc", "token [REDACTED]"),
        ("token gloas-AbCdEf123", "token [REDACTED]"),
        ("token glrt-t1_AbCdEf123", "token [REDACTED]"),
        ("token gldt-AbCdEf123", "token [REDACTED]"),
        ("token ghp_AbCdEf123456", "token [REDACTED]"),
        ("token gho_AbCdEf123456", "token [REDACTED]"),
        ("token ghs_AbCdEf123456", "token [REDACTED]"),
        ("token github_pat_11AB_cdEF", "token [REDACTED]"),
        ("Authorization: Bearer abc.def-123", "Authorization: Bearer [REDACTED]"),
        ("authorization: bearer abc", "authorization: bearer [REDACTED]"),
        ("PRIVATE-TOKEN: abc123", "PRIVATE-TOKEN: [REDACTED]"),
        ("oauth sk-ant-oat01-AbC_d-ef", "oauth [REDACTED]"),
    ])
    func scrubs(input: String, expected: String) {
        #expect(Redactor.redact(input) == expected)
    }

    @Test("B113: configured token values are scrubbed literally")
    func literals() {
        #expect(Redactor.redact("using tok-short and x", literals: ["tok-short", ""]) == "using [REDACTED] and x")
    }

    @Test func ordinaryLinesSurvive() {
        let lines = [
            "provision: started stack on port 54321 in /Users/me/clones/proj.slots/2",
            "fetching https://gitlab.example.com/group/project.git",
            "short sha 1a2b3c4d on branch loopworker-12-fix-login",
            "user@example.com said hi",
        ]
        for line in lines { #expect(Redactor.redact(line) == line) }
    }

    @Test func fullGitShaIsAKnownOverRedaction() {
        #expect(Redactor.redact("HEAD is 0123456789abcdef0123456789abcdef01234567") == "HEAD is [REDACTED]")
    }
}

@Suite struct PaneTests {
    @Test("B16: claude's login prompt is an auth failure", arguments: [
        "⏺ Please run /login · API Error: 401 {\"type\":\"error\"}",
        "Not logged in · Please run /login",
    ])
    func authFailure(pane: String) {
        #expect(Pane.showsAuthFailure("some work\n\(pane)\n"))
    }

    @Test("B16: the words alone are not an auth failure")
    func authFailureNeedsChrome() {
        #expect(!Pane.showsAuthFailure("⏺ Editing Pane.swift to match \"Please run /login\" anchored on the separator"))
        #expect(!Pane.showsAuthFailure("All 12 tests passed"))
    }

    @Test("B17: folder-trust dialog", arguments: [
        "Accessing workspace:", "Yes, I trust this folder", "is this a project you created or one you trust?",
        "Do you trust the files in this folder?",
    ])
    func trustPrompt(pane: String) {
        #expect(Pane.startupDialog(pane)?.dialog == "folder trust")
    }

    @Test func noStartupDialogInOrdinaryPane() {
        #expect(Pane.startupDialog("⏺ Running swift test") == nil)
    }

    @Test("B17: the trust dialog is answered by moving to Yes, whatever the option order")
    func trustPromptKeys() {
        let noFirst = """
             Accessing workspace:
             /private/tmp/x
             Quick safety check: Is this a project you created or one you trust?
             ❯ No, exit
               Yes, I trust this folder
             Enter to confirm · Esc to cancel
            """
        #expect(Pane.startupDialog(noFirst)?.keys == ["Down", "Enter"])
        let yesFirst = """
             Do you trust the files in this folder?
             ❯ Yes, proceed
               No, exit
            """
        #expect(Pane.startupDialog(yesFirst)?.keys == ["Enter"])
        let numbered = """
            │ Do you trust the files in this folder? │
            │ ❯ 1. No, exit                          │
            │   2. Yes, proceed                      │
            """
        #expect(Pane.startupDialog(numbered)?.keys == ["Down", "Enter"])
        #expect(Pane.startupDialog("Do you trust the files in this folder?\n  1. Maybe") == .init(dialog: "folder trust", keys: nil))
    }

    static let imports = """
        Allow external CLAUDE.md file imports?
          This project's CLAUDE.md or .claude/rules imports files outside the current
          working directory. Never allow this for third-party repositories.
          External imports:
            /Volumes/Disk/Dev/Parent/AGENTS.md
          ❯ No, disable external imports
            Yes, allow external imports
          Enter to confirm · Esc to cancel
        """

    @Test("B246: the external-imports dialog is answered No, from wherever the cursor is")
    func importsDialogKeys() {
        #expect(Pane.startupDialog(Self.imports) == .init(dialog: "external CLAUDE.md imports", keys: ["Enter"]))
        let cursorBelow = Self.imports.replacingOccurrences(of: "❯ No", with: "  No").replacingOccurrences(of: "  Yes, allow", with: "❯ Yes, allow")
        #expect(Pane.startupDialog(cursorBelow)?.keys == ["Up", "Enter"])
        let cursorAbove = """
            Allow external CLAUDE.md file imports?
              ❯ Ask me later
                No, disable external imports
            """
        #expect(Pane.startupDialog(cursorAbove)?.keys == ["Down", "Enter"])
        let noAnswer = Self.imports.replacingOccurrences(of: "No, disable external imports", with: "Never")
        #expect(Pane.startupDialog(noAnswer) == .init(dialog: "external CLAUDE.md imports", keys: nil))
    }

    @Test("B246: an answered dialog in scrollback gives way to the next one, or to the input screen")
    func dialogInScrollback() {
        let trust = "Do you trust the files in this folder?\n❯ 1. Yes, proceed\n  2. No, exit\nEnter to confirm · Esc to cancel"
        #expect(Pane.startupDialog(trust + "\n" + Self.imports) == .init(dialog: "external CLAUDE.md imports", keys: ["Enter"]))
        let input = trust + "\n╭────╮\n│ ❯  │\n╰────╯\n  ⏵⏵ auto mode on (shift+tab to cycle)"
        #expect(Pane.startupDialog(input) == nil)
        #expect(Pane.showsInputScreen(input))
        #expect(!Pane.showsInputScreen(Self.imports))
    }

    @Test("B247: a dialog's title is its question line above the options")
    func dialogTitle() {
        #expect(Pane.dialogTitle(Self.imports) == "Allow external CLAUDE.md file imports?")
        let permission = """
            ⏺ Bash(make clean)
            ╭──────────────────────────────╮
            │ Bash command                 │
            │   make clean                 │
            │ Do you want to proceed?      │
            │ ❯ 1. Yes                     │
            │   2. No, and tell Claude what to do differently (esc) │
            ╰──────────────────────────────╯
            """
        #expect(Pane.dialogTitle(permission) == "Do you want to proceed?")
        #expect(Pane.dialogTitle("Choose a theme\n❯ 1. Dark\n  2. Light") == "Choose a theme")
        #expect(Pane.dialogTitle("⏺ Running swift test\n✻ Thinking… (12s · esc to interrupt)") == nil)
        #expect(Pane.dialogTitle(Self.imports + "\n⏺ Reading\n  ⏵⏵ auto mode on (shift+tab to cycle)") == nil)
        #expect(Pane.dialogTitle("❯ fix the bug") == nil)
    }

    @Test("B18: activity line skips chrome and the tip below the thinking line")
    func activityLine() {
        let pane = """
            ⏺ Reading the reconciler
            ✢ Percolating… (24s · esc to interrupt)
            ✢ Percolating… (24s)
              ⎿  Tip: use /clear
            ╭────────────╮
            │ ❯          │
            ╰────────────╯
              ⏵⏵ auto mode on (shift+tab to cycle)

            """
        #expect(Pane.activityLine(pane) == "✢ Percolating… (24s)")
    }

    @Test("B18: empty when only chrome, cut to 140 characters")
    func activityLineEdges() {
        #expect(Pane.activityLine("╭──╮\n│ ❯ │\n╰──╯\n") == "")
        #expect(Pane.activityLine(String(repeating: "x", count: 300)).count == 140)
    }
}
